#!/usr/bin/env python3

import os
import sys
import json
import socket
import requests
from typing import Dict, List, Optional
from .base import (
    HTTP_TIMEOUT,
    CAARecord,
    DNSProvider,
    DNSRecord,
    RecordType,
    write_secret_file,
)


class LinodeDNSProvider(DNSProvider):
    """DNS provider implementation for Linode DNS."""

    DETECT_ENV = "LINODE_API_TOKEN"

    # Certbot configuration
    CERTBOT_PLUGIN = "dns-linode"
    CERTBOT_PLUGIN_MODULE = "certbot_dns_linode"
    CERTBOT_PACKAGE = "certbot-dns-linode"
    CERTBOT_PROPAGATION_SECONDS = 300
    CERTBOT_CREDENTIALS_FILE = "~/.linode/credentials.ini"

    # Linode's maximum; most zones then fit in a single request.
    PAGE_SIZE = 500

    def __init__(self):
        super().__init__()
        self.api_token = os.getenv("LINODE_API_TOKEN")
        if not self.api_token:
            raise ValueError("LINODE_API_TOKEN environment variable is required")
        self.base_url = "https://api.linode.com/v4"
        self.headers = {
            "Authorization": f"Bearer {self.api_token}",
            "Content-Type": "application/json",
        }
        self.zone_id: Optional[str] = None  # Will be set when needed
        self.zone_domain: Optional[str] = None  # Cache the domain for the zone

    def setup_certbot_credentials(self) -> bool:
        """Setup Linode credentials file for certbot."""
        credentials_file = os.path.expanduser(self.CERTBOT_CREDENTIALS_FILE)
        credentials_dir = os.path.dirname(credentials_file)

        try:
            # Create credentials directory
            os.makedirs(credentials_dir, exist_ok=True)

            write_secret_file(
                credentials_file,
                "# WARNING: This file contains sensitive credentials for Linode DNS API.\n"
                "# Ensure this file is kept secure and not shared.\n"
                f"dns_linode_key = {self.api_token}\n",
            )
            print(f"Linode credentials file created: {credentials_file}")

            # Pre-fetch zone ID if we have a domain
            domain = os.getenv("DOMAIN")
            if domain:
                self._ensure_zone_id(domain)

            return True

        except Exception as e:
            print(f"Error setting up Linode credentials: {e}", file=sys.stderr)
            return False

    def _make_request(
        self, method: str, endpoint: str, data: Optional[Dict] = None
    ) -> Dict:
        """Make a request to the Linode API with error handling."""
        url = f"{self.base_url}/{endpoint}"
        try:
            response = requests.request(
                method, url, headers=self.headers, json=data, timeout=HTTP_TIMEOUT
            )

            if response.status_code == 404:
                return {
                    "success": False,
                    "errors": [{"field": "not_found", "reason": "Resource not found"}],
                }

            response.raise_for_status()

            # For DELETE requests, Linode returns empty response
            if method.upper() == "DELETE" and response.status_code == 200:
                return {"success": True}

            # For successful GET/POST/PUT, parse JSON
            if response.content:
                result = response.json()
                return {"success": True, "data": result}
            else:
                return {"success": True}

        except requests.exceptions.RequestException as e:
            print(f"Request Error: {str(e)}", file=sys.stderr)
            if data:
                print(f"Request data: {json.dumps(data)}", file=sys.stderr)
            return {"success": False, "errors": [{"reason": str(e)}]}
        except json.JSONDecodeError:
            print("JSON Decode Error: Could not parse response", file=sys.stderr)
            return {
                "success": False,
                "errors": [{"reason": "Could not parse response"}],
            }
        except Exception as e:
            print(f"Unexpected Error: {str(e)}", file=sys.stderr)
            return {"success": False, "errors": [{"reason": str(e)}]}

    def _get_all(self, endpoint: str) -> Optional[List[Dict]]:
        """GET every page of a paginated Linode collection, or None on failure."""
        items: List[Dict] = []
        page = 1
        pages = 1
        while page <= pages:
            result = self._make_request(
                "GET", f"{endpoint}?page={page}&page_size={self.PAGE_SIZE}"
            )
            if not result.get("success", False):
                return None
            body = result.get("data", {})
            items.extend(body.get("data", []))
            pages = body.get("pages", 1)
            page += 1
        return items

    def _get_zone_id(self, domain: str) -> Optional[str]:
        """Get the domain ID for a domain in Linode."""
        domains = self._get_all("domains")
        if domains is None:
            return None

        best_match_domain = None
        best_match_length = 0

        for domain_obj in domains:
            domain_name = domain_obj.get("domain", "")
            if domain == domain_name:
                return str(domain_obj.get("id"))
            if (
                domain.endswith(f".{domain_name}")
                and len(domain_name) > best_match_length
            ):
                best_match_length = len(domain_name)
                best_match_domain = domain_obj.get("id")

        if best_match_domain:
            return str(best_match_domain)
        else:
            print(f"Domain not found: {domain}", file=sys.stderr)
            return None

    def _get_subdomain(self, fqdn: str, domain_id: str) -> str:
        """Get the subdomain part for a record."""
        # First, get the domain name
        result = self._make_request("GET", f"domains/{domain_id}")
        if not result.get("success", False):
            raise RuntimeError(f"Failed to look up Linode domain {domain_id}")

        domain_name = result.get("data", {}).get("domain", "")

        if fqdn == domain_name:
            return ""  # Root domain
        elif fqdn.endswith(f".{domain_name}"):
            return fqdn[: -len(domain_name) - 1]
        else:
            return fqdn

    def _ensure_zone_id(self, domain: str) -> Optional[str]:
        """Ensure we have a zone ID for the domain, fetching if necessary."""
        # If we already have a zone_id and it's for a parent domain, reuse it
        if self.zone_id and self.zone_domain:
            if domain == self.zone_domain or domain.endswith(f".{self.zone_domain}"):
                return self.zone_id

        # Otherwise fetch the zone ID
        self.zone_id = self._get_zone_id(domain)
        if self.zone_id:
            # Store the base domain for this zone
            # For Linode, we need to get the actual domain from the API
            result = self._make_request("GET", f"domains/{self.zone_id}")
            if result.get("success", False):
                self.zone_domain = result.get("data", {}).get("domain", "")
        return self.zone_id

    def get_dns_records(
        self, name: str, record_type: Optional[RecordType] = None
    ) -> List[DNSRecord]:
        """Get DNS records for a domain."""
        zone_id = self._ensure_zone_id(name)
        if not zone_id:
            raise RuntimeError(f"Could not find zone for domain {name}")

        all_records = self._get_all(f"domains/{zone_id}/records")
        if all_records is None:
            raise RuntimeError(f"Failed to list DNS records for {name}")

        print(f"Checking for existing DNS records for {name}")

        records = []
        subdomain = self._get_subdomain(name, zone_id)

        for record_data in all_records:
            record_name = record_data.get("name", "")

            # Match records by subdomain
            if record_name == subdomain:
                record_type_str = record_data.get("type", "")

                # Filter by record type if specified
                if record_type and record_type.value != record_type_str:
                    continue

                # Parse CAA record data if applicable
                data = None
                if record_type_str == "CAA":
                    # Linode stores CAA with separate tag and target fields
                    target = record_data.get("target", "")
                    tag = record_data.get("tag", "issue")

                    data = {
                        "flags": 0,  # Linode doesn't support flags (always 0)
                        "tag": tag,
                        "value": target.strip('"'),
                    }

                records.append(
                    DNSRecord(
                        id=str(record_data.get("id")),
                        name=name,
                        type=RecordType(record_type_str),
                        content=record_data.get("target", ""),
                        ttl=record_data.get("ttl_sec", 60),
                        priority=record_data.get("priority"),
                        data=data,
                    )
                )

        return records

    def create_dns_record(self, record: DNSRecord) -> bool:
        """Create a DNS record."""
        zone_id = self._ensure_zone_id(record.name)
        if not zone_id:
            print(
                f"Error: Could not find zone for domain {record.name}", file=sys.stderr
            )
            return False

        subdomain = self._get_subdomain(record.name, zone_id)

        data = {
            "type": record.type.value,
            "name": subdomain,
            "target": record.content,
            "ttl_sec": record.ttl,
        }

        # Handle specific record types
        if record.type == RecordType.TXT:
            # Ensure TXT records have quotes
            if not record.content.startswith('"'):
                data["target"] = f'"{record.content}"'

        if record.priority is not None:
            data["priority"] = record.priority

        print(f"Adding {record.type.value} record for {record.name}")
        result = self._make_request("POST", f"domains/{zone_id}/records", data)

        return result.get("success", False)

    def delete_dns_record(self, record_id: str, domain: str) -> bool:
        """Delete a DNS record."""
        zone_id = self._ensure_zone_id(domain)
        if not zone_id:
            print(f"Error: Could not find zone for domain {domain}", file=sys.stderr)
            return False

        print(f"Deleting record ID: {record_id}")
        result = self._make_request("DELETE", f"domains/{zone_id}/records/{record_id}")

        return result.get("success", False)

    def set_alias_record(
        self,
        name: str,
        content: str,
        ttl: int = 60,
        proxied: bool = False,
    ) -> bool:
        """Override to use A record instead of CNAME for Linode to avoid CAA conflicts.

        Linode doesn't allow CAA and CNAME records on the same subdomain.
        Using A records solves this limitation.
        """
        # Resolve domain to IP
        domain = content
        print(f"Trying to resolve: {domain}")
        ip_address = socket.gethostbyname(domain)
        print(f"✅ Resolved {domain} to IP: {ip_address}")

        self.clear_conflicting_alias(name, RecordType.A)

        print(
            f"Creating A record for {name} pointing to {ip_address} (instead of CNAME to {content})"
        )
        # Use the base class's set_a_record method with idempotency
        return self.set_a_record(name, ip_address, ttl, proxied=False)

    def create_caa_record(self, caa_record: CAARecord) -> bool:
        """Create a CAA record."""
        zone_id = self._ensure_zone_id(caa_record.name)
        if not zone_id:
            print(
                f"Error: Could not find zone for domain {caa_record.name}",
                file=sys.stderr,
            )
            return False

        subdomain = self._get_subdomain(caa_record.name, zone_id)

        # Clean up the value
        clean_value = caa_record.value.strip('"')

        # Linode CAA format uses separate tag and target fields
        # The flags are not supported in Linode API (always 0)
        data = {
            "type": "CAA",
            "name": subdomain,
            "tag": caa_record.tag,
            "target": clean_value,
            "ttl_sec": caa_record.ttl,
        }

        print(
            f"Adding CAA record for {caa_record.name} with tag {caa_record.tag} and value {clean_value}"
        )
        result = self._make_request("POST", f"domains/{zone_id}/records", data)

        return result.get("success", False)
