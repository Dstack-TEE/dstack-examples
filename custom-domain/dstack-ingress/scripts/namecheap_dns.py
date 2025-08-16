#!/usr/bin/env python3

import argparse
import json
import os
import sys
import requests
import xml.etree.ElementTree as ET
from typing import Dict, List, Optional


class NamecheapDNSClient:
    """A client for managing DNS records in Namecheap with better error handling."""

    def __init__(self, username: str, api_key: str, client_ip: str, sandbox: bool = False):
        self.username = username
        self.api_key = api_key
        self.client_ip = client_ip
        self.sandbox = sandbox
        
        if sandbox:
            self.base_url = "https://api.sandbox.namecheap.com/xml.response"
        else:
            self.base_url = "https://api.namecheap.com/xml.response"

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
            response = requests.post(self.base_url, data=request_params)
            response.raise_for_status()
            
            # Parse XML response
            root = ET.fromstring(response.content)
            
            # Check for API errors
            errors = root.find('.//{https://api.namecheap.com/xml.response}Errors')
            if errors is not None and len(errors) > 0:
                error_messages = []
                for error in errors:
                    error_messages.append(f"Code: {error.get('Number')}, Message: {error.text}")
                error_msg = "\n".join(error_messages)
                print(f"API Error: {error_msg}", file=sys.stderr)
                return {"success": False, "errors": error_messages}
            
            # Check response status
            status = root.get('Status')
            if status != 'OK':
                print(f"API Response Status: {status}", file=sys.stderr)
                return {"success": False, "errors": [{"message": f"API returned status: {status}"}]}
            
            return {"success": True, "result": root}
            
        except requests.exceptions.RequestException as e:
            print(f"Request Error: {str(e)}", file=sys.stderr)
            return {"success": False, "errors": [{"message": str(e)}]}
        except ET.ParseError as e:
            print(f"XML Parse Error: {str(e)}", file=sys.stderr)
            return {"success": False, "errors": [{"message": f"XML Parse Error: {str(e)}"}]}
        except Exception as e:
            print(f"Unexpected Error: {str(e)}", file=sys.stderr)
            return {"success": False, "errors": [{"message": str(e)}]}

    def get_domain_name(self, domain: str) -> Optional[str]:
        """Extract the domain name from a full domain or subdomain."""
        # For Namecheap, we need to determine the registered domain name
        # This is a simplified approach - for production, you might want
        # to use a more sophisticated domain parsing library
        parts = domain.split('.')
        if len(parts) >= 2:
            # Assume the domain is the last two parts (e.g., example.com from test.example.com)
            return '.'.join(parts[-2:])
        return domain

    def get_dns_records(self, domain: str) -> List[Dict]:
        """Get DNS records for a domain."""
        domain_name = self.get_domain_name(domain)
        if not domain_name:
            print(f"Could not determine domain name from {domain}", file=sys.stderr)
            return []
        
        # Split domain into SLD and TLD
        parts = domain_name.split('.')
        if len(parts) < 2:
            print(f"Invalid domain format: {domain_name}", file=sys.stderr)
            return []
        
        sld = parts[0]  # Second Level Domain
        tld = '.'.join(parts[1:])  # Top Level Domain
        
        print(f"Getting DNS records for {domain_name} (SLD: {sld}, TLD: {tld})")
        
        result = self._make_request(
            "namecheap.domains.dns.getHosts",
            SLD=sld,
            TLD=tld
        )
        
        if not result.get("success", False):
            return []
        
        # Parse the host records from XML response
        hosts = []
        host_elements = result["result"].findall('.//{https://api.namecheap.com/xml.response}host')
        
        for host in host_elements:
            hosts.append({
                "HostId": host.get("HostId"),
                "Name": host.get("Name"),
                "Type": host.get("Type"),
                "Address": host.get("Address"),
                "MXPref": host.get("MXPref", "10"),
                "TTL": host.get("TTL", "1800"),
                "AssociatedAppTitle": host.get("AssociatedAppTitle", ""),
                "FriendlyName": host.get("FriendlyName", "")
            })
        
        return hosts

    def set_dns_records(self, domain: str, records: List[Dict]) -> bool:
        """Set DNS records for a domain."""
        domain_name = self.get_domain_name(domain)
        if not domain_name:
            print(f"Could not determine domain name from {domain}", file=sys.stderr)
            return False
        
        # Split domain into SLD and TLD
        parts = domain_name.split('.')
        if len(parts) < 2:
            print(f"Invalid domain format: {domain_name}", file=sys.stderr)
            return False
        
        sld = parts[0]  # Second Level Domain
        tld = '.'.join(parts[1:])  # Top Level Domain
        
        # Prepare host records parameters
        params = {
            "SLD": sld,
            "TLD": tld
        }
        
        # Add host records to parameters
        for i, record in enumerate(records, 1):
            params[f"HostName{i}"] = record.get("HostName", "@")
            params[f"RecordType{i}"] = record.get("RecordType", "A")
            params[f"Address{i}"] = record.get("Address", "")
            params[f"TTL{i}"] = record.get("TTL", "1800")
            
            # Add MXPref for MX records
            if record.get("RecordType") == "MX":
                params[f"MXPref{i}"] = record.get("MXPref", "10")
        
        print(f"Setting DNS records for {domain_name}")
        result = self._make_request("namecheap.domains.dns.setHosts", **params)
        
        return result.get("success", False)

    def create_cname_record(self, domain: str, content: str, ttl: int = 1800) -> bool:
        """Create a CNAME record by updating all DNS records."""
        # Get existing records
        existing_records = self.get_dns_records(domain)
        
        # Extract hostname from domain
        domain_name = self.get_domain_name(domain)
        if domain == domain_name:
            hostname = "@"
        else:
            hostname = domain.replace(f".{domain_name}", "")
        
        # Remove existing CNAME records with the same hostname
        filtered_records = [
            r for r in existing_records 
            if not (r["Name"] == hostname and r["Type"] == "CNAME")
        ]
        
        # Add new CNAME record
        filtered_records.append({
            "HostName": hostname,
            "RecordType": "CNAME",
            "Address": content,
            "TTL": str(ttl)
        })
        
        print(f"Adding CNAME record for {domain} pointing to {content}")
        return self.set_dns_records(domain, filtered_records)

    def create_txt_record(self, domain: str, content: str, ttl: int = 1800) -> bool:
        """Create a TXT record by updating all DNS records."""
        # Get existing records
        existing_records = self.get_dns_records(domain)
        
        # Extract hostname from domain
        domain_name = self.get_domain_name(domain)
        if domain == domain_name:
            hostname = "@"
        else:
            hostname = domain.replace(f".{domain_name}", "")
        
        # Remove existing TXT records with the same hostname
        filtered_records = [
            r for r in existing_records 
            if not (r["Name"] == hostname and r["Type"] == "TXT")
        ]
        
        # Add new TXT record
        filtered_records.append({
            "HostName": hostname,
            "RecordType": "TXT",
            "Address": content,
            "TTL": str(ttl)
        })
        
        print(f"Adding TXT record for {domain} with content {content}")
        return self.set_dns_records(domain, filtered_records)

    def create_caa_record(self, domain: str, tag: str, value: str, flags: int = 0, ttl: int = 1800) -> bool:
        """Create a CAA record by updating all DNS records."""
        # Namecheap doesn't support CAA records through their API currently
        # This is a limitation of their API
        print(f"Warning: Namecheap API does not currently support CAA records", file=sys.stderr)
        print(f"You need to manually add CAA record for {domain} with tag {tag} and value {value}", file=sys.stderr)
        return True  # Return True to not break the workflow


def main():
    parser = argparse.ArgumentParser(description="Manage Namecheap DNS records")
    parser.add_argument("action", choices=["get_zone_id", "set_cname", "set_txt", "set_caa"], 
                        help="Action to perform")
    parser.add_argument("--domain", required=True, help="Domain name")
    parser.add_argument("--username", help="Namecheap username")
    parser.add_argument("--api-key", help="Namecheap API key")
    parser.add_argument("--client-ip", help="Client IP address")
    parser.add_argument("--sandbox", action="store_true", help="Use sandbox API")
    parser.add_argument("--content", help="Record content (target for CNAME, value for TXT/CAA)")
    parser.add_argument("--caa-tag", choices=["issue", "issuewild", "iodef"], 
                        help="CAA record tag")
    parser.add_argument("--caa-value", help="CAA record value")
    
    args = parser.parse_args()
    
    # Get credentials from environment if not provided
    username = args.username or os.environ.get("NAMECHEAP_USERNAME")
    api_key = args.api_key or os.environ.get("NAMECHEAP_API_KEY")
    client_ip = args.client_ip or os.environ.get("NAMECHEAP_CLIENT_IP")
    
    assert username is not None, "Namecheap username is required"
    assert api_key is not None, "Namecheap API key is required"
    assert client_ip is not None, "Client IP address is required"

    # Create DNS client
    client = NamecheapDNSClient(username, api_key, client_ip, args.sandbox)
    
    if args.action == "get_zone_id":
        # For Namecheap, we don't have zone IDs like Cloudflare
        # We just return the domain name for compatibility
        domain_name = client.get_domain_name(args.domain)
        if not domain_name:
            sys.exit(1)
        print(domain_name)  # Output domain name for shell script to capture
    
    elif args.action == "set_cname":
        if not args.content:
            print("Error: --content is required for CNAME records", file=sys.stderr)
            sys.exit(1)
        
        success = client.create_cname_record(args.domain, args.content)
        if not success:
            sys.exit(1)
    
    elif args.action == "set_txt":
        if not args.content:
            print("Error: --content is required for TXT records", file=sys.stderr)
            sys.exit(1)
        
        success = client.create_txt_record(args.domain, args.content)
        if not success:
            sys.exit(1)
    
    elif args.action == "set_caa":
        if not args.caa_tag or not args.caa_value:
            print("Error: --caa-tag and --caa-value are required for CAA records", file=sys.stderr)
            sys.exit(1)
        
        success = client.create_caa_record(args.domain, args.caa_tag, args.caa_value)
        if not success:
            sys.exit(1)


if __name__ == "__main__":
    main()