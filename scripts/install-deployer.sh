#!/usr/bin/env bash
# One-time (and safe to re-run) installer of the Dex deployer on the Mac mini. Run as root from a checkout of the repo:
#   sudo scripts/install-deployer.sh [--deploy-now] [--skip-personal]
# It does NOT start a deploy: a fresh install leaves each target paused (<base>/deploy-paused) until you pass --deploy-now
# or remove that file. Internal helper:  scripts/install-deployer.sh --migrate-only BASE   (just the current-symlink migration)
set -euo pipefail
# Run as root: system directories only. Homebrew and /usr/local are writable by non-root users and must never be on root's PATH.
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

HERE=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$HERE/.." && pwd)
PREFIX=/usr/local/dex-deployer
HOSTED_SVC=/var/dexhosted            # the service's own tree: data/, logs/ (owned by _dexhosted; the deployer never works in here)
HOSTED_BASE=/var/dexhosted-deploy    # everything root manages: releases/, current, tmp/, logs/deploy.log, deploy-seen (root:wheel 755)
HOSTED_LABEL=in.dextron04.agentvault-hosted
HOSTED_PLIST=/Library/LaunchDaemons/$HOSTED_LABEL.plist
PERSONAL_USER=mac-agent
PERSONAL_HOME=${DEX_PERSONAL_HOME:-/Users/$PERSONAL_USER}
PERSONAL_BASE=$PERSONAL_HOME/agentvault
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
# Root-owned Python for the hosted daemon and the deployer (python.org installer, signed by the Python Software Foundation).
# To upgrade: change PY_VER, PY_MINOR, PY_URL and PY_SHA256 (of the pkg you downloaded and checked), and python= in targets/hosted.conf. See docs/deploy-pipeline.md.
PY_VER=3.14.10
PY_MINOR=3.14
PY_URL=https://www.python.org/ftp/python/3.14.10/python-3.14.10-macos11.pkg
PY_SHA256=286c7018aa2730f6747ca433dccdc2b31be45f078a9ea0ffa44d5f06368fd2d7
PY_TEAM=BMM5U3QVKW     # Developer ID Installer: Python Software Foundation
PY_ROOT=/Library/Frameworks/Python.framework
PY_BIN=$PY_ROOT/Versions/$PY_MINOR/bin/python$PY_MINOR

say() { printf '%s\n' "$*"; }
die() { printf 'install-deployer: %s\n' "$*" >&2; exit 1; }

# Turn <base>/app (a plain dir today) into <base>/releases/<stamp>-initial, with <base>/current -> that release and
# <base>/app -> current, so anything still pointing at <base>/app keeps working. Backs up first. Idempotent.
migrate_layout() {
  local base=$1 name bk
  case $base in ''|/|//) die "refusing to migrate base '$base'";; esac
  [[ $base == /* && $base != *..* ]] || die "refusing to migrate base '$base'"
  [ -d "$base" ] && [ ! -L "$base" ] || die "$base is not a directory"
  mkdir -p "$base/releases" "$base/backups" "$base/logs"
  if [ -L "$base/current" ]; then
    say "  $base: already migrated (current -> $(readlink "$base/current"))"
    if [ -d "$base/app" ] && [ ! -L "$base/app" ]; then say "  note: $base/app is still a plain directory; the service must use $base/current"; fi
    return 0
  fi
  [ -d "$base/app" ] && [ ! -L "$base/app" ] || { say "  $base: no app dir to migrate (the first deploy creates current)"; return 0; }
  bk="$base/backups/pre-deployer-$STAMP"
  mkdir -p "$bk" && cp -Rp "$base/app" "$bk/"
  name="$STAMP-initial"
  ln -s "releases/$name" "$base/current"        # dangling for a moment: the rename below is the only gap
  mv "$base/app" "$base/releases/$name"
  ln -s current "$base/app"
  chmod -R go-w "$base/releases/$name"
  say "  $base: migrated. backup $bk; current -> releases/$name; app -> current"
}

# Copy an old plain app dir into <base>/releases/<stamp>-initial (root-owned, 644/755) and point <base>/current at it. Backs up first. Idempotent.
# The old dir belongs to the service user, who could swap a path for a symlink while root copies. So the READ is done as that user
# (tar | tar: root never opens a path in their tree) and the result is refused if it contains any link.
copy_tree() {   # copy_tree SRC DEST [tar exclude args]: DEST is a fresh root-owned dir
  local src=$1 dest=$2 owner=""; shift 2
  if [ "$(id -u)" = 0 ]; then owner=$(stat -f %Su "$src"); fi
  if [ -n "$owner" ] && [ "$owner" != root ]; then ( cd / && sudo -n -u "$owner" tar -C "$src" -cf - "$@" . ) | tar -C "$dest" -xf - --no-same-owner
  else tar -C "$src" -cf - "$@" . | tar -C "$dest" -xf - --no-same-owner; fi
  if [ -n "$(find "$dest" ! -type f ! -type d -print -quit)" ]; then rm -rf "$dest"; die "refusing: $src contains links or special files (a symlink could redirect root); nothing copied"; fi
}
migrate_copy() {
  local old=$1 base=$2 name bk
  case $base in ''|/|//) die "refusing to migrate into '$base'";; esac
  [[ $base == /* && $base != *..* ]] || die "refusing to migrate into '$base'"
  [ -d "$base" ] && [ ! -L "$base" ] || die "$base is not a directory"
  for d in releases tmp logs backups; do [ -L "$base/$d" ] && die "$base/$d is a symlink"; [ -e "$base/$d" ] || mkdir "$base/$d"; done
  chmod 700 "$base/backups"
  if [ -L "$base/current" ]; then say "  $base: already migrated (current -> $(readlink "$base/current"))"; return 0; fi
  [ -d "$old" ] && [ ! -L "$old" ] || { say "  no $old to migrate (the first deploy creates current)"; return 0; }
  bk="$base/backups/pre-deployer-$STAMP"; name="$STAMP-initial"
  mkdir -p "$bk/app" && copy_tree "$old" "$bk/app"
  mkdir "$base/releases/$name"
  copy_tree "$old" "$base/releases/$name" --exclude __pycache__ --exclude '*.pyc'
  if [ "$(id -u)" = 0 ]; then chown -R root:wheel "$base/releases/$name"; fi
  chmod -R u+w,go-w,a+rX "$base/releases/$name"
  ln -s "releases/$name" "$base/current"
  say "  $base: copied $old -> releases/$name; backup $bk; current -> releases/$name (the old dir is left in place)"
}

# Everything the installer does inside the personal user's tree runs AS that user (never as root: chown, chmod, > and cp follow symlinks,
# and that user could plant one). Paths that must be plain files are also refused if they are symlinks.
# Test entry: --personal-files BASE HOME PREFIX NEW DEPLOY_NOW (refuses to run as root)
personal_files() {
  local base=$1 home=$2 prefix=$3 new=$4 now=$5 W A OLD p
  [ "$(id -u)" != 0 ] || die "personal_files must not run as root"
  W=$base/connector-deploy.sh; A=$home/Library/LaunchAgents/in.dextron04.dex-deployer-personal.plist; OLD=$home/Library/LaunchAgents/in.dextron04.agentvault-deploy.plist
  for p in "$base" "$base/tmp" "$base/backups" "$base/deploy-paused" "$W" "$home/Library" "$home/Library/LaunchAgents" "$A" "$OLD"; do
    [ ! -L "$p" ] || die "refusing: $p is a symlink"
  done
  migrate_layout "$base"
  for p in tmp backups; do [ ! -L "$base/$p" ] || die "refusing: $base/$p is a symlink"; mkdir -p "$base/$p"; done
  # the connector's /hooks/deploy runs this path with /bin/zsh: it must stay, and now only calls the new deployer
  if [ -f "$W" ] && ! cmp -s "$W" "$prefix/connector-deploy.sh"; then cp -p "$W" "$base/backups/connector-deploy.sh.$STAMP"; fi
  install -m 755 "$prefix/connector-deploy.sh" "$W"
  if [ "$new" = 1 ] && [ "$now" = 0 ]; then : > "$base/deploy-paused"; fi
  mkdir -p "$home/Library/LaunchAgents"
  sed -e "s|__PREFIX__|$prefix|g" -e "s|__HOME__|$home|g" "$prefix/personal.plist.template" > "$A.new" && mv -f "$A.new" "$A"
  chmod 644 "$A"; plutil -lint "$A" >/dev/null
  [ ! -f "$OLD" ] || { mv "$OLD" "$OLD.disabled-$STAMP"; say "  old poller disabled: $OLD.disabled-$STAMP"; }
}

if [ "${1:-}" = --migrate-only ]; then migrate_layout "${2:-}"; exit 0; fi
if [ "${1:-}" = --migrate-copy ]; then migrate_copy "${2:-}" "${3:-}"; exit 0; fi
if [ "${1:-}" = --personal-files ]; then shift; personal_files "$@"; exit 0; fi

DEPLOY_NOW=0 SKIP_PERSONAL=0
for a in "$@"; do
  case $a in --deploy-now) DEPLOY_NOW=1;; --skip-personal) SKIP_PERSONAL=1;; *) die "unknown option $a";; esac
done
[ "$(id -u)" = 0 ] || die "run with sudo"
[ "$(uname)" = Darwin ] || die "macOS only"

bootstrap() {   # launchd often answers "5: Input/output error" right after a bootout: wait and try once more
  launchctl bootstrap "$1" "$2" 2>/dev/null && return 0
  sleep 4
  launchctl bootstrap "$1" "$2"
}
reload() { launchctl bootout "$1/$2" 2>/dev/null || true; sleep 1; bootstrap "$1" "$3"; }
render() { sed -e "s|__PREFIX__|$PREFIX|g" -e "s|__HOME__|$PERSONAL_HOME|g" "$1" > "$2"; }   # root-owned destinations only
pa() { ( cd / && sudo -n -u "$PERSONAL_USER" "$@" ); }   # run something AS the personal user
healthy() {   # the hosted service answers: GET /healthz 200 and POST /mcp 401, within ~40 s
  local i g p
  for i in $(seq 1 40); do
    g=$(curl -s -o /dev/null -m 3 -w '%{http_code}' http://127.0.0.1:8766/healthz || true)
    p=$(curl -s -o /dev/null -m 3 -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d '{}' http://127.0.0.1:8766/mcp || true)
    [ "$g" = 200 ] && [ "$p" = 401 ] && return 0
    sleep 1
  done
  return 1
}
# Fail unless the path and every parent are real (non-symlink) directories/files owned by root and not group/world-writable.
chain_ok() {
  local p=$1 o m
  while :; do
    [ ! -L "$p" ] || { say "  $p is a symlink"; return 1; }
    read -r o m <<< "$(stat -f '%u %Lp' "$p")"
    [ "$o" = 0 ] && [ $((8#$m & 8#22)) -eq 0 ] || { say "  $p: owner $o mode $m"; return 1; }
    [ "$p" = / ] && return 0
    p=${p%/*}; [ -n "$p" ] || p=/
  done
}
ensure_python() {
  local have="" t ch
  [ ! -x "$PY_BIN" ] || have=$("$PY_BIN" -I -c 'import sys; print("%d.%d.%d" % sys.version_info[:3])' 2>/dev/null || true)
  if [ "$have" != "$PY_VER" ]; then
    say "  installing Python $PY_VER from python.org (have: ${have:-none})"
    t=$(mktemp -d /var/tmp/dex-python.XXXXXX)   # a fresh 0700 root dir: nobody else can swap the pkg between the checks and the install
    curl -fsSL --proto '=https' --tlsv1.2 --max-time 600 -o "$t/python.pkg" "$PY_URL" || { rm -rf "$t"; die "download failed: $PY_URL"; }
    [ "$(shasum -a 256 "$t/python.pkg" | cut -d' ' -f1)" = "$PY_SHA256" ] || { rm -rf "$t"; die "SHA-256 of the pkg does not match the pinned value; refusing to install"; }
    ch=$(pkgutil --check-signature "$t/python.pkg" 2>&1) || { rm -rf "$t"; die "pkg signature check failed: $ch"; }
    { printf '%s' "$ch" | grep -q "Python Software Foundation ($PY_TEAM)"; } || { rm -rf "$t"; die "pkg is not signed by the Python Software Foundation ($PY_TEAM)"; }
    # the framework only: no GUI apps, no /usr/local/bin links, no docs, no shell-profile edits, no pip run as root
    cat > "$t/choices.xml" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><array>
$(for c in PythonApplications PythonUnixTools PythonDocumentation PythonProfileChanges PythonInstallPip PythonTFramework; do
  printf '<dict><key>choiceIdentifier</key><string>org.python.Python.%s-%s</string><key>choiceAttribute</key><string>selected</string><key>attributeSetting</key><integer>0</integer></dict>
' "$c" "$PY_MINOR"; done)
</array></plist>
XML
    installer -pkg "$t/python.pkg" -applyChoiceChangesXML "$t/choices.xml" -target / >/dev/null || { rm -rf "$t"; die "installer failed"; }
    rm -rf "$t"
  else
    say "  Python $PY_VER already at $PY_BIN"
  fi
  # The pkg's postinstall makes the framework group-admin-writable (chgrp admin; chmod g+w). The personal user is in admin: undo that, every run.
  chown -R root:wheel "$PY_ROOT"; chmod -R go-w "$PY_ROOT"
  chain_ok "$PY_BIN" || die "$PY_BIN is not root-owned all the way up; refusing to continue"
  "$PY_BIN" -I -c 'import hashlib, ssl, sqlite3, sys; hashlib.scrypt(b"x", salt=b"y"*16, n=2**14, r=8, p=1); assert sys.version_info >= (3, 10)' || die "$PY_BIN is missing something the hosted service needs"
  say "  interpreter ok: $PY_BIN (root-owned chain, no symlinks)"
}

say "1. Installing scripts to $PREFIX (root:wheel)"
install -d -m 755 -o root -g wheel "$PREFIX" "$PREFIX/targets"
install -m 755 -o root -g wheel "$HERE/dex-deployer.sh" "$PREFIX/dex-deployer.sh"
install -m 755 -o root -g wheel "$HERE/connector-deploy.sh" "$PREFIX/connector-deploy.sh"
install -m 755 -o root -g wheel "$HERE/install-deployer.sh" "$PREFIX/install-deployer.sh"   # run as the personal user for its half (--personal-files)
for c in hosted personal; do install -m 644 -o root -g wheel "$HERE/deploy-targets/$c.conf" "$PREFIX/targets/$c.conf"; done
install -m 644 -o root -g wheel "$REPO_ROOT/memory/launchd/in.dextron04.dex-deployer-hosted.plist.template" "$PREFIX/hosted.plist.template"
install -m 644 -o root -g wheel "$REPO_ROOT/memory/launchd/in.dextron04.dex-deployer-personal.plist.template" "$PREFIX/personal.plist.template"

say "1b. Root-owned Python runtime (nothing root or $HOSTED_LABEL's user executes may be writable by another user)"
ensure_python
say "2. Hosted: code and deploy state in $HOSTED_BASE (root:wheel); data and logs stay in $HOSTED_SVC"
[ -d "$HOSTED_SVC" ] || die "$HOSTED_SVC missing: do docs/hosted-isolation.md first"
HOSTED_NEW=0; [ -f /Library/LaunchDaemons/in.dextron04.dex-deployer-hosted.plist ] || HOSTED_NEW=1
[ -L "$HOSTED_BASE" ] && die "$HOSTED_BASE is a symlink"
install -d -m 755 -o root -g wheel "$HOSTED_BASE"
chown root:wheel "$HOSTED_BASE"; chmod 755 "$HOSTED_BASE"
migrate_copy "$HOSTED_SVC/app" "$HOSTED_BASE"
for d in releases tmp logs; do chown root:wheel "$HOSTED_BASE/$d"; chmod 755 "$HOSTED_BASE/$d"; done
chown root:wheel "$HOSTED_BASE/backups"
if [ -f "$HOSTED_PLIST" ]; then
  tmp=$(mktemp "${TMPDIR:-/tmp}/hosted-plist.XXXXXX")
  cp "$HOSTED_PLIST" "$tmp"
  plutil -replace WorkingDirectory -string "$HOSTED_BASE/current" "$tmp"
  plutil -replace ProgramArguments.0 -string "$PY_BIN" "$tmp"
  case $(plutil -extract EnvironmentVariables.PATH raw -o - "$tmp" 2>/dev/null || true) in *homebrew*) plutil -replace EnvironmentVariables.PATH -string /usr/bin:/bin "$tmp";; esac
  if plutil -extract EnvironmentVariables.PYTHONPATH raw -o - "$tmp" >/dev/null 2>&1; then plutil -replace EnvironmentVariables.PYTHONPATH -string "$HOSTED_BASE/current" "$tmp"; fi
  plutil -lint "$tmp" >/dev/null
  if cmp -s <(plutil -convert xml1 -o - "$HOSTED_PLIST") <(plutil -convert xml1 -o - "$tmp"); then
    say "  $HOSTED_PLIST already uses $HOSTED_BASE/current and $PY_BIN"
  else
    cp -p "$HOSTED_PLIST" "$HOSTED_BASE/backups/hosted-plist-$STAMP.plist"
    say "  plist change (backup: $HOSTED_BASE/backups/hosted-plist-$STAMP.plist):"
    diff -u <(plutil -convert xml1 -o - "$HOSTED_PLIST") <(plutil -convert xml1 -o - "$tmp") || true
    install -m 644 -o root -g wheel "$tmp" "$HOSTED_PLIST"
    say "  restarting the hosted service on the new plist (a few seconds of downtime)"
    reload system "$HOSTED_LABEL" "$HOSTED_PLIST"
    if healthy; then say "  hosted service healthy on the new plist"
    else
      say "  HOSTED SERVICE UNHEALTHY on the new plist: putting the old plist back"
      install -m 644 -o root -g wheel "$HOSTED_BASE/backups/hosted-plist-$STAMP.plist" "$HOSTED_PLIST"
      reload system "$HOSTED_LABEL" "$HOSTED_PLIST" || true
      healthy && say "  old plist restored, service healthy again" || say "  old plist restored, service STILL unhealthy: check /var/dexhosted/logs"
      rm -f "$tmp"; die "hosted health check failed after the plist change; rolled back (the runtime and deployer files stay installed)"
    fi
  fi
  rm -f "$tmp"
  # the daemon no longer reads $HOSTED_SVC/app, and nothing else needs it (no compatibility symlink): move it aside, never delete it
  if [ -d "$HOSTED_SVC/app" ] && [ ! -L "$HOSTED_SVC/app" ] && [ "$(plutil -extract WorkingDirectory raw -o - "$HOSTED_PLIST")" = "$HOSTED_BASE/current" ]; then
    mv "$HOSTED_SVC/app" "$HOSTED_SVC/app.replaced-$STAMP"; say "  old code moved to $HOSTED_SVC/app.replaced-$STAMP (delete it yourself once happy)"
  fi
else
  say "  WARNING: $HOSTED_PLIST not found; set WorkingDirectory to $HOSTED_BASE/current when you create it"
fi
# the nightly backup also runs as the service user with PATH starting at /opt/homebrew/bin (sqlite3, tar, rsync: all in /usr/bin): same hole, same fix
BK_LABEL=in.dextron04.agentvault-hosted-backup; BK_PLIST=/Library/LaunchDaemons/$BK_LABEL.plist
if [ -f "$BK_PLIST" ] && case $(plutil -extract EnvironmentVariables.PATH raw -o - "$BK_PLIST" 2>/dev/null || true) in *homebrew*) true;; *) false;; esac; then
  cp -p "$BK_PLIST" "$HOSTED_BASE/backups/hosted-backup-plist-$STAMP.plist"
  plutil -replace EnvironmentVariables.PATH -string /usr/bin:/bin:/usr/sbin:/sbin "$BK_PLIST"; plutil -lint "$BK_PLIST" >/dev/null
  chown root:wheel "$BK_PLIST"; chmod 644 "$BK_PLIST"
  say "  backup job PATH is now system dirs only (backup: $HOSTED_BASE/backups/hosted-backup-plist-$STAMP.plist)"
  reload system "$BK_LABEL" "$BK_PLIST" || say "  WARNING: could not reload $BK_LABEL"
fi
if [ "$HOSTED_NEW" = 1 ] && [ "$DEPLOY_NOW" = 0 ]; then : > "$HOSTED_BASE/deploy-paused"; fi
D=/Library/LaunchDaemons/in.dextron04.dex-deployer-hosted.plist
render "$PREFIX/hosted.plist.template" "$D"; chown root:wheel "$D"; chmod 644 "$D"; plutil -lint "$D" >/dev/null
reload system in.dextron04.dex-deployer-hosted "$D"

if [ "$SKIP_PERSONAL" = 0 ] && [ -d "$PERSONAL_BASE" ]; then
  say "3. Personal connector: $PERSONAL_BASE (user $PERSONAL_USER)"
  PUID=$(id -u "$PERSONAL_USER")
  PERSONAL_NEW=0; [ -f "$PERSONAL_HOME/Library/LaunchAgents/in.dextron04.dex-deployer-personal.plist" ] || PERSONAL_NEW=1
  # all file work in that user's tree happens as that user (see personal_files): root never chowns, chmods or writes there
  pa /bin/bash "$PREFIX/install-deployer.sh" --personal-files "$PERSONAL_BASE" "$PERSONAL_HOME" "$PREFIX" "$PERSONAL_NEW" "$DEPLOY_NOW"
  A=$PERSONAL_HOME/Library/LaunchAgents/in.dextron04.dex-deployer-personal.plist
  launchctl bootout "gui/$PUID/in.dextron04.agentvault-deploy" 2>/dev/null || true
  reload "gui/$PUID" in.dextron04.dex-deployer-personal "$A" || say "  WARNING: could not load the agent into gui/$PUID (is $PERSONAL_USER logged in?). Log in and: launchctl bootstrap gui/$PUID $A"
else
  say "3. Personal connector skipped"
fi

if [ "$DEPLOY_NOW" = 1 ]; then
  say "4. --deploy-now: enabling and kicking the deployers"
  rm -f "$HOSTED_BASE/deploy-paused"; launchctl kickstart "system/in.dextron04.dex-deployer-hosted" || true
  if [ -d "$PERSONAL_BASE" ] && [ "$SKIP_PERSONAL" = 0 ]; then pa /bin/rm -f "$PERSONAL_BASE/deploy-paused"; launchctl kickstart "gui/$PUID/in.dextron04.dex-deployer-personal" || true; fi
fi

say; say "Summary"
ls -ld "$PREFIX" "$PREFIX/dex-deployer.sh" "$PREFIX/targets/"*.conf
for b in "$HOSTED_BASE" "$PERSONAL_BASE"; do
  [ -d "$b" ] || continue
  say "  $b: current -> $(readlink "$b/current" 2>/dev/null || echo MISSING); app -> $(readlink "$b/app" 2>/dev/null || echo plain)"
  [ -e "$b/deploy-paused" ] && say "    PAUSED: nothing deploys until: rm $b/deploy-paused" || say "    deployer active"
done
launchctl print system/in.dextron04.dex-deployer-hosted >/dev/null 2>&1 && say "  hosted deployer loaded" || say "  hosted deployer NOT loaded"
say "  hosted health: GET /healthz -> $(curl -s -o /dev/null -m 5 -w '%{http_code}' http://127.0.0.1:8766/healthz || true)"
say "  hosted daemon program: $(plutil -extract ProgramArguments.0 raw -o - "$HOSTED_PLIST" 2>/dev/null || echo unknown)"
say "  interpreter ownership chain:"; p=$PY_BIN; while :; do ls -ld "$p" | sed 's/^/    /'; [ "$p" = / ] && break; p=${p%/*}; [ -n "$p" ] || p=/; done
say "  deployer plist PATH: $(plutil -extract EnvironmentVariables.PATH raw -o - "$D" 2>/dev/null || echo unknown)"
say "  hosted service data (untouched): $HOSTED_SVC/data, $HOSTED_SVC/logs"
say "  hosted daemon working directory: $(plutil -extract WorkingDirectory raw -o - "$HOSTED_PLIST" 2>/dev/null || echo unknown)"
say "Logs: <base>/logs/deploy.log. Details: docs/deploy-pipeline.md"
