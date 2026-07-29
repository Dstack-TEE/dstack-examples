#!/usr/bin/env python3
"""Unit tests for certman's renewal-window handling.

Run: python3 scripts/tests/test_certman.py
"""

import os
import shutil
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
        # Its own directory, so a test may make the directory unwritable
        # without touching anything it does not own.
        self.dir = tempfile.mkdtemp()
        self.path = os.path.join(self.dir, "example.com.conf")
        self.write(CERTBOT_CONF)

    def tearDown(self):
        os.chmod(self.dir, 0o700)
        shutil.rmtree(self.dir, ignore_errors=True)
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

    def test_write_is_atomic_and_leaves_no_scratch_file(self):
        """The live config is renamed into place, never truncated in place.

        Opening it with "w" would empty it before the replacement was written,
        and a lineage config certbot cannot parse is one it cannot renew.
        """
        self.apply("365")
        self.assertFalse(
            os.path.exists(self.path + ".dstack-tmp"),
            "temporary file left behind",
        )
        self.assertTrue(self.read().endswith("\n"))
        self.assertIn("[renewalparams]", self.read())

    def test_a_failed_write_leaves_the_original_intact(self):
        original = self.read()
        os.chmod(self.dir, 0o500)  # cannot create the temp file
        try:
            self.apply("365")
        finally:
            os.chmod(self.dir, 0o700)
        self.assertEqual(self.read(), original)

    def test_wildcard_uses_the_bare_lineage_name(self):
        self.assertEqual(
            certman.CertManager._lineage_name("*.example.com"), "example.com"
        )
        self.assertEqual(
            certman.CertManager._lineage_name("example.com"), "example.com"
        )


class FakeProvider:
    CERTBOT_PLUGIN = "dns-cloudflare"
    CERTBOT_CREDENTIALS_FILE = None
    CERTBOT_PROPAGATION_SECONDS = 120


def _command_manager(propagation=120) -> certman.CertManager:
    """A CertManager that can build commands without a real provider or venv."""
    mgr = object.__new__(certman.CertManager)
    provider = FakeProvider()
    provider.CERTBOT_PROPAGATION_SECONDS = propagation
    mgr.provider = provider
    mgr.provider_type = "cloudflare"
    mgr._get_certbot_command = lambda: ["certbot"]  # noqa: SLF001
    return mgr


class EnvTestCase(unittest.TestCase):
    """Restore every environment variable a test touches."""

    VARS = (
        "CERTBOT_TIMEOUT",
        "DELEGATION_ZONE",
        "DELEGATION_PROPAGATION_SECONDS",
        "ACME_STAGING",
        "CERTBOT_STAGING",
    )

    def setUp(self):
        self._saved = {v: os.environ.get(v) for v in self.VARS}
        for v in self.VARS:
            os.environ.pop(v, None)

    def tearDown(self):
        for v, old in self._saved.items():
            if old is None:
                os.environ.pop(v, None)
            else:
                os.environ[v] = old


class RenewScopeTest(EnvTestCase):
    """`certbot renew` renews every lineage unless told otherwise.

    run_pass calls this once per domain, so without --cert-name N domains meant
    N runs over all N lineages, and each run's result was reported against
    whichever domain happened to ask for it.
    """

    def test_renew_is_scoped_to_one_lineage(self):
        cmd = _command_manager()._build_certbot_command("renew", "a.example.com", "")
        self.assertIn("--cert-name", cmd)
        self.assertEqual(cmd[cmd.index("--cert-name") + 1], "a.example.com")

    def test_renew_uses_the_bare_name_for_a_wildcard(self):
        cmd = _command_manager()._build_certbot_command("renew", "*.example.com", "")
        self.assertEqual(cmd[cmd.index("--cert-name") + 1], "example.com")

    def test_certonly_is_scoped_by_d_not_cert_name(self):
        cmd = _command_manager()._build_certbot_command(
            "certonly", "a.example.com", "")
        self.assertNotIn("--cert-name", cmd)
        self.assertIn("-d", cmd)

    def test_delegation_renew_is_scoped_too(self):
        os.environ["DELEGATION_ZONE"] = "deleg.example.net"
        cmd = _command_manager()._build_certbot_command("renew", "a.example.com", "")
        self.assertEqual(cmd[cmd.index("--cert-name") + 1], "a.example.com")
        # renew must not re-specify the authenticator; it is in the lineage.
        self.assertNotIn("--manual", cmd)


class CertbotTimeoutTest(EnvTestCase):
    """A fixed 300s cap could not fit every provider's own propagation wait."""

    def test_timeout_covers_the_propagation_wait(self):
        self.assertEqual(
            _command_manager(propagation=120)._certbot_timeout(),
            120 + certman.CERTBOT_TIMEOUT_HEADROOM,
        )

    def test_linode_default_propagation_fits(self):
        # linode's CERTBOT_PROPAGATION_SECONDS is 300, so the old 300s cap could
        # never be met: issuance and renewal timed out every time.
        timeout = _command_manager(propagation=300)._certbot_timeout()
        self.assertGreater(timeout, 300)

    def test_delegation_uses_its_own_propagation_setting(self):
        os.environ["DELEGATION_ZONE"] = "deleg.example.net"
        os.environ["DELEGATION_PROPAGATION_SECONDS"] = "200"
        self.assertEqual(
            _command_manager()._certbot_timeout(),
            200 + certman.CERTBOT_TIMEOUT_HEADROOM,
        )

    def test_delegation_falls_back_to_the_hook_default(self):
        os.environ["DELEGATION_ZONE"] = "deleg.example.net"
        self.assertEqual(
            _command_manager()._certbot_timeout(),
            120 + certman.CERTBOT_TIMEOUT_HEADROOM,
        )

    def test_explicit_override_wins(self):
        os.environ["CERTBOT_TIMEOUT"] = "900"
        self.assertEqual(_command_manager(propagation=300)._certbot_timeout(), 900)

    def test_invalid_override_is_ignored(self):
        for bad in ("0", "-5", "soon", ""):
            os.environ["CERTBOT_TIMEOUT"] = bad
            self.assertEqual(
                _command_manager(propagation=120)._certbot_timeout(),
                120 + certman.CERTBOT_TIMEOUT_HEADROOM,
                f"{bad!r} should be ignored",
            )

    def test_provider_without_propagation_still_gets_headroom(self):
        # route53 sets CERTBOT_PROPAGATION_SECONDS = None.
        self.assertEqual(
            _command_manager(propagation=None)._certbot_timeout(),
            certman.CERTBOT_TIMEOUT_HEADROOM,
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
