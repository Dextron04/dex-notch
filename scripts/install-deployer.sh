#!/usr/bin/env bash
# One-time (and safe to re-run) installer of the Dex deployer on the Mac mini. Run as root from a checkout of the repo:
#   sudo scripts/install-deployer.sh [--deploy-now] [--skip-personal]
# It does NOT start a deploy: a fresh install leaves each target paused (<base>/deploy-paused) until you pass --deploy-now
# or remove that file. Internal helper:  scripts/install-deployer.sh --migrate-only BASE   (just the current-symlink migration)
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

HERE=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$HERE/.." && pwd)
PREFIX=/usr/local/dex-deployer
HOSTED_BASE=/var/dexhosted
HOSTED_LABEL=in.dextron04.agentvault-hosted
HOSTED_PLIST=/Library/LaunchDaemons/$HOSTED_LABEL.plist
PERSONAL_USER=mac-agent
PERSONAL_HOME=${DEX_PERSONAL_HOME:-/Users/$PERSONAL_USER}
PERSONAL_BASE=$PERSONAL_HOME/agentvault
STAMP=$(date -u +%Y%m%dT%H%M%SZ)

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
  say "  $base: migrated. backup $bk; current -> releases/$name; app -> current"
}

if [ "${1:-}" = --migrate-only ]; then migrate_layout "${2:-}"; exit 0; fi

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
render() { sed -e "s|__PREFIX__|$PREFIX|g" -e "s|__HOME__|$PERSONAL_HOME|g" "$1" > "$2"; }

say "1. Installing scripts to $PREFIX (root:wheel)"
install -d -m 755 -o root -g wheel "$PREFIX" "$PREFIX/targets"
install -m 755 -o root -g wheel "$HERE/dex-deployer.sh" "$PREFIX/dex-deployer.sh"
install -m 755 -o root -g wheel "$HERE/connector-deploy.sh" "$PREFIX/connector-deploy.sh"
for c in hosted personal; do install -m 644 -o root -g wheel "$HERE/deploy-targets/$c.conf" "$PREFIX/targets/$c.conf"; done
install -m 644 -o root -g wheel "$REPO_ROOT/memory/launchd/in.dextron04.dex-deployer-hosted.plist.template" "$PREFIX/hosted.plist.template"
install -m 644 -o root -g wheel "$REPO_ROOT/memory/launchd/in.dextron04.dex-deployer-personal.plist.template" "$PREFIX/personal.plist.template"

say "2. Hosted: $HOSTED_BASE"
[ -d "$HOSTED_BASE" ] || die "$HOSTED_BASE missing: do docs/hosted-isolation.md first"
HOSTED_NEW=0; [ -f /Library/LaunchDaemons/in.dextron04.dex-deployer-hosted.plist ] || HOSTED_NEW=1
migrate_layout "$HOSTED_BASE"
chown root:wheel "$HOSTED_BASE/releases"; chmod 755 "$HOSTED_BASE/releases"
mkdir -p "$HOSTED_BASE/tmp"; chown _dexhosted:_dexhosted "$HOSTED_BASE/tmp"; chmod 700 "$HOSTED_BASE/tmp"
if [ -f "$HOSTED_PLIST" ]; then
  tmp=$(mktemp "${TMPDIR:-/tmp}/hosted-plist.XXXXXX")
  cp "$HOSTED_PLIST" "$tmp"
  plutil -replace WorkingDirectory -string "$HOSTED_BASE/current" "$tmp"
  plutil -lint "$tmp" >/dev/null
  if cmp -s <(plutil -convert xml1 -o - "$HOSTED_PLIST") <(plutil -convert xml1 -o - "$tmp"); then
    say "  $HOSTED_PLIST already uses $HOSTED_BASE/current"
  else
    cp -p "$HOSTED_PLIST" "$HOSTED_BASE/backups/hosted-plist-$STAMP.plist"
    say "  plist change (backup: $HOSTED_BASE/backups/hosted-plist-$STAMP.plist):"
    diff -u <(plutil -convert xml1 -o - "$HOSTED_PLIST") <(plutil -convert xml1 -o - "$tmp") || true
    install -m 644 -o root -g wheel "$tmp" "$HOSTED_PLIST"
    say "  restarting the hosted service on the new plist (a few seconds of downtime)"
    reload system "$HOSTED_LABEL" "$HOSTED_PLIST"
  fi
  rm -f "$tmp"
else
  say "  WARNING: $HOSTED_PLIST not found; set WorkingDirectory to $HOSTED_BASE/current when you create it"
fi
if [ "$HOSTED_NEW" = 1 ] && [ "$DEPLOY_NOW" = 0 ]; then : > "$HOSTED_BASE/deploy-paused"; fi
D=/Library/LaunchDaemons/in.dextron04.dex-deployer-hosted.plist
render "$PREFIX/hosted.plist.template" "$D"; chown root:wheel "$D"; chmod 644 "$D"; plutil -lint "$D" >/dev/null
reload system in.dextron04.dex-deployer-hosted "$D"

if [ "$SKIP_PERSONAL" = 0 ] && [ -d "$PERSONAL_BASE" ]; then
  say "3. Personal connector: $PERSONAL_BASE (user $PERSONAL_USER)"
  PUID=$(id -u "$PERSONAL_USER"); PGID=$(id -g "$PERSONAL_USER")
  PERSONAL_NEW=0; [ -f "$PERSONAL_HOME/Library/LaunchAgents/in.dextron04.dex-deployer-personal.plist" ] || PERSONAL_NEW=1
  migrate_layout "$PERSONAL_BASE"
  mkdir -p "$PERSONAL_BASE/tmp"
  chown -h "$PUID:$PGID" "$PERSONAL_BASE/releases" "$PERSONAL_BASE/backups" "$PERSONAL_BASE/logs" "$PERSONAL_BASE/tmp"
  [ ! -L "$PERSONAL_BASE/current" ] || chown -h "$PUID:$PGID" "$PERSONAL_BASE/current"
  [ ! -L "$PERSONAL_BASE/app" ] || chown -h "$PUID:$PGID" "$PERSONAL_BASE/app"
  chown -R "$PUID:$PGID" "$PERSONAL_BASE/backups" "$PERSONAL_BASE"/releases/* 2>/dev/null || true
  # the connector's /hooks/deploy runs this path with /bin/zsh: it must stay, and now only calls the new deployer
  W=$PERSONAL_BASE/connector-deploy.sh
  if [ -f "$W" ] && ! cmp -s "$W" "$HERE/connector-deploy.sh"; then cp -p "$W" "$PERSONAL_BASE/backups/connector-deploy.sh.$STAMP"; fi
  install -m 755 -o "$PUID" -g "$PGID" "$HERE/connector-deploy.sh" "$W"
  if [ "$PERSONAL_NEW" = 1 ] && [ "$DEPLOY_NOW" = 0 ]; then : > "$PERSONAL_BASE/deploy-paused"; chown "$PUID:$PGID" "$PERSONAL_BASE/deploy-paused"; fi
  mkdir -p "$PERSONAL_HOME/Library/LaunchAgents"
  A=$PERSONAL_HOME/Library/LaunchAgents/in.dextron04.dex-deployer-personal.plist
  render "$PREFIX/personal.plist.template" "$A"; chown "$PUID:$PGID" "$A"; chmod 644 "$A"; plutil -lint "$A" >/dev/null
  OLD=$PERSONAL_HOME/Library/LaunchAgents/in.dextron04.agentvault-deploy.plist
  launchctl bootout "gui/$PUID/in.dextron04.agentvault-deploy" 2>/dev/null || true
  [ ! -f "$OLD" ] || { mv "$OLD" "$OLD.disabled-$STAMP"; say "  old poller disabled: $OLD.disabled-$STAMP"; }
  reload "gui/$PUID" in.dextron04.dex-deployer-personal "$A" || say "  WARNING: could not load the agent into gui/$PUID (is $PERSONAL_USER logged in?). Log in and: launchctl bootstrap gui/$PUID $A"
else
  say "3. Personal connector skipped"
fi

if [ "$DEPLOY_NOW" = 1 ]; then
  say "4. --deploy-now: enabling and kicking the deployers"
  rm -f "$HOSTED_BASE/deploy-paused"; launchctl kickstart "system/in.dextron04.dex-deployer-hosted" || true
  if [ -d "$PERSONAL_BASE" ] && [ "$SKIP_PERSONAL" = 0 ]; then rm -f "$PERSONAL_BASE/deploy-paused"; launchctl kickstart "gui/$PUID/in.dextron04.dex-deployer-personal" || true; fi
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
say "  hosted daemon working directory: $(plutil -extract WorkingDirectory raw -o - "$HOSTED_PLIST" 2>/dev/null || echo unknown)"
say "Logs: <base>/logs/deploy.log. Details: docs/deploy-pipeline.md"
