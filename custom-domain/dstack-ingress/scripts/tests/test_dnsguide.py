#!/usr/bin/env python3
"""Unit tests for dnsguide's record parsing and CAA evaluation.

Run: python3 scripts/tests/test_dnsguide.py
"""

import argparse
import contextlib
import io
import os
import sys
import unittest
from unittest import mock

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


class TestCaaRelevantTag(unittest.TestCase):
    """RFC 8659: only the tag that applies to the name restricts issuance."""

    def _check(self, rdatas, tag):
        saved = dnsguide.query_union
        dnsguide.query_union = lambda name, rr, resolvers: (
            rdatas if name == "app.example.com" else []
        )
        self.addCleanup(lambda: setattr(dnsguide, "query_union", saved))
        return dnsguide.check_caa("app.example.com", tag, "dns-01", "", "r1")

    def test_iodef_only_is_unrestricted(self):
        ok, _ = self._check(['0 iodef "mailto:sec@example.com"'], "issue")
        self.assertTrue(ok)

    def test_issuewild_does_not_restrict_a_plain_name(self):
        ok, _ = self._check(['0 issuewild "ca.example.net"'], "issue")
        self.assertTrue(ok)

    def test_wildcard_falls_back_to_issue(self):
        ok, _ = self._check(['0 issue "letsencrypt.org"'], "issuewild")
        self.assertTrue(ok)
        ok, why = self._check(['0 issue "ca.example.net"'], "issuewild")
        self.assertFalse(ok)
        self.assertIn("ca.example.net", why)

    def test_unknown_critical_tag_forbids_issuance(self):
        ok, why = self._check(['128 tbs "x"'], "issue")
        self.assertFalse(ok)
        self.assertIn("critical tbs", why)
        ok, _ = self._check(['128 tbs "x"', '0 issue "letsencrypt.org"'], "issue")
        self.assertFalse(ok)
        ok, _ = self._check(['128 iodef "mailto:sec@example.com"'], "issue")
        self.assertTrue(ok)
        ok, _ = self._check(['0 tbs "x"'], "issue")
        self.assertTrue(ok)

    def test_issuewild_overrides_issue_for_a_wildcard(self):
        ok, _ = self._check(
            ['0 issue "letsencrypt.org"', '0 issuewild "ca.example.net"'], "issuewild"
        )
        self.assertFalse(ok)


class TestCaaOnly(unittest.TestCase):
    """--caa-only: the check dns-01 runs before asking the CA."""

    ACCOUNT = "https://acme-v02.api.letsencrypt.org/acme/acct/1"

    def _run(self, query, domain="svc.example.com", tag="issue", timeout=0):
        saved = dnsguide.query_union, dnsguide.time.sleep
        dnsguide.query_union = query
        dnsguide.time.sleep = lambda s: None
        self.addCleanup(lambda: (setattr(dnsguide, "query_union", saved[0]),
                                 setattr(dnsguide.time, "sleep", saved[1])))
        args = argparse.Namespace(domain=domain, caa_tag=tag, challenge="dns-01",
                                  account_uri=self.ACCOUNT, resolver="",
                                  timeout=timeout, interval=1)
        with contextlib.redirect_stderr(io.StringIO()), contextlib.redirect_stdout(io.StringIO()):
            return dnsguide.caa_only(args)

    def test_pinned_to_another_account_fails(self):
        other = '0 issue "letsencrypt.org;accounturi=https://acme-v02.api.letsencrypt.org/acme/acct/2"'
        self.assertEqual(self._run(lambda n, rr, r: [other] if n == "svc.example.com" else []),
                         dnsguide.CAA_FORBIDS)

    def test_inherited_other_ca_fails_a_wildcard(self):
        query = lambda n, rr, r: ['0 issue "digicert.com"'] if n == "example.com" else []
        self.assertEqual(self._run(query, domain="*.svc.example.com", tag="issuewild"),
                         dnsguide.CAA_FORBIDS)

    def test_waits_for_a_replaced_record(self):
        old = '0 issue "letsencrypt.org;accounturi=https://acme-v02.api.letsencrypt.org/acme/acct/2"'
        answers = iter([[old], [old], []])
        query = lambda n, rr, r: next(answers) if n == "svc.example.com" else []
        self.assertEqual(self._run(query, timeout=60), 0)

    def test_no_caa_passes(self):
        self.assertEqual(self._run(lambda n, rr, r: []), 0)

    def test_unreadable_dns_does_not_block(self):
        def broken(name, rr, resolvers):
            raise dnsguide.ResolveError("all resolvers failed")
        self.assertEqual(self._run(broken), 0)


class TestMainChecksCaaOnlyWhenAsked(unittest.TestCase):
    """The record check runs CAA only when `caa` is included."""

    def _main(self, *extra):
        asked = []
        union = lambda name, rr, r: asked.append(rr) or (["gw.example."] if rr == dnsguide.RR_CNAME else [])
        per_resolver = lambda name, rr, r: [("r", ['"x:443"'])]
        argv = ["dnsguide.py", "--domain", "a.example.com", "--alias-target", "gw.example",
                "--txt-name", "_dstack-app-address.a.example.com", "--txt-value", "x:443",
                "--mode", "wait", "--timeout", "0", *extra]
        with mock.patch.object(sys, "argv", argv), \
                mock.patch.object(dnsguide, "query_union", union), \
                mock.patch.object(dnsguide, "query_per_resolver", per_resolver), \
                contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            code = dnsguide.main()
        return code, dnsguide.RR_CAA in asked

    def test_default_include_checks_caa(self):
        self.assertEqual(self._main(), (0, True))

    def test_without_caa_it_is_not_checked(self):
        self.assertEqual(self._main("--include", "cname,txt"), (0, False))


class TestDelegationRecord(unittest.TestCase):
    """The _acme-challenge CNAME that makes challenge delegation work."""

    def _args(self, domain, alias):
        import argparse
        return argparse.Namespace(
            domain=domain, alias_target="gw.example.net",
            txt_name="_dstack-app-address." + domain.lstrip("*."),
            txt_value="appid:443", caa_name="", caa_tag="issue", caa_value="",
            account_uri="", challenge="dns-01", delegation_zone=alias,
            include="challenge-cname",
        )

    def test_points_at_the_delegation_zone(self):
        rec = dnsguide.build_records(self._args("svc.example.com", "deleg.example.net"))[0]
        self.assertEqual(rec.name, "_acme-challenge.svc.example.com")
        self.assertEqual(rec.value, "_acme-challenge.svc.example.com.deleg.example.net")
        self.assertTrue(rec.exact, "a delegation CNAME has no address to fall back to")

    def test_wildcard_validates_at_the_base_name(self):
        rec = dnsguide.build_records(self._args("*.example.com", "deleg.example.net"))[0]
        self.assertEqual(rec.name, "_acme-challenge.example.com")

    def test_absent_without_a_delegation_zone(self):
        self.assertEqual(dnsguide.build_records(self._args("svc.example.com", "")), [])


class TestWildcardDelegation(unittest.TestCase):
    """A wildcard is evaluated at its base, so the base needs its own alias."""

    def _records(self, domain, txt):
        import argparse
        return dnsguide.build_records(argparse.Namespace(
            domain=domain, alias_target="gw", txt_name=txt, txt_value="x",
            caa_name="", caa_tag="issue", caa_value="", account_uri="",
            challenge="dns-01", delegation_zone="deleg.net", include="delegated"))

    def test_wildcard_aliases_its_base_as_well(self):
        names = [r.name for r in self._records(
            "*.app.example.com", "_dstack-app-address-wildcard.app.example.com")]
        self.assertIn("app.example.com", names)
        self.assertEqual(len(names), 4)

    def test_plain_domain_does_not(self):
        names = [r.name for r in self._records(
            "svc.example.com", "_dstack-app-address.svc.example.com")]
        self.assertNotIn("example.com", names)
        self.assertEqual(len(names), 3)


class TestExactCnameCheck(unittest.TestCase):
    """check_alias falls back to comparing addresses; a delegation target has none."""

    REC = dnsguide.Record(type="CNAME", name="_acme-challenge.svc.example.com",
                          value="_acme-challenge.svc.example.com.deleg.example.net",
                          exact=True)

    def _with(self, cnames):
        saved = dnsguide.query_union
        dnsguide.query_union = lambda name, rr, r: cnames if rr == dnsguide.RR_CNAME else []
        self.addCleanup(lambda: setattr(dnsguide, "query_union", saved))

    def test_accepts_the_exact_target(self):
        self._with(["_acme-challenge.svc.example.com.deleg.example.net."])
        ok, _ = dnsguide.check_cname_exact(self.REC, "r")
        self.assertTrue(ok)

    def test_rejects_a_different_target(self):
        self._with(["somewhere.else.example.net."])
        ok, why = dnsguide.check_cname_exact(self.REC, "r")
        self.assertFalse(ok)
        self.assertIn("expected", why)

    def test_reports_absence_without_claiming_it_does_not_resolve(self):
        self._with([])
        ok, why = dnsguide.check_cname_exact(self.REC, "r")
        self.assertFalse(ok)
        self.assertIn("no CNAME record found", why)


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

    def test_wildcard_caa_also_publishes_issue(self):
        caa = [r.value for r in dnsguide.build_records(self._args(caa_tag="issuewild"))
               if r.type == "CAA"]
        self.assertEqual(
            caa,
            ['0 issue "letsencrypt.org;validationmethods=tls-alpn-01"',
             '0 issuewild "letsencrypt.org;validationmethods=tls-alpn-01"'],
        )

    def test_caa_omitted_without_value(self):
        types = [r.type for r in dnsguide.build_records(self._args(caa_value=""))]
        self.assertEqual(types, ["CNAME", "TXT"])


class TestNoShadowedDefinitions(unittest.TestCase):
    """A duplicated class or method silently shadows the earlier one.

    Python does not complain, unittest does not notice, and the count still
    goes up -- so a merge that lands the same block twice leaves dead tests
    that look like passing ones. This caught exactly that.
    """

    def test_every_definition_is_unique(self):
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
