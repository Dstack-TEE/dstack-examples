#!/usr/bin/env python3
"""Unit tests for the Route53 provider against a fake boto3 client.

Run: python3 scripts/tests/test_route53.py
"""

import os
import sys
import types
import unittest
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

sys.modules.setdefault("boto3", types.SimpleNamespace(client=lambda *a, **k: None))

from dns_providers.base import RecordType  # noqa: E402
from dns_providers.route53 import Route53DNSProvider  # noqa: E402


class FakeRoute53:
    """Lists names the way Route53 does: `*` comes back as `\\052`."""

    def __init__(self, record_sets):
        self.record_sets = record_sets
        self.batches = []

    def get_paginator(self, op):
        if op == "list_hosted_zones":
            zones = [{"Id": "/hostedzone/Z1", "Name": "example.com."}]
            return mock.Mock(paginate=lambda **kw: [{"HostedZones": zones}])
        return mock.Mock(
            paginate=lambda **kw: [{"ResourceRecordSets": list(self.record_sets)}]
        )

    def change_resource_record_sets(self, HostedZoneId, ChangeBatch):
        self.batches.append(ChangeBatch["Changes"])
        for change in ChangeBatch["Changes"]:
            rrset = dict(change["ResourceRecordSet"])
            rrset["Name"] = rrset["Name"].replace("*", "\\052")
            key = (rrset["Name"], rrset["Type"])
            self.record_sets = [
                r for r in self.record_sets if (r["Name"], r["Type"]) != key
            ]
            if change["Action"] != "DELETE":
                self.record_sets.append(rrset)
        return {"ChangeInfo": {"Status": "PENDING"}}


def provider(record_sets):
    p = Route53DNSProvider.__new__(Route53DNSProvider)
    p.client = FakeRoute53(record_sets)
    p.hosted_zone_id = p.hosted_zone_name = None
    return p


WILDCARD_CNAME = {
    "Name": "\\052.example.com.",
    "Type": "CNAME",
    "TTL": 60,
    "ResourceRecords": [{"Value": "gw.example"}],
}


class TestEscapedNames(unittest.TestCase):
    def test_wildcard_is_found_under_its_escaped_name(self):
        p = provider([WILDCARD_CNAME])
        records = p.get_dns_records("*.example.com", RecordType.CNAME)
        self.assertEqual([r.content for r in records], ["gw.example"])


@mock.patch("socket.gethostbyname", return_value="203.0.113.7")
class TestSetAddressRecord(unittest.TestCase):
    def test_replaces_the_cname_in_one_change(self, _):
        p = provider([WILDCARD_CNAME])
        self.assertTrue(p.set_address_record("*.example.com", "gw.example"))
        self.assertEqual(len(p.client.batches), 1)
        self.assertEqual(
            [(c["Action"], c["ResourceRecordSet"]["Type"]) for c in p.client.batches[0]],
            [("DELETE", "CNAME"), ("UPSERT", "A")],
        )
        self.assertEqual(
            [(r["Name"], r["Type"]) for r in p.client.record_sets],
            [("\\052.example.com.", "A")],
        )

    def test_rerun_changes_nothing(self, _):
        p = provider([WILDCARD_CNAME])
        p.set_address_record("*.example.com", "gw.example")
        p.set_address_record("*.example.com", "gw.example")
        self.assertEqual(len(p.client.batches), 1)


if __name__ == "__main__":
    unittest.main()
