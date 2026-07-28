#!/usr/bin/env python3
"""Unit tests for dnsguide's record parsing and CAA evaluation.

Run: python3 scripts/tests/test_dnsguide.py
"""

import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

import dnsguide  # noqa: E402

# Same record, as each resolver actually returns it. Google answers in
# presentation format; Cloudflare answers in RFC 3597 generic format.
CAA_PRESENTATION = '0 issue "letsencrypt.org;validationmethods=dns-01"'
CAA_GENERIC = (
    "\\# 47 00 05 69 73 73 75 65 6c 65 74 73 65 6e 63 72 79 70 74 2e 6f 72 67 3b "
    "76 61 6c 69 64 61 74 69 6f 6e 6d 65 74 68 6f 64 73 3d 64 6e 73 2d 30 31"
)


class TestCaaParsing(unittest.TestCase):
    def test_presentation_format(self):
        self.assertEqual(
            dnsguide._parse_caa(CAA_PRESENTATION),
            (0, "issue", "letsencrypt.org;validationmethods=dns-01"),
        )

    def test_generic_format_matches_presentation(self):
        """Both resolvers must yield the same tuple, or the check is resolver-dependent."""
        self.assertEqual(
            dnsguide._parse_caa(CAA_GENERIC), dnsguide._parse_caa(CAA_PRESENTATION)
        )

    def test_issuewild_tag(self):
        parsed = dnsguide._parse_caa('0 issuewild "letsencrypt.org"')
        self.assertEqual(parsed, (0, "issuewild", "letsencrypt.org"))

    def test_garbage_is_rejected(self):
        for junk in ("", "nonsense", "\\# zz", "\\# 2"):
            self.assertIsNone(dnsguide._parse_caa(junk), junk)


class TestCaaPermits(unittest.TestCase):
    ACCOUNT = "https://acme-staging-v02.api.letsencrypt.org/acme/acct/1"

    def test_method_restriction_blocks_other_method(self):
        ok, why = dnsguide._caa_permits(
            "letsencrypt.org;validationmethods=dns-01", "issue", "tls-alpn-01", ""
        )
        self.assertFalse(ok)
        self.assertIn("tls-alpn-01", why)

    def test_method_restriction_allows_listed_method(self):
        ok, _ = dnsguide._caa_permits(
            "letsencrypt.org;validationmethods=dns-01,tls-alpn-01", "issue", "tls-alpn-01", ""
        )
        self.assertTrue(ok)

    def test_no_parameters_allows_any_method(self):
        ok, _ = dnsguide._caa_permits("letsencrypt.org", "issue", "tls-alpn-01", "")
        self.assertTrue(ok)

    def test_other_issuer_blocks(self):
        ok, why = dnsguide._caa_permits("digicert.com", "issue", "tls-alpn-01", "")
        self.assertFalse(ok)
        self.assertIn("digicert.com", why)

    def test_account_mismatch_blocks(self):
        ok, why = dnsguide._caa_permits(
            f"letsencrypt.org;accounturi={self.ACCOUNT}", "issue", "tls-alpn-01",
            "https://acme-staging-v02.api.letsencrypt.org/acme/acct/999",
        )
        self.assertFalse(ok)
        self.assertIn("accounturi", why)

    def test_account_unknown_skips_the_comparison(self):
        """Before our account exists we cannot compare it, so do not block on it."""
        ok, _ = dnsguide._caa_permits(
            f"letsencrypt.org;accounturi={self.ACCOUNT}", "issue", "tls-alpn-01", ""
        )
        self.assertTrue(ok)


class TestCaaCheckDeduplication(unittest.TestCase):
    """One record seen twice, in two wire formats, must be reported once.

    Resolvers disagree on CAA presentation: Cloudflare hands back RFC 3597
    generic hex, Google the human-readable form. The union is taken over raw
    rdata, so the same record arrives as two different strings.
    """

    PRESENTATION = '0 issue "letsencrypt.org;validationmethods=dns-01"'
    # The same record, generic-encoded: flags=0, tag len 5, "issue", value.
    GENERIC = (
        r"\# 44 00 05 69 73 73 75 65 6c 65 74 73 65 6e 63 72 79 70 74 2e 6f 72 67 "
        r"3b 76 61 6c 69 64 61 74 69 6f 6e 6d 65 74 68 6f 64 73 3d 64 6e 73 2d 30 31"
    )

    def setUp(self):
        self._saved = dnsguide.query_union
        dnsguide.query_union = lambda name, rr, resolvers: (
            [self.GENERIC, self.PRESENTATION] if name == "app.example.com" else []
        )
        self.addCleanup(lambda: setattr(dnsguide, "query_union", self._saved))

    def test_both_encodings_parse_to_the_same_record(self):
        self.assertEqual(
            dnsguide._parse_caa(self.GENERIC), dnsguide._parse_caa(self.PRESENTATION)
        )

    def test_reason_is_not_repeated(self):
        ok, reason = dnsguide.check_caa(
            "app.example.com", "issue", "tls-alpn-01", "", "r1,r2"
        )
        self.assertFalse(ok)
        self.assertEqual(reason.count("excludes tls-alpn-01"), 1, reason)


class TestTxtNormalisation(unittest.TestCase):
    def test_strips_quotes(self):
        self.assertEqual(dnsguide._unquote_txt('"abc:443"'), "abc:443")

    def test_joins_split_chunks(self):
        self.assertEqual(dnsguide._unquote_txt('"aaa" "bbb"'), "aaabbb")

    def test_passes_through_unquoted(self):
        self.assertEqual(dnsguide._unquote_txt("abc:443"), "abc:443")


class TestRecordBuilding(unittest.TestCase):
    def _args(self, **over):
        import argparse

        base = dict(
            domain="app.example.com",
            alias_target="gw.example.com",
            txt_name="_dstack-app-address.app.example.com",
            txt_value="deadbeef:443",
            caa_name="app.example.com",
            caa_tag="issue",
            caa_value="letsencrypt.org;validationmethods=tls-alpn-01",
            account_uri="",
            include="cname,txt,caa",
        )
        base.update(over)
        return argparse.Namespace(**base)

    def test_all_records(self):
        types = [r.type for r in dnsguide.build_records(self._args())]
        self.assertEqual(types, ["CNAME", "TXT", "CAA"])

    def test_include_filters(self):
        types = [r.type for r in dnsguide.build_records(self._args(include="txt"))]
        self.assertEqual(types, ["TXT"])

    def test_caa_omitted_without_value(self):
        types = [r.type for r in dnsguide.build_records(self._args(caa_value=""))]
        self.assertEqual(types, ["CNAME", "TXT"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
