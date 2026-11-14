import argparse
from pathlib import Path
from .oauth import OAuthStore
from .server import make_server

def main() -> None:
    ap = argparse.ArgumentParser(description="Remote MCP connector for the shared vault")
    ap.add_argument("--vault", required=True); ap.add_argument("--state", required=True, help="oauth state file")
    ap.add_argument("--passphrase-file", required=True); ap.add_argument("--public-url", required=True)
    ap.add_argument("--port", type=int, default=8765)
    a = ap.parse_args()
    pw = Path(a.passphrase_file).expanduser().read_text().strip()
    if len(pw) < 12: raise SystemExit("passphrase must be at least 12 characters")
    srv = make_server(Path(a.vault).expanduser(), OAuthStore(Path(a.state).expanduser()), pw, a.public_url, a.port)
    print("agentvault remote on 127.0.0.1:%d as %s" % (a.port, a.public_url), flush=True)
    srv.serve_forever()

if __name__ == "__main__":
    main()
