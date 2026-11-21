"""Tests for lib/set_openclaw_key.py. Run: python3 -m unittest discover -s tests"""
import json
import os
import stat
import subprocess
import sys
import tempfile
import unittest

LIB = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib")
SCRIPT = os.path.join(LIB, "set_openclaw_key.py")
sys.path.insert(0, LIB)
from set_openclaw_key import is_local  # noqa: E402


class IsLocal(unittest.TestCase):
    def test_loopback_hosts_on_the_port(self):
        for url in ("http://127.0.0.1:8000", "http://localhost:8000/v1", "http://[::1]:8000/v1"):
            self.assertTrue(is_local(url, "8000"), url)

    def test_port_must_match_exactly(self):
        # The old startswith() check matched these.
        self.assertFalse(is_local("http://127.0.0.1:8000", "800"))
        self.assertFalse(is_local("http://127.0.0.1:8000", "80"))
        self.assertFalse(is_local("http://127.0.0.1:80001", "8000"))

    def test_host_must_be_loopback(self):
        self.assertFalse(is_local("http://127.0.0.1.evil.example:8000", "8000"))
        self.assertFalse(is_local("http://10.0.0.5:8000", "8000"))
        self.assertFalse(is_local("http://localhost@evil.example:8000", "8000"))

    def test_rejects_other_schemes_and_junk(self):
        self.assertFalse(is_local("https://127.0.0.1:8000", "8000"))
        self.assertFalse(is_local("http://127.0.0.1:notaport", "8000"))
        self.assertFalse(is_local("", "8000"))
        self.assertFalse(is_local(None, "8000"))


class Script(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.path = os.path.join(self.dir.name, "openclaw.json")

    def tearDown(self):
        self.dir.cleanup()

    def write_config(self, providers):
        with open(self.path, "w", encoding="utf-8") as f:
            json.dump({"models": {"providers": providers}, "other": 1}, f)

    def run_script(self, port, key):
        return subprocess.run([sys.executable, SCRIPT, port, self.path],
                              input=key, capture_output=True, text=True)

    def read_text(self):
        with open(self.path, encoding="utf-8") as f:
            return f.read()

    def read_config(self):
        return json.loads(self.read_text())

    def test_sets_key_only_on_matching_providers(self):
        self.write_config({
            "colibri": {"baseUrl": "http://127.0.0.1:8000/v1"},
            "colibri6": {"baseUrl": "http://[::1]:8000/v1"},
            "ollama": {"baseUrl": "http://127.0.0.1:11434"},
            "near-miss": {"baseUrl": "http://127.0.0.1:80001/v1"},
        })
        r = self.run_script("8000", "s3cret\n")
        self.assertEqual(r.returncode, 0, r.stderr)
        providers = self.read_config()["models"]["providers"]
        self.assertEqual(providers["colibri"]["apiKey"], "s3cret")
        self.assertEqual(providers["colibri6"]["apiKey"], "s3cret")
        self.assertNotIn("apiKey", providers["ollama"])
        self.assertNotIn("apiKey", providers["near-miss"])
        self.assertEqual(self.read_config()["other"], 1, "unrelated settings are kept")

    def test_file_is_private_afterwards(self):
        self.write_config({"colibri": {"baseUrl": "http://127.0.0.1:8000"}})
        os.chmod(self.path, 0o644)
        self.assertEqual(self.run_script("8000", "k\n").returncode, 0)
        self.assertEqual(stat.S_IMODE(os.stat(self.path).st_mode), 0o600)

    def test_fails_when_no_provider_matches(self):
        self.write_config({"ollama": {"baseUrl": "http://127.0.0.1:11434"}})
        before = self.read_text()
        r = self.run_script("8000", "k\n")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("no provider", r.stderr)
        self.assertEqual(self.read_text(), before, "file untouched")

    def test_fails_without_a_key(self):
        self.write_config({"colibri": {"baseUrl": "http://127.0.0.1:8000"}})
        r = self.run_script("8000", "")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("no key", r.stderr)

    def test_key_is_not_in_the_output(self):
        self.write_config({"colibri": {"baseUrl": "http://127.0.0.1:8000"}})
        r = self.run_script("8000", "s3cret\n")
        self.assertNotIn("s3cret", r.stdout + r.stderr)


if __name__ == "__main__":
    unittest.main()
