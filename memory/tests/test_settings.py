import json, sys, tempfile, unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from agentvault import rag_push, settings

class SettingsTests(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.TemporaryDirectory(); self.addCleanup(self.d.cleanup)
        self.p = Path(self.d.name) / "settings.json"

    def put(self, obj): self.p.write_text(json.dumps(obj) if not isinstance(obj, str) else obj)

    def test_loads_host_with_keychain_defaults(self):
        self.put({"gemma": {"host": "ai.example.com", "model": "gemma3:12b"}})
        self.assertEqual(settings.load(self.p), {"host": "ai.example.com", "base": "https://ai.example.com",
                                                 "keychain_service": "ai.example.com", "keychain_account": "notchapp"})

    def test_keychain_overrides(self):
        self.put({"gemma": {"host": "h.example.com", "keychain_service": "gw", "keychain_account": "me"}})
        c = settings.load(self.p); self.assertEqual((c["keychain_service"], c["keychain_account"]), ("gw", "me"))

    def test_missing_broken_or_incomplete_means_not_configured(self):
        self.assertIsNone(settings.load(self.p))
        self.put("{ nope"); self.assertIsNone(settings.load(self.p))
        self.put({"other": 1}); self.assertIsNone(settings.load(self.p))
        self.put({"gemma": {"model": "m"}}); self.assertIsNone(settings.load(self.p))

    def test_host_rules_match_the_app(self):
        self.assertEqual(settings.normalize_host("  https://ai.example.com/ "), "ai.example.com")
        self.assertEqual(settings.normalize_host("ai.example.com:8443"), "ai.example.com:8443")
        for bad in ["", "http://ai.example.com", "ai.example.com/path", "user@ai.example.com", "ai.example.com?x=1", "ai example.com",
                    "-bad.example.com", "ai.example.com:99999", "ai.example.com\n.evil.com"]:
            self.assertIsNone(settings.normalize_host(bad), bad)

    def test_rag_sync_without_settings_is_a_clear_error_not_a_crash(self):
        with self.assertRaises(rag_push.PushError) as cm:
            rag_push.sync(Path(self.d.name), settings_path=self.p)      # no post injected, no settings file
        self.assertIn("settings.json", str(cm.exception))

    def test_semantic_search_without_settings_just_finds_nothing(self):
        self.assertEqual(rag_push.semantic_paths("anything", settings_path=self.p), [])

if __name__ == "__main__": unittest.main()
