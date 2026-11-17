import sys, tempfile, threading, unittest
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

    def test_markdown_is_escaped_and_links_are_safe(self):
        _, _, out = md.render("# T\n\n<script>x</script> [a](javascript:alert(1)) [b](https://ok.io/?a=1&b=2) **s**\n")
        self.assertNotIn("<script>", out); self.assertNotIn("javascript:", out); self.assertIn('href="https://ok.io/?a=1&amp;b=2"', out); self.assertIn("<strong>s</strong>", out)

    def test_site_copies_match_the_repo_documents(self):    # the repo files are what GitHub shows; the site must say the same
        for src, name in (("PRIVACY.md", "privacy.md"), ("docs/terms.md", "terms.md")):
            if (ROOT / src).exists(): self.assertEqual((ROOT / src).read_text(), (Path(md.__file__).parent / "content" / name).read_text(), src)

if __name__ == "__main__": unittest.main()
