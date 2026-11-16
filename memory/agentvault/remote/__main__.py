import argparse, os, subprocess
from pathlib import Path
from .oauth import OAuthStore
from .server import make_server

def main() -> None:
    ap = argparse.ArgumentParser(description="Remote MCP connector for the shared vault")
    ap.add_argument("--vault", required=True); ap.add_argument("--state", required=True, help="oauth state file")
    ap.add_argument("--passphrase-file", required=True); ap.add_argument("--public-url", required=True)
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--deploy-secret-file", help="shared secret of GitHub's webhook; with --deploy-script, switches on POST /hooks/deploy")
    ap.add_argument("--reminder-key-file", help="secret the laptop uses to hold GET /reminders/wait open (instant reminders)")
    ap.add_argument("--deploy-script", help="run (detached) when GitHub reports a green CI run on master")
    a = ap.parse_args()
    pw = Path(a.passphrase_file).expanduser().read_text().strip()
    if len(pw) < 12: raise SystemExit("passphrase must be at least 12 characters")
    secret, script = b"", None
    if a.deploy_secret_file and a.deploy_script:
        secret = Path(a.deploy_secret_file).expanduser().read_text().strip().encode()
        if len(secret) < 20: raise SystemExit("deploy secret must be at least 20 characters")
        script = str(Path(a.deploy_script).expanduser())
    # new session: the deploy restarts this very process, and must outlive it to finish (or roll back)
    def on_deploy():
        log = open(Path(script).parent / "logs" / "deploy.err", "ab")          # the script's own errors, not lost with the request
        subprocess.Popen(["/bin/zsh", script], start_new_session=True, stdin=subprocess.DEVNULL, stdout=log, stderr=log, env={**os.environ, "DEPLOY_HOOK": "1"})
    if not script: on_deploy = None
    rkey = b""
    if a.reminder_key_file:
        rkey = Path(a.reminder_key_file).expanduser().read_text().strip().encode()
        if len(rkey) < 20: raise SystemExit("reminder key must be at least 20 characters")
    srv = make_server(Path(a.vault).expanduser(), OAuthStore(Path(a.state).expanduser()), pw, a.public_url, a.port, deploy_secret=secret, on_deploy=on_deploy, reminder_key=rkey)
    print("agentvault remote on 127.0.0.1:%d as %s" % (a.port, a.public_url), flush=True)
    srv.serve_forever()

if __name__ == "__main__":
    main()
