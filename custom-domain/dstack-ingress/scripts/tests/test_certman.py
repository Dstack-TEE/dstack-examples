#!/usr/bin/env python3
"""Unit tests for certman's renewal-window handling.

Run: python3 scripts/tests/test_certman.py
"""

import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

import certman  # noqa: E402

# A lineage config as certbot writes it: the key ships commented out, and
# everything after the first section header is out of bounds for a top-level key.
CERTBOT_CONF = """\
version = 5.7.0
archive_dir = /etc/letsencrypt/archive/example.com
cert = /etc/letsencrypt/live/example.com/cert.pem
# renew_before_expiry = 30 days

[renewalparams]
authenticator = dns-cloudflare
"""


def _manager(path: str) -> certman.CertManager:
    """A CertManager that reads and writes one temp file.

    __init__ builds a provider from the environment; none of that is involved
    in rewriting a config file, so bypass it.
    """
    mgr = object.__new__(certman.CertManager)
    mgr._renewal_conf_path = lambda domain: path  # noqa: SLF001
    return mgr


class RenewalWindowTest(unittest.TestCase):
    def setUp(self):
        self._saved = os.environ.get("RENEW_DAYS_BEFORE")
        fd, self.path = tempfile.mkstemp(suffix=".conf")
        os.close(fd)
        self.write(CERTBOT_CONF)

    def tearDown(self):
        os.unlink(self.path)
        if self._saved is None:
            os.environ.pop("RENEW_DAYS_BEFORE", None)
        else:
            os.environ["RENEW_DAYS_BEFORE"] = self._saved

    def write(self, text):
        with open(self.path, "w", encoding="utf-8") as fh:
            fh.write(text)

    def read(self):
        with open(self.path, encoding="utf-8") as fh:
            return fh.read()

    def apply(self, value):
        if value is None:
            os.environ.pop("RENEW_DAYS_BEFORE", None)
        else:
            os.environ["RENEW_DAYS_BEFORE"] = value
        _manager(self.path).apply_renewal_window("example.com")

    def test_setting_is_written_above_the_first_section(self):
        self.apply("365")
        body = self.read()
        self.assertIn("renew_before_expiry = 365 days", body)
        self.assertLess(
            body.index("renew_before_expiry"), body.index("[renewalparams]")
        )

    def test_setting_replaces_a_previous_value_without_duplicating(self):
        self.apply("365")
        self.apply("45")
        body = self.read()
        self.assertIn("renew_before_expiry = 45 days", body)
        self.assertNotIn("365", body)
        self.assertEqual(body.count("renew_before_expiry"), 1)

    def test_unsetting_removes_a_previously_written_value(self):
        """The regression: the lineage config outlives the container.

        Leaving the setting behind kept the certificate permanently due, and
        the documented way out -- unset the variable -- did nothing.
        """
        self.apply("365")
        self.assertIn("renew_before_expiry = 365 days", self.read())
        self.apply(None)
        self.assertNotIn("renew_before_expiry = 365 days", self.read())

    def test_unsetting_leaves_certbots_commented_template_alone(self):
        self.apply(None)
        self.assertIn("# renew_before_expiry = 30 days", self.read())

    def test_unsetting_on_an_untouched_config_changes_nothing(self):
        self.apply(None)
        self.assertEqual(self.read(), CERTBOT_CONF)

    def test_invalid_value_leaves_the_config_alone(self):
        self.apply("365")
        before = self.read()
        for bad in ("0", "-1", "later", "30 days"):
            self.apply(bad)
            self.assertEqual(self.read(), before, f"{bad!r} should be ignored")

    def test_missing_lineage_is_not_an_error(self):
        os.unlink(self.path)
        self.apply("365")
        self.assertFalse(os.path.exists(self.path))
        open(self.path, "w").close()  # tearDown unlinks it

    def test_wildcard_uses_the_bare_lineage_name(self):
        self.assertEqual(
            certman.CertManager._lineage_name("*.example.com"), "example.com"
        )
        self.assertEqual(
            certman.CertManager._lineage_name("example.com"), "example.com"
        )


class NoDuplicateDefinitionsTest(unittest.TestCase):
    """Python shadows a repeated class or method silently; unittest counts the
    later one and the total still goes up, so a duplicated block looks like
    passing tests. Same guard as test_dnsguide.py."""

    def test_no_duplicate_definitions(self):
        import ast, collections, pathlib

        tree = ast.parse(pathlib.Path(__file__).read_text())
        names = [n.name for n in tree.body if isinstance(n, ast.ClassDef)]
        for cls in (n for n in tree.body if isinstance(n, ast.ClassDef)):
            names += [f"{cls.name}.{m.name}" for m in cls.body
                      if isinstance(m, (ast.FunctionDef, ast.AsyncFunctionDef))]
        dupes = [n for n, c in collections.Counter(names).items() if c > 1]
        self.assertEqual(dupes, [], f"defined more than once: {dupes}")


if __name__ == "__main__":
    unittest.main(verbosity=2)
