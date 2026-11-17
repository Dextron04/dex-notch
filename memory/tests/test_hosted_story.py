import json, sys, tempfile, threading, unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_hosted_server import call, PUB
from agentvault.hosted import md
from agentvault.hosted.oauth import Auth
from agentvault.hosted.server import make_server
from agentvault.hosted.store import Store

ROOT = Path(__file__).resolve().parents[2]

class StoryTests(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.TemporaryDirectory(); self.addCleanup(self.d.cleanup)
        self.srv = make_server(Store(Path(self.d.name)), Auth(Store(Path(self.d.name)), invite_only=True), PUB, lambda e, l: None, port=0)
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()
        self.addCleanup(self.srv.server_close); self.addCleanup(self.srv.shutdown)
        self.base = "http://127.0.0.1:%d" % self.srv.server_address[1]

    def test_pages_are_read_on_the_site_not_redirected_to_github(self):
        for path, word in (("/privacy", "Hosted memory"), ("/terms", "closed beta"), ("/about", "Many people, one session")):
            st, _, body = call("GET", self.base + path)
            self.assertEqual(st, 200, path); self.assertIn(word, body); self.assertNotIn("github.com/Dextron04/dex-notch/blob", body)

    def test_the_site_links_to_its_own_privacy_page(self):
        _, _, home = call("GET", self.base + "/")
        self.assertIn('href="/privacy"', home); self.assertNotIn("PRIVACY.md", home); self.assertNotIn("Download for Mac", home.split("</section>")[0])

    def test_the_long_read_is_honest_about_what_is_planned(self):
        _, _, body = call("GET", self.base + "/about")
        self.assertIn("Not built yet", body); self.assertIn("This is a plan, not a promise", body)

    def test_the_motion_layer_is_self_hosted_and_only_on_the_long_read(self):
        _, _, about = call("GET", self.base + "/about"); _, _, privacy = call("GET", self.base + "/privacy")
        self.assertIn('type="module" src="/static/fx.js', about); self.assertIn('class="scene-bg"', about); self.assertNotIn("fx.js", privacy)
        self.assertNotRegex(about, r'<script[^>]+src="https?://')      # the CSP allows only this origin
        st, h, _ = call("GET", self.base + "/static/fx.js"); self.assertEqual(st, 200)

    def test_the_saving_instruction_is_the_same_on_the_site_and_in_the_app(self):
        import re, textwrap
        from agentvault.hosted import pages
        if not (ROOT / "NotchApp" / "AgentFiles.swift").exists(): self.skipTest("the Mac app source is not on this machine")   # the mini holds the server only
        swift = (ROOT / "NotchApp" / "AgentFiles.swift").read_text()
        app = textwrap.dedent(re.search(r'static let block = """\n(.*?)\n\s*"""', swift, re.S).group(1))
        self.assertEqual(pages.AGENT_SNIPPET, app)
        self.assertIn("remember", app); self.assertIn("Never include passwords", app)
        _, _, page = call("GET", self.base + "/connect"); self.assertIn("Save every conversation", page); self.assertIn("agent-snippet", page)

    def test_markdown_is_escaped_and_links_are_safe(self):
        _, _, out = md.render("# T\n\n<script>x</script> [a](javascript:alert(1)) [b](https://ok.io/?a=1&b=2) **s**\n")
        self.assertNotIn("<script>", out); self.assertNotIn("javascript:", out); self.assertIn('href="https://ok.io/?a=1&amp;b=2"', out); self.assertIn("<strong>s</strong>", out)

    def test_site_copies_match_the_repo_documents(self):    # the repo files are what GitHub shows; the site must say the same
        for src, name in (("PRIVACY.md", "privacy.md"), ("docs/terms.md", "terms.md")):
            if (ROOT / src).exists(): self.assertEqual((ROOT / src).read_text(), (Path(md.__file__).parent / "content" / name).read_text(), src)

if __name__ == "__main__": unittest.main()

class ConnectPageTests(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.TemporaryDirectory(); self.addCleanup(self.d.cleanup)
        self.store = Store(Path(self.d.name)); self.auth = Auth(self.store)
        self.srv = make_server(self.store, self.auth, PUB, lambda e, l: None, port=0)
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()
        self.addCleanup(self.srv.server_close); self.addCleanup(self.srv.shutdown)
        self.base = "http://127.0.0.1:%d" % self.srv.server_address[1]

    def test_the_page_gives_each_assistant_its_steps_and_the_address(self):
        st, _, body = call("GET", self.base + "/connect"); self.assertEqual(st, 200)
        for word in ("Claude", "ChatGPT", "claude mcp add --transport http --scope user dex-memory " + PUB + "/mcp", "codex mcp add dex-memory --url " + PUB + "/mcp", "codex mcp login dex-memory"): self.assertIn(word, body)
        self.assertNotIn("Not connected yet", body)      # signed out: nothing is claimed about status

    def test_me_and_the_page_say_which_assistants_are_connected(self):
        from agentvault.hosted import devices
        uid = self.store.create_user("a@x.io"); _, tok = devices.create(self.store, uid, "Mac")
        me = lambda: json.loads(call("GET", self.base + "/v1/me", headers={"Authorization": "Bearer " + tok})[2])["assistants"]
        self.assertEqual(me(), {"claude": False, "chatgpt": False})
        for name in ("Claude", "ChatGPT"):
            cid = self.auth.register(["https://claude.ai/cb"], name)
            with self.store.conn() as c: c.execute("INSERT INTO grants(hash,kind,user_id,client_id,exp) VALUES(?,?,?,?,?)", ("h" + name, "refresh", uid, cid, 9e12))
        self.assertEqual(me(), {"claude": True, "chatgpt": True})
