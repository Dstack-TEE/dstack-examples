#!/usr/bin/env python3

import os
import re
import socket
import sys
from typing import Dict, List, Optional
from .base import DNSProvider, DNSRecord, CAARecord, RecordType



class Route53DNSProvider(DNSProvider):
    """DNS provider implementation for AWS Route53."""

    DETECT_ENV = "AWS_ACCESS_KEY_ID"

    # Certbot configuration
    CERTBOT_PLUGIN = "dns-route53"
    CERTBOT_PLUGIN_MODULE = "certbot_dns_route53"
    CERTBOT_PACKAGE = "certbot-dns-route53==5.1.0"
    CERTBOT_PROPAGATION_SECONDS = None

    def __init__(self):
        super().__init__()

        # Import boto3 here to avoid requiring it unless Route53 is used
        try:
            import boto3

            self.boto3 = boto3
        except ImportError:
            raise ImportError(
                "boto3 is required for Route53 provider. "
                "Install with: pip install boto3"
            )

        try:
            self.client = self.boto3.client("route53")
        except Exception as e:
            raise ValueError(f"Failed to initialize Route53 client: {e}")

        self.hosted_zone_id: Optional[str] = None
        self.hosted_zone_name: Optional[str] = None


    def setup_certbot_credentials(self) -> bool:
        """Setup AWS credentials file for certbot.

        This container will be provided with aws credentials purely for the purpose
        of assuming a role. Doing so will enable the boto platform to provision
        temporary access key and secret keys on demand!

        Using this strategy we can impose least permissive and fast expiring access
        to our domain.

        """

        try:
            # Pre-fetch hosted zone ID if we have a domain
            domain = os.getenv("DOMAIN")
            if domain:
                self._ensure_hosted_zone_id(domain)

            return True

        except Exception as e:
            print(f"Error setting up AWS credentials: {e}", file=sys.stderr)
            return False

    def validate_credentials(self) -> bool:
        """Validate AWS credentials by testing Route53 access."""
        try:
            # Test API access by listing hosted zones (limited response)
            self.client.list_hosted_zones(MaxItems="1")
            print("✓ AWS Route53 credentials are valid")
            return True
        except Exception as e:
            print(f"✗ AWS Route53 credential validation failed: {e}", file=sys.stderr)
            return False

    def _get_hosted_zone_info(self, domain: str) -> Optional[tuple[str, str]]:
        """Get the hosted zone ID and name for a domain.

        Returns:
            Tuple of (hosted_zone_id, hosted_zone_name) or None
        """
        try:
            # List all hosted zones
            paginator = self.client.get_paginator("list_hosted_zones")

            best_match_id = None
            best_match_name = None
            best_match_length = 0

            for page in paginator.paginate():
                for zone in page["HostedZones"]:
                    zone_name = zone["Name"].rstrip(".")  # Remove trailing dot
                    zone_id = zone["Id"].split("/")[-1]  # Extract ID from full path

                    # Exact match
                    if domain == zone_name:
                        return (zone_id, zone_name)

                    # Subdomain match - find the most specific (longest) zone
                    if (
                        domain.endswith(f".{zone_name}")
                        and len(zone_name) > best_match_length
                    ):
                        best_match_length = len(zone_name)
                        best_match_id = zone_id
                        best_match_name = zone_name

            if best_match_id:
                return (best_match_id, best_match_name)
            else:
                print(f"No hosted zone found for domain: {domain}", file=sys.stderr)
                return None

        except Exception as e:
            print(f"Error getting hosted zone: {e}", file=sys.stderr)
            return None

    def _ensure_hosted_zone_id(self, domain: str) -> Optional[str]:
        """Ensure we have a hosted zone ID for the domain, fetching if necessary."""
        domain = domain.lower().rstrip(".")
        # Check if we can reuse cached zone
        if self.hosted_zone_id and self.hosted_zone_name:
            if domain == self.hosted_zone_name or domain.endswith(
                f".{self.hosted_zone_name}"
            ):
                return self.hosted_zone_id

        # Fetch zone info
        zone_info = self._get_hosted_zone_info(domain)
        if not zone_info:
            return None
        self.hosted_zone_id, self.hosted_zone_name = zone_info
        return self.hosted_zone_id

    def _normalize_record_name(self, name: str) -> str:
        """Normalize record name to lowercase FQDN with trailing dot (Route53 format).

        Route53 lists characters outside [a-z0-9-_] as octal escapes, `*` as
        `\\052`, so decode them to compare with the names we are given.
        """
        name = re.sub(r"\\([0-7]{3})", lambda m: chr(int(m.group(1), 8)), name)
        return f"{name.lower().rstrip('.')}."

    def get_dns_records(
        self, name: str, record_type: Optional[RecordType] = None
    ) -> List[DNSRecord]:
        """Get DNS records for a domain."""
        hosted_zone_id = self._ensure_hosted_zone_id(name)
        if not hosted_zone_id:
            raise RuntimeError(f"Could not find hosted zone for domain {name}")

        normalized_name = self._normalize_record_name(name)

        print(f"Checking for existing DNS records for {name}")

        try:
            # List resource record sets for the hosted zone
            paginator = self.client.get_paginator("list_resource_record_sets")
            records = []

            for page in paginator.paginate(HostedZoneId=hosted_zone_id):
                for record_set in page["ResourceRecordSets"]:
                    record_name = record_set["Name"]
                    record_type_str = record_set["Type"]

                    # Filter by name
                    if self._normalize_record_name(record_name) != normalized_name:
                        continue

                    # Filter by type if specified
                    if record_type and record_type_str != record_type.value:
                        continue

                    # Parse record content
                    content = ""
                    data = None

                    if record_type_str == "CAA":
                        # CAA records have special format
                        if "ResourceRecords" in record_set:
                            caa_value = record_set["ResourceRecords"][0]["Value"]
                            # Format: "flags tag value"
                            parts = caa_value.split(" ", 2)
                            if len(parts) >= 3:
                                flags = int(parts[0])
                                tag = parts[1]
                                value = parts[2].strip('"')
                                content = caa_value
                                data = {"flags": flags, "tag": tag, "value": value}
                    else:
                        # Standard records
                        if "ResourceRecords" in record_set:
                            # Get first record value (multiple values would need separate DNSRecord objects)
                            content = record_set["ResourceRecords"][0]["Value"]
                            # Remove quotes from TXT records
                            if record_type_str == "TXT":
                                content = content.strip('"')
                        elif "AliasTarget" in record_set:
                            # Alias record (Route53 specific)
                            content = record_set["AliasTarget"]["DNSName"].rstrip(".")

                    # Route53 doesn't have persistent record IDs, use name+type as identifier
                    record_id = f"{record_name}:{record_type_str}"

                    records.append(
                        DNSRecord(
                            id=record_id,
                            name=name,  # Return original name without trailing dot
                            type=RecordType(record_type_str),
                            content=content,
                            ttl=record_set.get("TTL", 60),
                            proxied=False,  # Route53 doesn't have proxy feature
                            priority=None,  # Would be in record value for MX/SRV
                            data=data,
                        )
                    )

            return records

        except Exception as e:
            raise RuntimeError(f"Failed to list DNS records for {name}: {e}") from e

    def create_dns_record(self, record: DNSRecord) -> bool:
        """Create a DNS record."""
        hosted_zone_id = self._ensure_hosted_zone_id(record.name)
        if not hosted_zone_id:
            print(
                f"Error: Could not find hosted zone for domain {record.name}",
                file=sys.stderr,
            )
            return False

        normalized_name = self._normalize_record_name(record.name)

        # Prepare record value
        if record.type == RecordType.TXT:
            # TXT records need to be quoted
            record_value = f'"{record.content}"'
        else:
            record_value = record.content

        # Prepare change batch
        change_batch = {
            "Changes": [
                {
                    "Action": "UPSERT",  # UPSERT creates or updates
                    "ResourceRecordSet": {
                        "Name": normalized_name,
                        "Type": record.type.value,
                        "TTL": record.ttl,
                        "ResourceRecords": [{"Value": record_value}],
                    },
                }
            ]
        }

        try:
            print(f"Adding {record.type.value} record for {record.name}")
            response = self.client.change_resource_record_sets(
                HostedZoneId=hosted_zone_id, ChangeBatch=change_batch
            )

            # Check if change was successful
            change_info = response.get("ChangeInfo", {})
            if change_info.get("Status") in ["PENDING", "INSYNC"]:
                return True
            else:
                print(
                    f"Unexpected change status: {change_info.get('Status')}",
                    file=sys.stderr,
                )
                return False

        except Exception as e:
            print(f"Error creating DNS record: {e}", file=sys.stderr)
            return False

    def delete_dns_record(self, record_id: str, domain: str) -> bool:
        """Delete a DNS record.

        Args:
            record_id: Format is "name:type" since Route53 doesn't have persistent IDs
            domain: The domain name (for zone lookup)
        """
        hosted_zone_id = self._ensure_hosted_zone_id(domain)
        if not hosted_zone_id:
            print(
                f"Error: Could not find hosted zone for domain {domain}",
                file=sys.stderr,
            )
            return False

        # Parse record_id to get name and type
        try:
            record_name, record_type = record_id.split(":", 1)
        except ValueError:
            print(f"Invalid record_id format: {record_id}", file=sys.stderr)
            return False

        try:
            # First, get the current record to know its full details
            record_set_to_delete = self._find_record_set(
                hosted_zone_id, record_name, record_type
            )

            if not record_set_to_delete:
                print(f"Record not found: {record_id}", file=sys.stderr)
                return False

            # Prepare DELETE change batch with exact record details
            change_batch = {
                "Changes": [
                    {"Action": "DELETE", "ResourceRecordSet": record_set_to_delete}
                ]
            }

            print(f"Deleting record: {record_id}")
            response = self.client.change_resource_record_sets(
                HostedZoneId=hosted_zone_id, ChangeBatch=change_batch
            )

            change_info = response.get("ChangeInfo", {})
            if change_info.get("Status") in ["PENDING", "INSYNC"]:
                return True
            else:
                print(
                    f"Unexpected change status: {change_info.get('Status')}",
                    file=sys.stderr,
                )
                return False

        except Exception as e:
            print(f"Error deleting DNS record: {e}", file=sys.stderr)
            return False

    def set_address_record(self, name: str, content: str, ttl: int = 60) -> bool:
        """Replace a CNAME or AAAA at `name` with an A record in one change.

        Deleting the CNAME first, as the generic helper does, would leave the
        name without an answer in between, and resolvers cache that.
        """
        ip_address = socket.gethostbyname(content)
        hosted_zone_id = self._ensure_hosted_zone_id(name)
        if not hosted_zone_id:
            print(f"Error: Could not find hosted zone for domain {name}", file=sys.stderr)
            return False

        try:
            existing = self._record_sets(hosted_zone_id, name)
        except Exception as e:
            print(f"Error getting DNS records: {e}", file=sys.stderr)
            return False

        wanted = {
            "Name": self._normalize_record_name(name),
            "Type": "A",
            "TTL": ttl,
            "ResourceRecords": [{"Value": ip_address}],
        }
        changes = [
            {"Action": "DELETE", "ResourceRecordSet": existing[t]}
            for t in ("CNAME", "AAAA")
            if t in existing
        ]
        current = existing.get("A")
        if not changes and current and current.get("ResourceRecords") == wanted["ResourceRecords"]:
            print("A record with the same IP already exists")
            return True
        changes.append({"Action": "UPSERT", "ResourceRecordSet": wanted})

        try:
            print(f"Creating A record for {name} pointing to {ip_address} ({content})")
            response = self.client.change_resource_record_sets(
                HostedZoneId=hosted_zone_id, ChangeBatch={"Changes": changes}
            )
        except Exception as e:
            print(f"Error setting A record: {e}", file=sys.stderr)
            return False
        status = response.get("ChangeInfo", {}).get("Status")
        if status in ["PENDING", "INSYNC"]:
            return True
        print(f"Unexpected change status: {status}", file=sys.stderr)
        return False

    def _record_sets(self, hosted_zone_id: str, name: str) -> Dict[str, dict]:
        """Return the record sets at `name`, keyed by type."""
        name = self._normalize_record_name(name)
        found = {}
        paginator = self.client.get_paginator("list_resource_record_sets")
        for page in paginator.paginate(HostedZoneId=hosted_zone_id):
            for record_set in page["ResourceRecordSets"]:
                if self._normalize_record_name(record_set["Name"]) == name:
                    found.setdefault(record_set["Type"], record_set)
        return found

    def _find_record_set(
        self, hosted_zone_id: str, name: str, record_type: str
    ) -> Optional[dict]:
        """Return the record set for (name, type), or None if there is none."""
        return self._record_sets(hosted_zone_id, name).get(record_type)

    def set_caa_record(
        self,
        name: str,
        tag: str,
        value: str,
        flags: int = 0,
        ttl: int = 60,
    ) -> bool:
        """Set a CAA record in one change.

        create_caa_record already replaces the values with the same tag
        atomically; deleting them first, as the generic helper does, would
        leave the name briefly without that tag.
        """
        return self.create_caa_record(
            CAARecord(name=name, flags=flags, tag=tag, value=value, ttl=ttl)
        )

    def create_caa_record(self, caa_record: CAARecord) -> bool:
        """Merge a CAA value into the record set at caa_record.name.

        Route53 keys a record set by name and type, so iodef and other tags
        share it with ours: replace only the values carrying the same tag and
        keep the rest.
        """
        hosted_zone_id = self._ensure_hosted_zone_id(caa_record.name)
        if not hosted_zone_id:
            print(
                f"Error: Could not find hosted zone for domain {caa_record.name}",
                file=sys.stderr,
            )
            return False

        normalized_name = self._normalize_record_name(caa_record.name)
        tag = caa_record.tag.lower()
        new_value = f'{caa_record.flags} {tag} "{caa_record.value}"'

        try:
            existing = self._find_record_set(hosted_zone_id, normalized_name, "CAA")
        except Exception as e:
            raise RuntimeError(
                f"Failed to list DNS records for {caa_record.name}: {e}"
            ) from e

        ttl = caa_record.ttl
        values: List[str] = []
        if existing:
            ttl = existing.get("TTL", ttl)
            values = [rr["Value"] for rr in existing.get("ResourceRecords", [])]

        merged = [v for v in values if v.lower().split(" ", 2)[1:2] != [tag]]
        merged.append(new_value)
        if sorted(merged) == sorted(values):
            print("CAA record with the same content already exists")
            return True

        change_batch = {
            "Changes": [
                {
                    "Action": "UPSERT",
                    "ResourceRecordSet": {
                        "Name": normalized_name,
                        "Type": "CAA",
                        "TTL": ttl,
                        "ResourceRecords": [{"Value": v} for v in merged],
                    },
                }
            ]
        }

        try:
            print(f"Setting CAA record set for {caa_record.name}: {', '.join(merged)}")
            response = self.client.change_resource_record_sets(
                HostedZoneId=hosted_zone_id, ChangeBatch=change_batch
            )

            change_info = response.get("ChangeInfo", {})
            if change_info.get("Status") in ["PENDING", "INSYNC"]:
                return True
            else:
                print(
                    f"Unexpected change status for CAA update: "
                    f"{change_info.get('Status')}",
                    file=sys.stderr,
                )
                return False

        except Exception as e:
            print(f"Error setting CAA record: {e}", file=sys.stderr)
            return False
