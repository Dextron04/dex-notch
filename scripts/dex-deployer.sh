#!/usr/bin/env bash
# Pull-based deployer for one Dex Notch server (a "target"). Usage: dex-deployer.sh TARGET.conf
# Polls GitHub unauthenticated (no secret on the mini), deploys the master head only when CI's `test` job passed,
# tests the tarball as the unprivileged service user, switches <base>/current atomically, restarts, health-checks and rolls back.
# bash 3.2 compatible (macOS /bin/bash). Config is parsed key by key, never sourced or eval'd. See docs/deploy-pipeline.md.
set -euo pipefail
umask 022
PATH="/opt/homebrew/bin:/usr/local/bin:${PATH:-/usr/bin:/bin}"

die() { printf 'dex-deployer: %s\n' "$2" >&2; exit "$1"; }
re() { [[ $1 =~ $2 ]]; }

# ---- config -----------------------------------------------------------------------------------------------------
CONF=${1:-}
[ -n "$CONF" ] && [ -f "$CONF" ] || die 2 "usage: dex-deployer.sh TARGET.conf"
NAME="" REPO="" BRANCH=master CI_JOB=test LABEL="" DOMAIN="" BASE="" BASE_SUFFIX="" RUN_USER="" RELEASE_OWNER=""
SRC_SUBDIR="" TEST_DIR="" KEEP=5 HEALTH_TIMEOUT=30 TEST_TIMEOUT=900 NOTIFY=""
HEALTH=(); NHEALTH=0
while IFS= read -r line || [ -n "$line" ]; do
  case $line in ''|'#'*) continue;; esac
  key=${line%%=*}; val=${line#*=}
  [ "$key" != "$line" ] || die 2 "bad config line (want key=value)"
  val=${val//@UID@/$(id -u)}; val=${val//@HOME@/${HOME:-}}
  case $key in
    name) NAME=$val;; repo) REPO=$val;; branch) BRANCH=$val;; ci_job) CI_JOB=$val;; label) LABEL=$val;; domain) DOMAIN=$val;;
    base) BASE=$val;; base_suffix) BASE_SUFFIX=$val;; run_user) RUN_USER=$val;; release_owner) RELEASE_OWNER=$val;;
    src_subdir) SRC_SUBDIR=$val;; test_dir) TEST_DIR=$val;; keep) KEEP=$val;; health_timeout) HEALTH_TIMEOUT=$val;;
    test_timeout) TEST_TIMEOUT=$val;; notify) NOTIFY=$val;;
    health) HEALTH[$NHEALTH]=$val; NHEALTH=$((NHEALTH+1));;
    *) die 2 "unknown config key: $key";;
  esac
done < "$CONF"

re "$NAME" '^[a-z0-9-]+$'                       || die 2 "config: bad name"
re "$REPO" '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$'  || die 2 "config: bad repo"
re "$BRANCH" '^[A-Za-z0-9._/-]+$'               || die 2 "config: bad branch"
re "$CI_JOB" '^[A-Za-z0-9._ -]+$'               || die 2 "config: bad ci_job"
re "$LABEL" '^[A-Za-z0-9._-]+$'                 || die 2 "config: bad label"
re "$DOMAIN" '^(system|gui/[0-9]+)$'            || die 2 "config: domain must be system or gui/<uid>"
re "$RUN_USER" '^[A-Za-z0-9._-]+$'              || die 2 "config: bad run_user"
re "$KEEP" '^[0-9]+$' && [ "$KEEP" -ge 2 ]      || die 2 "config: keep must be >= 2 (current + previous)"
re "$HEALTH_TIMEOUT" '^[0-9]+$'                 || die 2 "config: bad health_timeout"
re "$TEST_TIMEOUT" '^[0-9]+$'                   || die 2 "config: bad test_timeout"
[ -z "$RELEASE_OWNER" ] || re "$RELEASE_OWNER" '^[A-Za-z0-9._-]+(:[A-Za-z0-9._-]+)?$' || die 2 "config: bad release_owner"
[ "$NHEALTH" -ge 1 ] || die 2 "config: at least one health= line"
for p in "$SRC_SUBDIR" "$TEST_DIR"; do
  re "$p" '^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$' && [[ $p != *..* ]] || die 2 "config: bad source path '$p'"
done
[[ $SRC_SUBDIR == "$TEST_DIR"/* ]] || die 2 "config: src_subdir must sit inside test_dir"

# ---- refuse a dangerous base before touching anything --------------------------------------------------------------
while [ "${#BASE}" -gt 1 ] && [ "${BASE%/}" != "$BASE" ]; do BASE=${BASE%/}; done
[ -n "$BASE" ] && [ -n "$BASE_SUFFIX" ] || die 2 "refusing to run: empty base"
[ "$BASE" != "/" ]                      || die 2 "refusing to run: base is /"
{ re "$BASE" '^/[A-Za-z0-9._/-]+$' && [[ $BASE != *..* ]]; } || die 2 "refusing to run: base '$BASE' is not a plain absolute path"
[ "${BASE##*/}" = "$BASE_SUFFIX" ]      || die 2 "refusing to run: base '$BASE' does not end in /$BASE_SUFFIX"
{ [ -d "$BASE" ] && [ ! -L "$BASE" ]; } || die 2 "refusing to run: $BASE is not a directory (run install-deployer.sh first)"

BASE=$(cd "$BASE" && pwd -P)             # resolve system symlinks such as /var -> /private/var; below this, no component may be a symlink
[ "${BASE##*/}" = "$BASE_SUFFIX" ]      || die 2 "refusing to run: canonical base '$BASE' does not end in /$BASE_SUFFIX"

# ---- the tree this script works in must be ours: real directories, not group/world-writable, owned by root (as root) or by us ----
ME=$(id -u)
if [ "$(uname)" = Darwin ]; then fstat() { stat -f '%u %Lp' "$1"; }; else fstat() { stat -c '%u %a' "$1"; }; fi
dir_ok() {   # real directory (not a symlink), owned by the running user, no group/world write
  local o m
  { [ -d "$1" ] && [ ! -L "$1" ]; } || return 1
  read -r o m <<< "$(fstat "$1")" || return 1
  [ "$o" = "$ME" ] && [ $((8#$m & 8#22)) -eq 0 ]
}
BADPATH=""
tree_ok() {   # base, its working subdirs and every release dir; as root also every ancestor of base (a symlinked or writable parent would redirect root)
  local p=$BASE e
  if [ "$ME" = 0 ]; then
    while [ "$p" != / ]; do dir_ok "$p" || { BADPATH=$p; return 1; }; p=${p%/*}; [ -n "$p" ] || p=/; done
  else dir_ok "$BASE" || { BADPATH=$BASE; return 1; }; fi
  for e in logs releases tmp; do
    if [ -L "$BASE/$e" ]; then BADPATH=$BASE/$e; return 1; fi
    if [ -e "$BASE/$e" ]; then dir_ok "$BASE/$e" || { BADPATH=$BASE/$e; return 1; }; fi
  done
  for e in "$BASE"/releases/*; do
    if [ -L "$e" ]; then BADPATH=$e; return 1; fi
    if [ -d "$e" ]; then dir_ok "$e" || { BADPATH=$e; return 1; }; fi
  done
  return 0
}
if [ -L "$BASE/logs" ] || [ -L "$BASE/releases" ] || [ -L "$BASE/tmp" ]; then
  printf 'dex-deployer: refusing to run: a working directory under %s is a symlink\n' "$BASE" >&2; exit 2
fi
for d in logs releases tmp; do [ -e "$BASE/$d" ] || mkdir "$BASE/$d"; done
tree_ok || { printf 'dex-deployer: refusing to run: %s is a symlink, not a real directory, not owned by us, or group/world-writable\n' "$BADPATH" >&2; exit 2; }

API=${DEX_API_URL:-https://api.github.com}; API=${API%/}
LAUNCHCTL=${DEX_LAUNCHCTL:-launchctl}
UA="dex-deployer/1 (+https://github.com/$REPO)"
LOG=$BASE/logs/deploy.log
SEEN=$BASE/deploy-seen        # "<sha> <status> <etag>": last head looked at (deployed or rejected: never retried; delete the file to retry)
LOCK=$BASE/.deploy.lock
if [ "$(uname)" = Darwin ]; then MVLINK=(mv -fh); else MVLINK=(mv -fT); fi   # replace a symlink-to-dir in place, not move into it

log()  { printf '%s [%s] %s\n' "$(date -u '+%F %TZ')" "$NAME" "$*" >> "$LOG"; }
say()  { [ -z "${DEPLOY_HOOK:-}" ] || log "hook: $*"; }          # routine polls stay quiet; a webhook-started run says why it stopped
notify() {   # never fails the deploy. notify=osascript shows a macOS notification; notify=/path/to/cmd is run as `cmd MESSAGE` (no shell)
  [ -n "$NOTIFY" ] || return 0
  if [ "$NOTIFY" = osascript ]; then
    osascript -e 'on run argv' -e 'display notification (item 1 of argv) with title "Dex deployer"' -e 'end run' "$1" >/dev/null 2>&1 || true
  else "$NOTIFY" "$1" >/dev/null 2>&1 || true; fi
}

# ---- the only places that delete anything -----------------------------------------------------------------------
rm_release() {   # a release NAME under <base>/releases; prune never passes current or previous
  local n=$1 p
  case $n in ''|.|..|*/*|*[!0-9A-Za-z._-]*) return 1;; esac
  p="$BASE/releases/$n"
  { dir_ok "$BASE" && dir_ok "$BASE/releases"; } || return 1       # the parent was just checked
  { [[ $p == "$BASE/releases/"* ]] && [ -d "$p" ] && [ ! -L "$p" ]; } || return 1
  chmod -R u+w "$p" && rm -rf -- "$p"
}
WORK=""; RUNAS=()
rm_work() {   # only our own mktemp dir: <base>/tmp/work.XXXXXX
  [ -n "$WORK" ] || return 0
  case $WORK in "$BASE"/tmp/work.*) ;; *) return 0;; esac
  case ${WORK#"$BASE/tmp/"} in */*|*..*) return 0;; esac
  { dir_ok "$BASE" && dir_ok "$BASE/tmp" && dir_ok "$WORK"; } || return 0
  if [ -e "$WORK/state" ]; then       # the service user's writable area: only that user removes it, so root never walks into it
    "${RUNAS[@]}" rm -rf -- "$WORK/state" 2>/dev/null || true
    [ ! -e "$WORK/state" ] || return 0
  fi
  chmod -R u+w "$WORK" 2>/dev/null || true
  rm -rf -- "$WORK"
}
HAVE_LOCK=0
cleanup() { rm_work; if [ "$HAVE_LOCK" = 1 ]; then rmdir "$LOCK" 2>/dev/null || true; fi; }
trap cleanup EXIT
trap 'exit 130' INT TERM

# ---- helpers ----------------------------------------------------------------------------------------------------
run_timeout() {   # SECONDS cmd...: kill cmd after SECONDS. The watchdog gets no stdio so it can't hold a caller's pipe open.
  local secs=$1 pid w rc=0; shift
  "$@" & pid=$!
  ( exec >/dev/null 2>&1; sleep "$secs"; kill "$pid" ) & w=$!
  wait "$pid" || rc=$?
  pkill -P "$w" 2>/dev/null || true; kill "$w" 2>/dev/null || true; wait "$w" 2>/dev/null || true
  return "$rc"
}
tree_hash() {   # content hash of a source dir (paths + bytes), ignoring bytecode
  ( cd "$1" && find . -type f ! -path '*/__pycache__/*' ! -name '*.pyc' -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256 | shasum -a 256 | cut -d' ' -f1 )
}
has_files() { [ -n "$(find "$1" -type f ! -name '*.pyc' -print -quit 2>/dev/null)" ]; }
record_seen() { printf '%s %s %s\n' "$1" "$2" "${ETAG:-}" > "$SEEN.tmp" && mv -f "$SEEN.tmp" "$SEEN"; }
current_release() {   # name of the release `current` points at, or empty
  local t; t=$(readlink "$BASE/current" 2>/dev/null) || return 0
  case $t in releases/*) t=${t#releases/}; if re "$t" '^[0-9A-Za-z._-]+$'; then printf '%s' "$t"; fi;; esac
  return 0
}
switch_to() {   # atomic: build a temp symlink beside current, then rename it over current
  local tmp="$BASE/.current.tmp.$$"
  if [ -e "$BASE/current" ] && [ ! -L "$BASE/current" ]; then log "current is a real directory; run install-deployer.sh to migrate"; return 1; fi
  ln -sfn "releases/$1" "$tmp" && "${MVLINK[@]}" "$tmp" "$BASE/current"
}
restart() { "$LAUNCHCTL" kickstart -k "$DOMAIN/$LABEL" >> "$LOG" 2>&1; }
HEALTH_FAIL=""
health_ok() {
  local spec method url want code
  for spec in "${HEALTH[@]}"; do
    read -r method url want <<< "$spec"
    if [ "$method" = POST ]; then code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d '{}' "$url") || code=000
    else code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' "$url") || code=000; fi
    [ "$code" = "$want" ] || { HEALTH_FAIL="$method $url answered $code, wanted $want"; return 1; }
  done
}
wait_healthy() {   # retries for HEALTH_TIMEOUT seconds
  local end=$(( $(date +%s) + HEALTH_TIMEOUT ))
  while ! health_ok; do [ "$(date +%s)" -lt "$end" ] || return 1; sleep 1; done
}
prune() {
  tree_ok || { log "REFUSED to prune: $BADPATH is not a plain directory of ours"; return 0; }   # keep the newest KEEP releases, and never remove current or the one just before it
  local names=() n cur prev="" i total
  for n in $(ls -1 "$BASE/releases" | LC_ALL=C sort); do if re "$n" '^[0-9]{8}T[0-9]{6}Z-[0-9a-z]+$'; then names[${#names[@]}]=$n; fi; done
  total=${#names[@]}; cur=$(current_release)
  for ((i=0; i<total; i++)); do
    if [ "${names[$i]}" = "$cur" ] && [ "$i" -gt 0 ]; then prev=${names[$((i-1))]}; fi
  done
  for ((i=0; i<total-KEEP; i++)); do
    n=${names[$i]}
    if [ "$n" != "$cur" ] && [ "$n" != "$prev" ]; then rm_release "$n" && log "pruned $n"; fi
  done
  return 0
}

# ---- 1. pause switch and lock -----------------------------------------------------------------------------------
if [ -e "$BASE/deploy-paused" ]; then say "paused (remove $BASE/deploy-paused)"; exit 0; fi
find "$LOCK" -maxdepth 0 -mmin +30 -exec rmdir {} \; 2>/dev/null || true       # a crashed run's lock
mkdir "$LOCK" 2>/dev/null || { log "another deploy holds the lock"; exit 0; }
HAVE_LOCK=1
say "started"
if [ "$(id -u)" = 0 ]; then
  [ "$RUN_USER" != root ] || die 2 "refusing to run tests as root: set run_user to the service user"
  RUNAS=(sudo -n -u "$RUN_USER")
else
  [ "$(id -un)" = "$RUN_USER" ] || die 2 "must run as root or as $RUN_USER"
  RUNAS=(env)
fi
WORK=$(mktemp -d "$BASE/tmp/work.XXXXXX"); chmod 755 "$WORK"

# ---- 2. master head and its CI result ---------------------------------------------------------------------------
seen_sha="" seen_status="" seen_etag=""
if [ -f "$SEEN" ]; then read -r seen_sha seen_status seen_etag < "$SEEN" || true; fi
re "$seen_etag" '^(W/)?"[A-Za-z0-9._-]+"$' || seen_etag=""
ETAG=""
hdr=(-H 'Accept: application/vnd.github+json')
if [ -n "$seen_etag" ]; then hdr[${#hdr[@]}]=-H; hdr[${#hdr[@]}]="If-None-Match: $seen_etag"; fi   # a 304 costs no rate limit
code=$(curl -sS --max-time 20 -A "$UA" "${hdr[@]}" -D "$WORK/head.h" -o "$WORK/head.json" -w '%{http_code}' "$API/repos/$REPO/commits/$BRANCH" 2>>"$LOG") || code=000
if [ "$code" = 304 ]; then say "head unchanged"; exit 0; fi
if [ "$code" != 200 ]; then say "GitHub API answered $code for the head commit"; exit 0; fi       # offline or rate limited: try again later
sha=$(python3 -I -c 'import json,sys; print(json.load(sys.stdin)["sha"])' < "$WORK/head.json" 2>/dev/null) || sha=""
re "$sha" '^[0-9a-f]{40}$' || { log "head commit answer had no sha"; exit 0; }
ETAG=$(grep -i '^etag:' "$WORK/head.h" | head -n1 | cut -d' ' -f2- | tr -d '\r\n') || ETAG=""
re "$ETAG" '^(W/)?"[A-Za-z0-9._-]+"$' || ETAG=""
s7=${sha:0:7}
if [ "$sha" = "$seen_sha" ]; then say "$s7 already handled ($seen_status)"; exit 0; fi

code=$(curl -sS --max-time 20 -A "$UA" -H 'Accept: application/vnd.github+json' -o "$WORK/ci.json" -w '%{http_code}' "$API/repos/$REPO/commits/$sha/check-runs?per_page=100" 2>>"$LOG") || code=000
if [ "$code" != 200 ]; then say "GitHub API answered $code for check runs"; exit 0; fi
ci=$(python3 -I -c '
import json, sys
runs = [c for c in json.load(sys.stdin).get("check_runs", []) if c.get("name") == sys.argv[1] and (c.get("app") or {}).get("slug") == "github-actions"]
if not runs: print("none")
else:
    c = max(runs, key=lambda c: c.get("id", 0))
    print(c["conclusion"] if c.get("status") == "completed" and c.get("conclusion") else "pending")
' "$CI_JOB" < "$WORK/ci.json" 2>/dev/null) || ci=none
re "$ci" '^[a-z_]+$' || ci=none
case $ci in pending|none) say "$s7 CI is $ci"; exit 0;; esac        # not finished yet: look again next poll
if [ "$ci" != success ]; then log "skip $s7: CI is $ci"; record_seen "$sha" "skipped-ci-$ci"; exit 0; fi

# ---- 3. tarball for that exact sha ------------------------------------------------------------------------------
curl -fsSL --max-time 180 --max-filesize 200000000 -A "$UA" -o "$WORK/src.tgz" "$API/repos/$REPO/tarball/$sha" 2>>"$LOG" || { log "download failed for $s7"; exit 0; }
reject_tarball() { log "REJECTED $s7: $1"; record_seen "$sha" rejected-tarball; exit 1; }
tar -tzf "$WORK/src.tgz" > "$WORK/list.txt" 2>>"$LOG" || reject_tarball "tarball unreadable"
if tar -tvzf "$WORK/src.tgz" 2>/dev/null | grep -q '^[lh]'; then reject_tarball "tarball contains links"; fi
if grep -qE '(^/|(^|/)\.\.(/|$))' "$WORK/list.txt"; then reject_tarball "tarball has unsafe paths"; fi
top=$(head -n1 "$WORK/list.txt"); top=${top%%/*}
{ re "$top" '^[A-Za-z0-9._-]+$' && [[ $top == *"$s7"* ]]; } || reject_tarball "top dir '$top' does not carry the sha"
mkdir "$WORK/pristine"
tar -xzf "$WORK/src.tgz" -C "$WORK/pristine" "$top/$TEST_DIR" 2>>"$LOG" || reject_tarball "no $TEST_DIR in tarball"
PRIS=$WORK/pristine/$top
{ [ -d "$PRIS/$SRC_SUBDIR" ] && has_files "$PRIS/$SRC_SUBDIR"; } || reject_tarball "no $SRC_SUBDIR in tarball"

# ---- 4. anything new? -------------------------------------------------------------------------------------------
new_hash=$(tree_hash "$PRIS/$SRC_SUBDIR")
cur=$(current_release); PREV=$cur
if [ -n "$cur" ] && [ -f "$BASE/releases/$cur/.source-sha256" ] && [ "$(cat "$BASE/releases/$cur/.source-sha256")" = "$new_hash" ]; then
  log "$s7: no change under $SRC_SUBDIR since $cur"; record_seen "$sha" unchanged; exit 0
fi

# ---- 5. test before switching, as the service user, never root -----------------------------------------------------
# code under test: root-owned, readable by the service user. Its writable state (TMPDIR, HOME) is a separate dir owned by that user.
mkdir "$WORK/test" "$WORK/state" && cp -R "$PRIS/$TEST_DIR" "$WORK/test/$TEST_DIR"
if [ "$ME" = 0 ]; then chown "$RUN_USER" "$WORK/state"; fi
chmod 700 "$WORK/state"
"${RUNAS[@]}" mkdir "$WORK/state/tmp" "$WORK/state/home"
log "testing $s7 as $RUN_USER"
tests_ok=1
( cd "$WORK/test/$TEST_DIR" && run_timeout "$TEST_TIMEOUT" "${RUNAS[@]}" env -i PATH="$PATH" HOME="$WORK/state/home" TMPDIR="$WORK/state/tmp" LANG=en_US.UTF-8 PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests ) > "$WORK/test.log" 2>&1 || tests_ok=0
if [ "$tests_ok" = 0 ]; then
  log "REJECTED $s7: tests failed (last lines follow)"; tail -n 12 "$WORK/test.log" >> "$LOG"
  record_seen "$sha" rejected-tests; notify "Rejected $s7 on $NAME: tests failed"; exit 1
fi

# ---- 6. unpack into a new release ---------------------------------------------------------------------------------
rel_name="${DEX_TIMESTAMP:-$(date -u +%Y%m%dT%H%M%SZ)}-$s7"   # DEX_TIMESTAMP: test hook only
re "$rel_name" '^[0-9]{8}T[0-9]{6}Z-[0-9a-z]+$' || die 2 "bad release name $rel_name"
REL=$BASE/releases/$rel_name
tree_ok || { log "REFUSED: $BADPATH changed under us (symlink, owner or permissions); nothing switched"; exit 2; }
if [ -e "$REL" ]; then rm_release "$rel_name" || { log "release $rel_name exists and cannot be replaced"; exit 1; }; fi
if ! { mkdir "$REL" && cp -R "$PRIS/$SRC_SUBDIR" "$REL/agentvault"; }; then rm_release "$rel_name" || true; log "unpack failed for $s7"; exit 1; fi
printf '%s\n' "$new_hash" > "$REL/.source-sha256"; printf '%s\n' "$sha" > "$REL/.commit"
if [ -n "$RELEASE_OWNER" ] && [ "$(id -u)" = 0 ]; then chown -R "$RELEASE_OWNER" "$REL"; fi
chmod -R u+w,go-w,a+rX "$REL"       # root-owned (hosted) 644/755: the service can read, not change

# ---- 7-9. switch, restart, health, roll back ----------------------------------------------------------------------
fail_reason=""
if ! switch_to "$rel_name"; then fail_reason="could not switch current"
elif ! restart; then fail_reason="launchctl kickstart failed"
elif ! wait_healthy; then fail_reason="health check failed: $HEALTH_FAIL"; fi
if [ -n "$fail_reason" ]; then
  record_seen "$sha" rejected-health
  if [ -z "$PREV" ] || [ ! -d "$BASE/releases/$PREV" ]; then
    log "FAILED $s7: $fail_reason; no previous release to roll back to"; notify "Deploy of $s7 on $NAME failed and there is nothing to roll back to"; exit 1
  fi
  { switch_to "$PREV" && restart; } || true
  if wait_healthy; then log "ROLLED BACK $s7 -> $PREV: $fail_reason"; notify "Rolled back $s7 on $NAME: $fail_reason"
  else log "ROLLED BACK $s7 -> $PREV: $fail_reason; STILL UNHEALTHY after rollback: $HEALTH_FAIL"; notify "Rollback on $NAME did not recover: $HEALTH_FAIL"; fi
  exit 1
fi
log "deployed $s7 as $rel_name (was ${PREV:-nothing})"
record_seen "$sha" deployed

# ---- 10. prune ----------------------------------------------------------------------------------------------------
prune
exit 0
