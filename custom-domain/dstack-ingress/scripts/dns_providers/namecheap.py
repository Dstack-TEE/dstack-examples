#!/usr/bin/env python3

import json
import os
import requests
import xml.etree.ElementTree as ET
from typing import Dict, List, Optional
from .base import (
    HTTP_TIMEOUT,
    CAARecord,
    DNSProvider,
    DNSRecord,
    RecordType,
    write_secret_file,
)

NS = "{http://api.namecheap.com/xml.response}"


class NamecheapDNSProvider(DNSProvider):
    """Namecheap DNS provider implementation."""

    DETECT_ENV = "NAMECHEAP_API_KEY"
    CERTBOT_PLUGIN = "dns-namecheap"
    CERTBOT_PLUGIN_MODULE = "certbot_dns_namecheap"
    CERTBOT_PACKAGE = "certbot-dns-namecheap==1.0.0"
    CERTBOT_PROPAGATION_SECONDS = 120
    CERTBOT_CREDENTIALS_FILE = "~/.namecheap/namecheap.ini"

    def __init__(self):
        """Initialize the Namecheap DNS provider."""
        super().__init__()
        self.username = os.environ.get("NAMECHEAP_USERNAME")
        self.api_key = os.environ.get("NAMECHEAP_API_KEY")
        self.client_ip = os.environ.get("NAMECHEAP_CLIENT_IP", "127.0.0.1")
        self.sandbox = os.environ.get("NAMECHEAP_SANDBOX", "false").lower() == "true"
        
        if not self.username or not self.api_key:
            raise ValueError("NAMECHEAP_USERNAME and NAMECHEAP_API_KEY are required")
        
        if self.sandbox:
            self.base_url = "https://api.sandbox.namecheap.com/xml.response"
        else:
            self.base_url = "https://api.namecheap.com/xml.response"

    def setup_certbot_credentials(self) -> bool:
        """Setup credentials file for certbot."""
        try:
            cred_dir = os.path.expanduser("~/.namecheap")
            os.makedirs(cred_dir, exist_ok=True)
            
            cred_file = os.path.join(cred_dir, "namecheap.ini")
            write_secret_file(
                cred_file,
                "# Namecheap API credentials used by Certbot\n"
                f"dns_namecheap_username={self.username}\n"
                f"dns_namecheap_api_key={self.api_key}\n",
            )
            print(f"Credentials file created: {cred_file}")
            return True
        except Exception as e:
            print(f"Error setting up credentials file: {e}")
            return False

    def validate_credentials(self) -> bool:
        """Validate Namecheap API credentials by testing API access."""
        print(f"Validating Namecheap API credentials...")
        
        try:
            # Test API access with getBalances command
            test_result = self._make_request("namecheap.users.getBalances")
            if test_result.get("success", False):
                print(f"✓ Namecheap API credentials are valid")
                return True
            else:
                print(f"✗ Namecheap API validation failed: {test_result.get('errors', ['Unknown error'])}")
                return False
        except Exception as e:
            print(f"Error validating Namecheap credentials: {e}")
            return False

    def _make_request(self, command: str, **params) -> Dict:
        """Make a request to the Namecheap API with error handling."""
        # Base parameters required for all Namecheap API calls
        request_params = {
            "ApiUser": self.username,
            "ApiKey": self.api_key,
            "UserName": self.username,
            "ClientIp": self.client_ip,
            "Command": command
        }
        
        # Add additional parameters
        request_params.update(params)
        
        try:
            response = requests.post(
                self.base_url, data=request_params, timeout=HTTP_TIMEOUT
            )
            response.raise_for_status()
            
            # Parse XML response
            root = ET.fromstring(response.content)
            
            # Check for API errors
            errors = root.find('.//{http://api.namecheap.com/xml.response}Errors')
            if errors is not None and len(errors) > 0:
                error_messages = []
                for error in errors:
                    error_messages.append(f"Code: {error.get('Number')}, Message: {error.text}")
                error_msg = "\n".join(error_messages)
                print(f"Namecheap API Error: {error_msg}")
                return {"success": False, "errors": error_messages}
            
            # Check response status
            status = root.get('Status')
            if status != 'OK':
                print(f"Namecheap API Response Status: {status}")
                return {"success": False, "errors": [{"message": f"API returned status: {status}"}]}
            
            return {"success": True, "result": root}
            
        except requests.exceptions.RequestException as e:
            print(f"Namecheap API Request Error: {str(e)}")
            return {"success": False, "errors": [{"message": str(e)}]}
        except ET.ParseError as e:
            print(f"Namecheap API XML Parse Error: {str(e)}")
            return {"success": False, "errors": [{"message": f"XML Parse Error: {str(e)}"}]}
        except Exception as e:
            print(f"Namecheap API Unexpected Error: {str(e)}")
            return {"success": False, "errors": [{"message": str(e)}]}

    def _get_domain_info(self, domain: str) -> Optional[tuple]:
        """Extract SLD and TLD from domain."""
        parts = domain.rstrip('.').split('.')
        if len(parts) < 2:
            return None
        
        # For Namecheap, we need the registered domain name
        # This is a simplified approach - assumes the domain is the last two parts
        sld = parts[-2]
        tld = '.'.join(parts[-1:])
        
        return sld, tld

    def _get_hosts(self, sld: str, tld: str) -> List[Dict[str, str]]:
        """Read the zone's full host list.

        setHosts replaces the whole zone, so callers must never write back a
        list that did not come from a successful read: raise instead of
        returning an empty or partial list.
        """
        result = self._make_request(
            "namecheap.domains.dns.getHosts",
            SLD=sld,
            TLD=tld
        )
        hosts_result = None
        if result.get("success", False):
            hosts_result = result["result"].find(f".//{NS}DomainDNSGetHostsResult")
        if hosts_result is None:
            raise RuntimeError(
                f"Failed to read DNS records for {sld}.{tld}: {result.get('errors', 'no host list in response')}"
            )
        return [dict(host.attrib) for host in hosts_result.findall(f"{NS}host")]

    @staticmethod
    def _host_fqdn(host_name: str, sld: str, tld: str) -> str:
        domain = f"{sld}.{tld}"
        return domain if host_name == "@" else f"{host_name}.{domain}"

    @classmethod
    def _host_key(cls, host: Dict[str, str], sld: str, tld: str) -> str:
        """Identify a host by its content: setHosts renumbers HostIds."""
        fqdn = cls._host_fqdn(host.get("Name", "@"), sld, tld).lower()
        return json.dumps([fqdn, host.get("Type"), host.get("Address")])

    def get_dns_records(
        self, name: str, record_type: Optional[RecordType] = None
    ) -> List[DNSRecord]:
        """Get DNS records for a domain."""
        domain_info = self._get_domain_info(name)
        if not domain_info:
            print(f"Could not determine domain info from {name}")
            return []
        
        sld, tld = domain_info
        print(f"Getting DNS records for {name} (SLD: {sld}, TLD: {tld})")
        
        hosts = self._get_hosts(sld, tld)
        wanted = name.rstrip(".").lower()
        
        records = []
        for host in hosts:
            record_name = self._host_fqdn(host.get("Name", "@"), sld, tld)
            record_type_str = host.get("Type")
            
            if record_name.lower() != wanted:
                continue
            if record_type and record_type_str != record_type.value:
                continue
            
            content = host.get("Address")
            if record_type_str == "CNAME":
                # Namecheap returns CNAME targets fully qualified
                content = content.rstrip(".")

            # Create DNS record
            record = DNSRecord(
                id=self._host_key(host, sld, tld),
                name=record_name,
                type=RecordType(record_type_str),
                content=content,
                ttl=int(host.get("TTL", "1800")),
                proxied=False,
                priority=int(host.get("MXPref", "10")) if host.get("MXPref") else None
            )
            
            # Add CAA-specific data
            if record_type_str == "CAA":
                # Parse CAA record content (format: flags tag value)
                content = host.get("Address", "")
                parts = content.split(" ", 2)
                if len(parts) >= 3:
                    record.data = {
                        "flags": int(parts[0]),
                        "tag": parts[1],
                        "value": parts[2]
                    }
            
            records.append(record)
        
        return records

    def create_dns_record(self, record: DNSRecord) -> bool:
        """Create a DNS record."""
        domain_info = self._get_domain_info(record.name)
        if not domain_info:
            print(f"Could not determine domain info from {record.name}")
            return False
        
        sld, tld = domain_info
        domain = f"{sld}.{tld}"
        name = record.name.rstrip(".")
        hostname = "@" if name.lower() == domain.lower() else name[:-len(domain) - 1]
        
        # Replace existing records of the same type and name, keep the rest of the zone
        hosts = self._get_hosts(sld, tld)
        all_records = [
            h for h in hosts
            if not (
                self._host_fqdn(h.get("Name", "@"), sld, tld).lower() == name.lower()
                and h.get("Type") == record.type.value
            )
        ]

        # Add new record
        new_record = {"Name": hostname, "Type": record.type.value, "Address": record.content, "TTL": str(record.ttl)}
        if record.type == RecordType.MX and record.priority:
            new_record["MXPref"] = str(record.priority)
        all_records.append(new_record)

        return self._set_dns_records(sld, tld, all_records)

    def delete_dns_record(self, record_id: str, domain: str) -> bool:
        """Delete a DNS record."""
        domain_info = self._get_domain_info(domain)
        if not domain_info:
            return False

        sld, tld = domain_info
        hosts = self._get_hosts(sld, tld)
        all_records = [h for h in hosts if self._host_key(h, sld, tld) != record_id]
        if len(all_records) == len(hosts):
            print(f"No record {record_id} in {sld}.{tld}; nothing to delete")
            return True

        return self._set_dns_records(sld, tld, all_records)

    def create_caa_record(self, caa_record: CAARecord) -> bool:
        """Create a CAA record."""
        # Namecheap doesn't support CAA records through their API currently
        # This is a limitation of their API
        print(f"Warning: Namecheap API does not currently support CAA records")
        print(f"You need to manually add CAA record for {caa_record.name}")
        return True  # Return True to not break the workflow

    def _set_dns_records(self, sld: str, tld: str, records: List[Dict[str, str]]) -> bool:
        """Set DNS records for a domain."""
        # Prepare host records parameters
        params = {
            "SLD": sld,
            "TLD": tld
        }
        
        # Add host records to parameters
        for i, record in enumerate(records, 1):
            params[f"HostName{i}"] = record.get("Name", "@")
            params[f"RecordType{i}"] = record.get("Type", "A")
            params[f"Address{i}"] = record.get("Address", "")
            params[f"TTL{i}"] = record.get("TTL", "1800")
            
            # Add MXPref for MX records
            if record.get("Type") == "MX":
                params[f"MXPref{i}"] = record.get("MXPref", "10")
        
        print(f"Setting DNS records for {sld}.{tld}")
        result = self._make_request("namecheap.domains.dns.setHosts", **params)
        
        return result.get("success", False)

    def set_alias_record(
        self,
        name: str,
        content: str,
        ttl: int = 60,
        proxied: bool = False,
    ) -> bool:
        """Set an alias record using CNAME."""
        return self.set_cname_record(name, content, ttl, proxied)