#!/bin/zsh
# Pull-based deploy of the vault connector (memory/agentvault) on the mini. launchd runs it every 5 minutes.
# It deploys the newest master commit whose CI "test" job passed, restarts the connector, and rolls back if the restart doesn't answer.
# Pull, not push: the repo is public, so nothing outside can reach the mini and no runner or secret is needed.
export PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin
REPO=${DEPLOY_REPO:-Dextron04/dex-notch}
BASE=${DEPLOY_BASE:-$HOME/agentvault}
APP=$BASE/app/agentvault
LABEL=in.dextron04.agentvault-remote
PORT=8765
LOG=$BASE/logs/deploy.log
SEEN=$BASE/deploy-seen     # last commit looked at (deployed, or rejected: never retried)
mkdir -p $BASE/logs $BASE/backups
log() { print -r -- "$(date '+%F %T') $*" >> $LOG }
api() { curl -fsS --max-time 20 -H 'Accept: application/vnd.github+json' "https://api.github.com/repos/$REPO/$1" }
json() { python3 -c "import json,sys; d=json.load(sys.stdin); print($1)" }

sha=$(api commits/master | json 'd["sha"]') || exit 0                 # offline or rate limited: try again later
[[ "$sha" == "$(cat $SEEN 2>/dev/null)" ]] && exit 0
ci=$(api commits/$sha/check-runs | json '(lambda r: "none" if not r else r[0]["conclusion"] or "pending")([c for c in d["check_runs"] if c["name"] == "test"])') || exit 0
[[ "$ci" == "pending" || "$ci" == "none" ]] && exit 0                 # CI hasn't finished yet
if [[ "$ci" != "success" ]]; then log "skip ${sha:0:7}: CI is $ci"; print -r -- $sha > $SEEN; exit 0; fi

tmp=$(mktemp -d); trap 'rm -rf $tmp' EXIT
curl -fsSL --max-time 120 "https://api.github.com/repos/$REPO/tarball/$sha" -o $tmp/src.tgz || { log "download failed for ${sha:0:7}"; exit 0; }
tar -xzf $tmp/src.tgz -C $tmp --strip-components=1 --exclude '__pycache__' --exclude '.claude-flow' --exclude '.swarm' '*/memory/agentvault' || { log "unpack failed"; exit 0; }
SRC=$tmp/memory/agentvault
[[ -d $SRC ]] || { log "no memory/agentvault in ${sha:0:7}"; print -r -- $sha > $SEEN; exit 0; }

changed=$(rsync -rcni --exclude __pycache__ $SRC/ $APP/ | grep -c '^<f')
if [[ "$changed" == 0 ]]; then print -r -- $sha > $SEEN; exit 0; fi   # this commit didn't touch the connector

bk=$BASE/backups/deploy-$(date +%Y%m%d-%H%M%S); mkdir -p $bk && cp -R $APP $bk/
rsync -rc --exclude __pycache__ $SRC/ $APP/
python3 -c "import sys; sys.path.insert(0, '$BASE/app'); import agentvault.remote.server" 2>>$LOG \
  || { rsync -rc --exclude __pycache__ $bk/agentvault/ $APP/; log "REJECTED ${sha:0:7}: does not import; rolled back"; print -r -- $sha > $SEEN; exit 0; }
launchctl kickstart -k gui/$(id -u)/$LABEL; sleep 6
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -X POST http://127.0.0.1:$PORT/mcp -d '{}')
if [[ "$code" != 401 ]]; then        # a healthy connector refuses an unauthenticated call
  rsync -rc --exclude __pycache__ $bk/agentvault/ $APP/; launchctl kickstart -k gui/$(id -u)/$LABEL
  log "REJECTED ${sha:0:7}: connector answered $code after restart; rolled back to $bk"; print -r -- $sha > $SEEN; exit 0
fi
log "deployed ${sha:0:7} ($changed files)"; print -r -- $sha > $SEEN
ls -1dt $BASE/backups/deploy-* | tail -n +6 | xargs rm -rf          # keep the last five backups
