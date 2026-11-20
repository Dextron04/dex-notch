"""Runs scripts/dex-deployer.sh against a temp base dir, a fake GitHub API and a fake service restarted by a stub `launchctl`."""
import getpass, hashlib, io, json, os, shutil, socket, subprocess, sys, tarfile, tempfile, threading, unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
BASH = "/bin/bash" if os.path.exists("/bin/bash") else "bash"   # the mini runs the plists with /bin/bash (3.2 on macOS)
SCRIPT = REPO_ROOT / "scripts" / "dex-deployer.sh"
INSTALLER = REPO_ROOT / "scripts" / "install-deployer.sh"

FAKE_SERVICE = """
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
port, mode = int(sys.argv[1]), sys.argv[2]
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _send(self, code): self.send_response(code); self.send_header("Content-Length", "0"); self.end_headers()
    def do_GET(self): self._send(200 if mode == "ok" and self.path == "/healthz" else 500)
    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length") or 0)); self._send(401 if mode == "ok" else 500)
HTTPServer(("127.0.0.1", port), H).serve_forever()
"""

# stands in for launchctl: `kickstart -k <domain>/<label>` restarts the fake service, in the mode the new `current` asks for
STUB_LAUNCHCTL = """#!/bin/bash
echo "$@" >> "$DEX_TEST_DIR/launchctl.calls"
[ "$1" = kickstart ] || exit 0
[ -f "$DEX_TEST_DIR/service.pid" ] && kill "$(cat "$DEX_TEST_DIR/service.pid")" 2>/dev/null
mode=ok; [ -f "$DEX_TEST_BASE/current/agentvault/MODE" ] && mode=$(cat "$DEX_TEST_BASE/current/agentvault/MODE")
nohup python3 "$DEX_TEST_DIR/service.py" "$DEX_TEST_PORT" "$mode" >/dev/null 2>&1 </dev/null &
echo $! > "$DEX_TEST_DIR/service.pid"
sleep 0.4
"""


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0)); return s.getsockname()[1]


def make_tarball(sha, version, mode="ok", tests="pass", top=None, extra=None):
    top = top or "o-r-" + sha[:7]
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as t:
        def add(name, text):
            data = text.encode(); ti = tarfile.TarInfo(top + "/" + name); ti.size = len(data); t.addfile(ti, io.BytesIO(data))
        add("memory/agentvault/__init__.py", "")
        add("memory/agentvault/VERSION", version)
        add("memory/agentvault/MODE", mode)
        add("memory/tests/test_x.py", "import unittest\nclass T(unittest.TestCase):\n    def test_x(self): self.assertTrue(%s)\n" % (tests == "pass"))
        add("README.md", "not part of the release")
        for name, text in (extra or {}).items(): add(name, text)
    return buf.getvalue()


class FakeGitHub(BaseHTTPRequestHandler):
    state = {}   # sha -> {"ci": str, "tar": bytes}; "head" -> sha
    def log_message(self, *a): pass
    def _json(self, obj, etag=None):
        body = json.dumps(obj).encode(); self.send_response(200)
        self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(body)))
        if etag: self.send_header("ETag", etag)
        self.end_headers(); self.wfile.write(body)
    def do_GET(self):
        assert "dex-deployer" in self.headers.get("User-Agent", ""), "custom User-Agent expected"
        s = FakeGitHub.state; p = self.path.split("?")[0]
        if p == "/repos/o/r/commits/master":
            etag = '"%s"' % s["head"]
            if self.headers.get("If-None-Match") == etag:
                self.send_response(304); self.end_headers(); return
            return self._json({"sha": s["head"]}, etag)
        parts = p.split("/")   # '', repos, o, r, commits|tarball, sha[, check-runs]
        if len(parts) == 7 and parts[4] == "commits" and parts[6] == "check-runs":
            ci = s[parts[5]]["ci"]
            run = {"id": 1, "name": "test", "app": {"slug": "github-actions"}, "status": "completed" if ci != "pending" else "in_progress", "conclusion": None if ci == "pending" else ci}
            return self._json({"check_runs": [] if ci == "none" else [run, {"id": 2, "name": "other", "status": "completed", "conclusion": "failure", "app": {"slug": "github-actions"}}]})
        if len(parts) == 6 and parts[4] == "tarball":
            data = s[parts[5]]["tar"]; self.send_response(200)
            self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data); return
        self.send_response(404); self.end_headers()


def sha_n(n):
    return hashlib.sha1(str(n).encode()).hexdigest()


class DeployerTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.srv = ThreadingHTTPServer(("127.0.0.1", 0), FakeGitHub)
        threading.Thread(target=cls.srv.serve_forever, daemon=True).start()
        cls.api = "http://127.0.0.1:%d" % cls.srv.server_address[1]

    @classmethod
    def tearDownClass(cls):
        cls.srv.shutdown(); cls.srv.server_close()

    def setUp(self):
        FakeGitHub.state = {}
        self.dir = Path(tempfile.mkdtemp(prefix="dexdeploy-")).resolve()
        self.base = self.dir / "dexhosted"; self.base.mkdir()
        self.port = free_port(); self.ts = 0
        (self.dir / "service.py").write_text(FAKE_SERVICE)
        stub = self.dir / "launchctl"; stub.write_text(STUB_LAUNCHCTL); stub.chmod(0o755)
        self.keep = 5
        self.write_conf()
        self.addCleanup(self.cleanup)

    def cleanup(self):
        pid = self.dir / "service.pid"
        if pid.exists():
            try: os.kill(int(pid.read_text()), 15)
            except (ProcessLookupError, ValueError): pass
        for p in self.dir.rglob("*"):
            if not p.is_symlink(): p.chmod(0o755 if p.is_dir() else 0o644)
        shutil.rmtree(self.dir, ignore_errors=True)

    def write_conf(self, base=None, keep=None, suffix="dexhosted"):
        base = str(self.base) if base is None else base
        self.conf = self.dir / "t.conf"
        self.conf.write_text("\n".join([
            "name=test", "repo=o/r", "label=in.test.service", "domain=system", "base=" + base, "base_suffix=" + suffix,
            "run_user=" + getpass.getuser(), "src_subdir=memory/agentvault", "test_dir=memory", "keep=%d" % (keep or self.keep),
            "health=GET http://127.0.0.1:%d/healthz 200" % self.port, "health=POST http://127.0.0.1:%d/mcp 401" % self.port,
            "health_timeout=3", "test_timeout=60"]) + "\n")

    def publish(self, n, ci="success", version=None, **kw):
        sha = sha_n(n)
        FakeGitHub.state[sha] = {"ci": ci, "tar": make_tarball(sha, version or "v%d" % n, **kw)}
        FakeGitHub.state["head"] = sha
        return sha

    def run_deployer(self, env=None, conf=None):
        self.ts += 1
        e = dict(os.environ, DEX_API_URL=self.api, DEX_LAUNCHCTL=str(self.dir / "launchctl"), DEX_TEST_DIR=str(self.dir),
                 DEX_TEST_BASE=str(self.base), DEX_TEST_PORT=str(self.port), DEX_TIMESTAMP="20260101T0000%02dZ" % self.ts)
        e.update(env or {})
        return subprocess.run([BASH, str(SCRIPT), str(conf or self.conf)], capture_output=True, text=True, env=e, timeout=120)

    def current(self):
        link = self.base / "current"
        return os.readlink(link) if link.is_symlink() else None

    def version(self):
        return (self.base / "current" / "agentvault" / "VERSION").read_text()

    def releases(self):
        return sorted(p.name for p in (self.base / "releases").iterdir())

    def log(self):
        p = self.base / "logs" / "deploy.log"
        return p.read_text() if p.exists() else ""

    def kicks(self):
        p = self.dir / "launchctl.calls"
        return len(p.read_text().splitlines()) if p.exists() else 0

    def seen(self):
        return (self.base / "deploy-seen").read_text().split()

    def deploy_ok(self, n, **kw):
        sha = self.publish(n, **kw); r = self.run_deployer()
        self.assertEqual(r.returncode, 0, r.stderr + self.log())
        return sha

    # ---- the cases -----------------------------------------------------------------------------------------------
    def test_green_ci_deploys_and_switches_current(self):
        sha = self.deploy_ok(1)
        self.assertTrue(self.current().startswith("releases/20260101T000001Z-" + sha[:7]))
        self.assertEqual(self.version(), "v1")
        self.assertFalse((self.base / "current" / "README.md").exists())
        self.assertEqual(self.seen()[:2], [sha, "deployed"])
        self.assertEqual(self.kicks(), 1)
        self.assertIn("kickstart -k system/in.test.service", (self.dir / "launchctl.calls").read_text())
        self.assertIn("deployed " + sha[:7], self.log())
        self.assertEqual((self.base / "current" / "agentvault" / "VERSION").stat().st_mode & 0o777, 0o644)
        self.assertEqual(os.listdir(self.base / "tmp"), [])          # work dir cleaned up
        self.assertFalse((self.base / ".deploy.lock").exists())

    def test_test_copy_has_the_whole_repo_but_the_release_only_agentvault(self):
        t = ("import unittest\nfrom pathlib import Path\nR = Path(__file__).resolve().parents[2]\n"
             "class T(unittest.TestCase):\n    def test_x(self):\n        self.assertTrue((R / 'scripts' / 'x.sh').is_file()); self.assertTrue((R / 'PRIVACY.md').is_file())\n"
             "        self.assertTrue((R / 'docs' / 't.md').is_file()); self.assertFalse((R / 'docs' / 'assets').exists())\n")
        extra = {"memory/tests/test_repo.py": t, "scripts/x.sh": "#!/bin/bash\n", "PRIVACY.md": "p", "docs/t.md": "t", "docs/assets/big.gif": "g"}
        self.deploy_ok(1, extra=extra)
        self.assertEqual(sorted(p.name for p in (self.base / "current").iterdir() if not p.name.startswith(".")), ["agentvault"])

    def test_ci_not_green_is_skipped_and_recorded(self):
        sha = self.publish(1, ci="failure"); r = self.run_deployer()
        self.assertEqual(r.returncode, 0)
        self.assertIsNone(self.current()); self.assertEqual(self.kicks(), 0)
        self.assertEqual(self.seen()[:2], [sha, "skipped-ci-failure"]); self.assertIn("skip", self.log())

    def test_ci_pending_is_not_recorded(self):
        self.publish(1, ci="pending"); self.run_deployer()
        self.assertIsNone(self.current()); self.assertFalse((self.base / "deploy-seen").exists())
        FakeGitHub.state[sha_n(1)]["ci"] = "success"; self.run_deployer()
        self.assertEqual(self.version(), "v1")

    def test_failing_tests_reject_and_leave_current_alone(self):
        self.deploy_ok(1)
        before = self.current()
        sha = self.publish(2, tests="fail"); r = self.run_deployer()
        self.assertEqual(r.returncode, 1)
        self.assertEqual(self.current(), before); self.assertEqual(self.version(), "v1"); self.assertEqual(self.kicks(), 1)
        self.assertEqual(self.seen()[:2], [sha, "rejected-tests"]); self.assertIn("REJECTED", self.log())
        self.assertEqual(len(self.releases()), 1)

    def test_failing_health_rolls_back_to_previous_release(self):
        self.deploy_ok(1)
        before = self.current()
        sha = self.publish(2, mode="bad"); r = self.run_deployer()
        self.assertEqual(r.returncode, 1)
        self.assertEqual(self.current(), before); self.assertEqual(self.version(), "v1")
        self.assertIn("ROLLED BACK", self.log()); self.assertEqual(self.seen()[:2], [sha, "rejected-health"])
        self.assertEqual(self.kicks(), 3)                              # v1, v2, back to v1
        code = subprocess.run(["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}", "http://127.0.0.1:%d/healthz" % self.port], capture_output=True, text=True).stdout
        self.assertEqual(code, "200")                                  # the service really is back on the good release
        r = self.run_deployer()                                        # the rejected sha is never retried
        self.assertEqual(self.kicks(), 3)

    def test_same_sha_twice_is_a_noop(self):
        self.deploy_ok(1)
        r = self.run_deployer()
        self.assertEqual(r.returncode, 0); self.assertEqual(self.kicks(), 1); self.assertEqual(len(self.releases()), 1)

    def test_new_sha_with_unchanged_source_deploys_nothing(self):
        self.deploy_ok(1, version="same")
        sha = self.publish(2, version="same"); self.run_deployer()
        self.assertEqual(self.kicks(), 1); self.assertEqual(len(self.releases()), 1)
        self.assertEqual(self.seen()[:2], [sha, "unchanged"])

    def test_prune_keeps_n_and_never_current_or_previous(self):
        self.keep = 2; self.write_conf()
        for n in range(1, 5): self.deploy_ok(n)
        self.assertEqual(len(self.releases()), 2)
        self.assertEqual(self.version(), "v4")
        self.assertEqual(self.releases()[-1], os.path.basename(self.current()))
        # even when KEEP would allow removing it, current's older neighbour stays: point current two back, then prune by deploying
        self.assertIn("pruned", self.log())

    def test_prune_protects_current_after_a_rollback(self):
        self.keep = 2; self.write_conf()
        self.deploy_ok(1); self.deploy_ok(2)
        self.publish(3, mode="bad"); self.run_deployer()               # rolled back: current=v2, v3 is the newest dir
        self.publish(4); self.run_deployer()
        self.assertEqual(self.version(), "v4")
        names = self.releases(); self.assertEqual(len(names), 2)
        self.assertIn(os.path.basename(self.current()), names)

    def test_tarball_without_the_sha_in_its_top_dir_is_rejected(self):
        sha = sha_n(1)
        FakeGitHub.state[sha] = {"ci": "success", "tar": make_tarball(sha, "v1", top="o-r-0000000")}; FakeGitHub.state["head"] = sha
        self.assertEqual(self.run_deployer().returncode, 1)
        self.assertIsNone(self.current()); self.assertEqual(self.seen()[1], "rejected-tarball")

    def test_refuses_empty_root_wrong_suffix_and_missing_base(self):
        self.publish(1)
        for base in ("", "/", "//", str(self.dir / "elsewhere"), str(self.dir / "nonexistent" / "dexhosted"), "relative/dexhosted", str(self.dir / ".." / "dexhosted")):
            (self.dir / "elsewhere").mkdir(exist_ok=True)
            self.write_conf(base=base)
            r = self.run_deployer()
            self.assertEqual(r.returncode, 2, "base=%r: %s" % (base, r.stderr))
            self.assertIn("refusing", r.stderr)
        self.assertEqual(list((self.dir / "elsewhere").iterdir()), [])
        self.assertEqual(self.kicks(), 0)

    def test_lock_prevents_concurrent_runs(self):
        self.publish(1)
        (self.base / ".deploy.lock").mkdir()
        r = self.run_deployer()
        self.assertEqual(r.returncode, 0); self.assertIsNone(self.current()); self.assertIn("lock", self.log())
        self.assertTrue((self.base / ".deploy.lock").exists())         # not ours: left alone
        (self.base / ".deploy.lock").rmdir(); self.run_deployer()
        self.assertEqual(self.version(), "v1")

    def test_pause_file_stops_everything(self):
        self.publish(1); (self.base / "deploy-paused").write_text("")
        self.run_deployer()
        self.assertIsNone(self.current()); self.assertEqual(self.kicks(), 0)

    def test_no_previous_release_means_failed_not_rolled_back(self):
        self.publish(1, mode="bad"); r = self.run_deployer()
        self.assertEqual(r.returncode, 1); self.assertIn("no previous release", self.log())

    # ---- a compromised service must not be able to aim root's rm/mv/ln outside the tree --------------------------------
    def _outside(self):
        out = self.dir / "outside"; (out / "releases-victim").mkdir(parents=True)
        (out / "20250101T000000Z-victim").mkdir(); (out / "20250101T000000Z-victim" / "precious").write_text("x")
        (out / "keepme").write_text("x")
        return out, sorted(str(p.relative_to(out)) for p in out.rglob("*"))

    def _assert_refused(self, out, snapshot):
        kicks = self.kicks()
        self.assertEqual(self.run_deployer().returncode, 2)
        self.assertEqual(sorted(str(p.relative_to(out)) for p in out.rglob("*")), snapshot)
        self.assertEqual(self.kicks(), kicks)

    def test_symlinked_releases_dir_is_refused_untouched(self):
        self.deploy_ok(1); out, snap = self._outside()
        for p in (self.base / "releases").iterdir(): os.chmod(p, 0o755)
        shutil.rmtree(self.base / "releases"); os.symlink(out, self.base / "releases")
        self.publish(2); self._assert_refused(out, snap)

    def test_symlinked_tmp_dir_is_refused_untouched(self):
        self.deploy_ok(1); out, snap = self._outside()
        shutil.rmtree(self.base / "tmp"); os.symlink(out, self.base / "tmp")
        self.publish(2); self._assert_refused(out, snap)

    def test_symlinked_release_dir_is_refused_untouched(self):
        self.deploy_ok(1); out, snap = self._outside()
        rel = self.base / "releases" / self.releases()[0]
        os.chmod(rel, 0o755); shutil.rmtree(rel); os.symlink(out, rel)
        self.publish(2); self.run_deployer()
        self.assertEqual(sorted(str(p.relative_to(out)) for p in out.rglob("*")), snap)
        self.assertEqual(self.kicks(), 1); self.assertTrue(rel.is_symlink())

    def test_symlinked_logs_dir_is_refused_untouched(self):
        out, snap = self._outside(); (self.base / "logs").symlink_to(out)
        self.publish(1); self._assert_refused(out, snap)

    def test_symlinked_base_is_refused(self):
        real = self.dir / "real" / "dexhosted"; real.mkdir(parents=True)
        link = self.dir / "link" / "dexhosted"; link.parent.mkdir(); link.symlink_to(real)
        self.write_conf(base=str(link)); self.publish(1)
        self.assertEqual(self.run_deployer().returncode, 2); self.assertEqual(list(real.iterdir()), [])

    def test_world_writable_base_is_refused(self):
        self.publish(1); os.chmod(self.base, 0o777)
        r = self.run_deployer()
        self.assertEqual(r.returncode, 2); self.assertIn("refusing", r.stderr); self.assertIsNone(self.current())

    def test_unknown_config_key_is_refused(self):
        with open(self.conf, "a") as f: f.write("evil=$(touch /tmp/x)\n")
        self.assertEqual(self.run_deployer().returncode, 2)


@unittest.skipIf(os.geteuid() == 0, "the deployer refuses to run tests as root")
class InstallerMigrationTest(unittest.TestCase):
    def test_migrate_is_idempotent_and_keeps_old_path_working(self):
        with tempfile.TemporaryDirectory() as d:
            base = Path(d) / "dexhosted"; (base / "app" / "agentvault").mkdir(parents=True)
            (base / "app" / "agentvault" / "x.py").write_text("1")
            cmd = [BASH, str(INSTALLER), "--migrate-only", str(base)]
            for _ in range(2):
                r = subprocess.run(cmd, capture_output=True, text=True); self.assertEqual(r.returncode, 0, r.stderr)
                self.assertTrue((base / "current").is_symlink() and (base / "app").is_symlink())
                self.assertEqual((base / "current" / "agentvault" / "x.py").read_text(), "1")
                self.assertEqual((base / "app" / "agentvault" / "x.py").read_text(), "1")      # old WorkingDirectory still resolves
            self.assertEqual(len(list((base / "releases").iterdir())), 1)
            self.assertEqual(len(list((base / "backups").iterdir())), 1)
            self.assertEqual((base / "backups").iterdir().__next__().joinpath("app/agentvault/x.py").read_text(), "1")
            old, new = Path(d) / "old-app", Path(d) / "dexhosted-deploy"
            (old / "agentvault").mkdir(parents=True); (old / "agentvault" / "y.py").write_text("2"); new.mkdir()
            for _ in range(2):
                r = subprocess.run([BASH, str(INSTALLER), "--migrate-copy", str(old), str(new)], capture_output=True, text=True)
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertEqual((new / "current" / "agentvault" / "y.py").read_text(), "2")
                self.assertTrue((old / "agentvault" / "y.py").exists())               # the old dir is left alone
            self.assertEqual(len(list((new / "releases").iterdir())), 1)
            r = subprocess.run([BASH, str(INSTALLER), "--migrate-only", "/"], capture_output=True, text=True)
            self.assertNotEqual(r.returncode, 0)


if __name__ == "__main__":
    unittest.main()
