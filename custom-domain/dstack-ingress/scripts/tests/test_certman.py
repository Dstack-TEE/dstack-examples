#!/usr/bin/env python3
"""Unit tests for certman's renewal-window handling.

Run: python3 scripts/tests/test_certman.py
"""

import os
import shutil
import sys
import tempfile
import unittest
from unittest import mock

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

    def test_wildcard_has_its_own_deterministic_dir(self):
        with mock.patch.dict(os.environ, {"DETERMINISTIC_TLS_KEY": "true"}):
            self.assertEqual(certman.CertManager.cert_dir("*.example.com"),
                             "/etc/letsencrypt/deterministic/_wildcard.example.com")
            self.assertEqual(certman.CertManager.cert_dir("example.com"),
                             "/etc/letsencrypt/deterministic/example.com")


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
        "ACME_DIRECTORY_URL",
        "DETERMINISTIC_TLS_KEY",
    )

    def setUp(self):
        self._saved = {v: os.environ.get(v) for v in self.VARS}
        for v in self.VARS:
            os.environ.pop(v, None)
        self.root = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.root)
        self.addCleanup(setattr, certman, "LETSENCRYPT_DIR", certman.LETSENCRYPT_DIR)
        certman.LETSENCRYPT_DIR = self.root

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

    def test_renew_uses_the_wildcard_lineage(self):
        cmd = _command_manager()._build_certbot_command("renew", "*.example.com", "")
        self.assertEqual(cmd[cmd.index("--cert-name") + 1], "_wildcard.example.com")

    def test_certonly_names_the_lineage(self):
        """certbot's own pick for a wildcard is the base domain's name."""
        for delegation in ("", "deleg.example.net"):
            os.environ["DELEGATION_ZONE"] = delegation
            cmd = _command_manager()._build_certbot_command(
                "certonly", "*.example.com", "")
            self.assertEqual(cmd[cmd.index("--cert-name") + 1], "_wildcard.example.com")
            self.assertEqual(cmd[cmd.index("-d") + 1], "*.example.com")

    def test_csr_issuance_has_no_lineage(self):
        os.environ["DETERMINISTIC_TLS_KEY"] = "true"
        cmd = _command_manager()._build_certbot_command(
            "certonly", "*.example.com", "", ("--csr", "x.csr"))
        self.assertNotIn("--cert-name", cmd)

    def test_replacing_keeps_the_lineage(self):
        mgr = _command_manager()
        mgr.install_plugin = lambda: True
        mgr.provider.validate_credentials = lambda: True
        mgr.setup_credentials = lambda: True
        cmds = []
        with mock.patch.object(certman.subprocess, "run",
                               lambda cmd, **kw: cmds.append(cmd) or mock.Mock(returncode=0)):
            self.assertTrue(mgr.obtain_certificate("*.x.com", "", replace=True))
        cmd = cmds[0]
        self.assertIn("--force-renewal", cmd)
        self.assertIn("--break-my-certs", cmd)
        self.assertEqual(cmd[cmd.index("--cert-name") + 1], "_wildcard.x.com")

    def test_delegation_renew_is_scoped_too(self):
        os.environ["DELEGATION_ZONE"] = "deleg.example.net"
        cmd = _command_manager()._build_certbot_command("renew", "a.example.com", "")
        self.assertEqual(cmd[cmd.index("--cert-name") + 1], "a.example.com")
        # renew must not re-specify the authenticator; it is in the lineage.
        self.assertNotIn("--manual", cmd)


class AcmeServerTest(EnvTestCase):
    """The configured ACME server, not the one saved in a lineage, decides.

    The certificate volume outlives the configuration, so after a switch
    between staging and production the certificate in place, its renewal
    config and its account all belong to the other server.
    """

    COMMANDS = (("certonly", False), ("renew", False), ("certonly", True), ("renew", True))

    def servers(self):
        out = []
        for action, delegated in self.COMMANDS:
            if delegated:
                os.environ["DELEGATION_ZONE"] = "deleg.example.net"
            else:
                os.environ.pop("DELEGATION_ZONE", None)
            cmd = _command_manager()._build_certbot_command(action, "a.example.com", "")
            self.assertNotIn("--staging", cmd)
            out.append(cmd[cmd.index("--server") + 1])
        return set(out)

    def test_every_command_names_the_server(self):
        self.assertEqual(self.servers(), {certman.ACME_PROD})
        os.environ["ACME_STAGING"] = "true"
        self.assertEqual(self.servers(), {certman.ACME_STAGING})

    def test_directory_url_applies_to_every_command(self):
        os.environ["ACME_STAGING"] = "true"
        os.environ["ACME_DIRECTORY_URL"] = "https://pebble:14000/dir"
        self.assertEqual(self.servers(), {"https://pebble:14000/dir"})

    def run_auto(self, lineage_server, account=True):
        tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, tmp, ignore_errors=True)
        conf = os.path.join(tmp, "a.example.com.conf")
        with open(conf, "w", encoding="utf-8") as fh:
            if lineage_server:
                fh.write(f"version = 5.8.0\n[renewalparams]\nserver = {lineage_server}\n")
        calls = []
        mgr = object.__new__(certman.CertManager)
        mgr._renewal_conf_path = lambda domain: conf  # noqa: SLF001
        mgr.certificate_exists = lambda domain: True
        mgr.acme_account_exists = lambda: account
        mgr.renew_certificate = lambda d, e: calls.append("renew") or (True, False)
        mgr.obtain_certificate = lambda d, e, replace=False: calls.append(
            ("obtain", replace)) or True
        mgr.run_action("a.example.com", "", "auto")
        return calls

    def test_same_server_renews(self):
        self.assertEqual(self.run_auto(certman.ACME_PROD), ["renew"])

    def test_staging_to_production_replaces_the_certificate(self):
        self.assertEqual(self.run_auto(certman.ACME_STAGING), [("obtain", True)])

    def test_production_to_staging_replaces_the_certificate(self):
        os.environ["ACME_STAGING"] = "true"
        self.assertEqual(self.run_auto(certman.ACME_PROD), [("obtain", True)])

    def test_missing_account_replaces_the_certificate(self):
        self.assertEqual(self.run_auto(certman.ACME_PROD, account=False),
                         [("obtain", True)])

    def test_unknown_server_does_not_replace_every_pass(self):
        self.assertEqual(self.run_auto(None), ["renew"])


class RenewRandomSleepTest(EnvTestCase):
    """Without a TTY certbot sleeps up to 480s before a due renewal, longer
    than the subprocess timeout allows."""

    def test_renew_skips_the_random_sleep(self):
        cmd = _command_manager()._build_certbot_command("renew", "a.example.com", "")
        self.assertIn("--no-random-sleep-on-renew", cmd)

    def test_delegation_renew_skips_the_random_sleep(self):
        os.environ["DELEGATION_ZONE"] = "deleg.example.net"
        cmd = _command_manager()._build_certbot_command("renew", "a.example.com", "")
        self.assertIn("--no-random-sleep-on-renew", cmd)


def _cert_pem(name, key):
    from datetime import datetime, timedelta, timezone
    from cryptography import x509
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.x509.oid import NameOID

    now = datetime.now(timezone.utc)
    subject = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, name)])
    return (x509.CertificateBuilder()
            .subject_name(subject).issuer_name(subject)
            .public_key(key.public_key()).serial_number(1)
            .not_valid_before(now).not_valid_after(now + timedelta(days=90))
            .add_extension(x509.SubjectAlternativeName([x509.DNSName(name)]), critical=False)
            .sign(key, hashes.SHA256())
            .public_bytes(serialization.Encoding.PEM))


class LineageNameTest(EnvTestCase):
    """Existing lineages are found by content; new ones get a name of their own."""

    def setUp(self):
        super().setUp()
        from cryptography.hazmat.primitives.asymmetric import ec

        self.key = ec.generate_private_key(ec.SECP256R1())
        self.mgr = object.__new__(certman.CertManager)

    def lineage(self, lineage, name):
        os.makedirs(f"{self.root}/live/{lineage}")
        os.makedirs(f"{self.root}/renewal", exist_ok=True)
        with open(f"{self.root}/live/{lineage}/cert.pem", "wb") as fh:
            fh.write(_cert_pem(name, self.key))
        open(f"{self.root}/renewal/{lineage}.conf", "w").close()

    def test_new_wildcard_lineage_is_apart_from_the_base(self):
        self.assertEqual(self.mgr._lineage_name("*.x.com"), "_wildcard.x.com")
        self.assertEqual(self.mgr._lineage_name("x.com"), "x.com")

    def test_lineages_certbot_named_itself_are_found(self):
        self.lineage("x.com", "*.x.com")
        self.lineage("x.com-0001", "x.com")
        self.assertEqual(self.mgr._lineage_name("*.x.com"), "x.com")
        self.assertEqual(self.mgr._lineage_name("x.com"), "x.com-0001")

    def test_a_name_taken_by_another_certificate_is_not_reused(self):
        self.lineage("x.com", "*.x.com")
        self.assertEqual(self.mgr._lineage_name("x.com"), "x.com-0001")

    def test_legacy_wildcard_files_under_the_bare_name_move_to_the_wildcards(self):
        os.environ["DETERMINISTIC_TLS_KEY"] = "true"
        live = f"{self.root}/live/x.com"
        os.makedirs(live)
        for item in ("cert", "fullchain"):
            with open(f"{live}/{item}.pem", "wb") as fh:
                fh.write(_cert_pem("*.x.com", self.key))
        with open(f"{live}/privkey.pem", "wb") as fh:
            fh.write(certman.deterministic_key.key_pem(self.key))
        self.mgr._clear_legacy_live("*.x.com")
        self.assertFalse(os.path.exists(live))
        self.assertTrue(os.path.exists(f"{self.root}/deterministic/_wildcard.x.com/fullchain.pem"))


class CertbotTimeoutTest(EnvTestCase):
    """A fixed 300s cap could not fit every provider's own propagation wait."""

    def test_timeout_covers_the_propagation_wait(self):
        self.assertEqual(
            _command_manager(propagation=400)._certbot_timeout(),
            400 + certman.CERTBOT_TIMEOUT_HEADROOM,
        )

    def test_linode_default_propagation_fits(self):
        # linode's CERTBOT_PROPAGATION_SECONDS is 300, so the old 300s cap could
        # never be met: issuance and renewal timed out every time.
        timeout = _command_manager(propagation=300)._certbot_timeout()
        self.assertGreater(timeout, 300)

    def test_delegation_uses_its_own_propagation_setting(self):
        os.environ["DELEGATION_ZONE"] = "deleg.example.net"
        os.environ["DELEGATION_PROPAGATION_SECONDS"] = "240"
        self.assertEqual(
            _command_manager()._certbot_timeout(),
            240 + certman.CERTBOT_TIMEOUT_HEADROOM,
        )

    def test_delegation_falls_back_to_the_hook_default(self):
        os.environ["DELEGATION_ZONE"] = "deleg.example.net"
        self.assertEqual(
            _command_manager()._certbot_timeout(),
            max(certman.CERTBOT_TIMEOUT_FLOOR,
                120 + certman.CERTBOT_TIMEOUT_HEADROOM),
        )

    def test_explicit_override_wins(self):
        os.environ["CERTBOT_TIMEOUT"] = "900"
        self.assertEqual(_command_manager(propagation=300)._certbot_timeout(), 900)

    def test_invalid_override_is_ignored(self):
        for bad in ("0", "-5", "soon", ""):
            os.environ["CERTBOT_TIMEOUT"] = bad
            self.assertEqual(
                _command_manager(propagation=400)._certbot_timeout(),
                400 + certman.CERTBOT_TIMEOUT_HEADROOM,
                f"{bad!r} should be ignored",
            )

    def test_an_override_below_the_floor_is_still_honoured(self):
        os.environ["CERTBOT_TIMEOUT"] = "60"
        self.assertEqual(_command_manager(propagation=300)._certbot_timeout(), 60)

    def test_provider_without_propagation_keeps_the_old_budget(self):
        """route53 declares no propagation wait.

        Sizing purely from the wait would cut it from 300s to 180s and fail
        renewals that used to fit -- a regression introduced by the fix.
        """
        self.assertEqual(
            _command_manager(propagation=None)._certbot_timeout(),
            certman.CERTBOT_TIMEOUT_FLOOR,
        )

    def test_no_provider_ends_up_below_the_previous_fixed_cap(self):
        for propagation in (None, 0, 30, 120, 300):
            self.assertGreaterEqual(
                _command_manager(propagation=propagation)._certbot_timeout(),
                300,
                f"propagation={propagation} shortened the budget",
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
