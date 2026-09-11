#!/usr/bin/env python3
"""Regression tests for gateway targets supplied by the shipped examples.

Run: python3 scripts/tests/test_gateway_target.py
"""

import argparse
import os
from pathlib import Path
import re
import subprocess
import sys
import unittest

SCRIPTS = Path(__file__).resolve().parents[1]
INGRESS = SCRIPTS.parent
REPO = INGRESS.parents[1]
sys.path.insert(0, str(SCRIPTS))

import dnsguide  # noqa: E402


class TestGatewayTarget(unittest.TestCase):
    def test_multi_domain_compose_target(self):
        compose = (INGRESS / "docker-compose.multi.yaml").read_text()
        match = re.search(r"GATEWAY_DOMAIN: (\S+)", compose)
        assert match is not None, "multi-domain compose must configure a gateway"
        target = match.group(1)
        self.assertEqual(target, "gateway.dstack-prod5.phala.network")
        self.assert_guide_target(target)

    def test_k3s_interpolated_target(self):
        compose = (REPO / "k3s/docker-compose.yaml").read_text()
        match = re.search(r"GATEWAY_DOMAIN=(\S+)", compose)
        assert match is not None, "k3s compose must configure a gateway"
        target = match.group(1)
        target = target.replace("${DSTACK_GATEWAY_DOMAIN}", "cluster.example.net")
        self.assertEqual(target, "gateway.cluster.example.net")
        self.assert_guide_target(target)

    def test_e2e_default_and_explicit_override(self):
        script = (SCRIPTS / "tests/e2e-test.sh").read_text()
        match = re.search(r"^GATEWAY_DOMAIN=.*$", script, re.MULTILINE)
        assert match is not None, "e2e script must configure a gateway"
        assignment = match.group(0)
        for override, expected in (
            (None, "gateway.dstack-prod5.phala.network"),
            ("edge.operator.example", "edge.operator.example"),
            ("_.legacy.example", "_.legacy.example"),
        ):
            with self.subTest(override=override):
                env = os.environ.copy()
                env.pop("GATEWAY_DOMAIN", None)
                if override is not None:
                    env["GATEWAY_DOMAIN"] = override
                target = subprocess.check_output(
                    ["bash", "-c", assignment + '\nprintf "%s" "$GATEWAY_DOMAIN"'],
                    env=env, text=True,
                )
                self.assertEqual(target, expected)
                self.assert_guide_target(target)

    def assert_guide_target(self, target):
        for challenge in ("dns-01", "tls-alpn-01"):
            with self.subTest(challenge=challenge, target=target):
                records = dnsguide.build_records(argparse.Namespace(
                    domain="app.example.com", alias_target=target,
                    txt_name="_dstack-app-address.app.example.com",
                    txt_value="deadbeef:443", caa_name="app.example.com",
                    caa_tag="issue", caa_value="letsencrypt.org",
                    account_uri="", challenge=challenge,
                    delegation_zone="deleg.example.net",
                    include="cname,txt,caa,challenge-cname",
                ))
                self.assertEqual(records[0].value, target)
                self.assertEqual(records[1].name, "_dstack-app-address.app.example.com")
                self.assertEqual(records[2].name, "_acme-challenge.app.example.com")
                self.assertEqual(records[2].value,
                                 "_acme-challenge.app.example.com.deleg.example.net")
                self.assertEqual(records[3].value, '0 issue "letsencrypt.org"')


if __name__ == "__main__":
    unittest.main(verbosity=2)
