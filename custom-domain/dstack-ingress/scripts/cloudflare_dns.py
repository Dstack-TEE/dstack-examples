#!/usr/bin/env python3

import argparse
import json
import os
import sys
import requests
from typing import Dict, List, Optional


class CloudflareDNSClient:
    """A client for managing DNS records in Cloudflare with better error handling."""

    def __init__(self, api_token: str, zone_id: Optional[str] = None):
        self.api_token = api_token
        self.zone_id = zone_id
        self.base_url = "https://api.cloudflare.com/client/v4"
        self.headers = {
            "Authorization": f"Bearer {api_token}",
            "Content-Type": "application/json"
        }

    def _make_request(self, method: str, endpoint: str, data: Optional[Dict] = None) -> Dict:
        """Make a request to the Cloudflare API with error handling."""
        url = f"{self.base_url}/{endpoint}"
        try:
            if method.upper() == "GET":
                response = requests.get(url, headers=self.headers)
            elif method.upper() == "POST":
                response = requests.post(url, headers=self.headers, json=data)
            elif method.upper() == "DELETE":
                response = requests.delete(url, headers=self.headers)
            else:
                raise ValueError(f"Unsupported HTTP method: {method}")

            response.raise_for_status()
            result = response.json()

            if not result.get("success", False):
                errors = result.get("errors", [])
                error_msg = "\n".join([f"Code: {e.get('code')}, Message: {e.get('message')}" for e in errors])
                print(f"API Error: {error_msg}", file=sys.stderr)
                # Print the request data for debugging
                if data:
                    print(f"Request data: {json.dumps(data)}", file=sys.stderr)
                return {"success": False, "errors": errors}

            return result
        except requests.exceptions.RequestException as e:
            print(f"Request Error: {str(e)}", file=sys.stderr)
            # Print the request data for debugging
            if data:
                print(f"Request data: {json.dumps(data)}", file=sys.stderr)
            return {"success": False, "errors": [{"message": str(e)}]}
        except json.JSONDecodeError:
            print(f"JSON Decode Error: Could not parse response", file=sys.stderr)
            return {"success": False, "errors": [{"message": "Could not parse response"}]}
        except Exception as e:
            print(f"Unexpected Error: {str(e)}", file=sys.stderr)
            return {"success": False, "errors": [{"message": str(e)}]}

    def get_zone_id(self, domain: str) -> Optional[str]:
        """Get the zone ID for a domain."""
        # Extract the root domain (e.g., example.com from sub.example.com)
        parts = domain.split('.')
        if len(parts) > 2:
            root_domain = '.'.join(parts[-2:])
        else:
            root_domain = domain

        print(f"Fetching zone ID for domain: {root_domain}")
        result = self._make_request("GET", f"zones?name={root_domain}")

        if not result.get("success", False):
            return None

        zones = result.get("result", [])
        if not zones:
            print(f"No zones found for domain: {root_domain}", file=sys.stderr)
            return None

        zone_id = zones[0].get("id")
        if zone_id:
            print(f"Successfully retrieved zone ID: {zone_id} for domain {root_domain}")
            # Store the zone ID separately from any print output
            self.zone_id = zone_id
            return zone_id
        else:
            print(f"Zone ID not found in response for domain: {root_domain}", file=sys.stderr)
            return None

    def get_dns_records(self, name: str, record_type: Optional[str] = None) -> List[Dict]:
        """Get DNS records for a domain."""
        if not self.zone_id:
            print("Zone ID is required", file=sys.stderr)
            return []

        params = f"zones/{self.zone_id}/dns_records?name={name}"
        if record_type:
            params += f"&type={record_type}"

        print(f"Checking for existing DNS records for {name}")
        result = self._make_request("GET", params)

        if not result.get("success", False):
            return []

        records = result.get("result", [])
        return records

    def delete_dns_record(self, record_id: str) -> bool:
        """Delete a DNS record."""
        if not self.zone_id:
            print("Zone ID is required", file=sys.stderr)
            return False

        print(f"Deleting record ID: {record_id}")
        result = self._make_request("DELETE", f"zones/{self.zone_id}/dns_records/{record_id}")

        return result.get("success", False)

    def create_cname_record(self, name: str, content: str, ttl: int = 60, proxied: bool = False) -> bool:
        """Create a CNAME record."""
        if not self.zone_id:
            print("Zone ID is required", file=sys.stderr)
            return False

        data = {
            "type": "CNAME",
            "name": name,
            "content": content,
            "ttl": ttl,
            "proxied": proxied
        }

        print(f"Adding CNAME record for {name} pointing to {content}")
        result = self._make_request("POST", f"zones/{self.zone_id}/dns_records", data)

        return result.get("success", False)

    def create_txt_record(self, name: str, content: str, ttl: int = 60) -> bool:
        """Create a TXT record."""
        if not self.zone_id:
            print("Zone ID is required", file=sys.stderr)
            return False

        data = {
            "type": "TXT",
            "name": name,
            "content": f'"{content}"',
            "ttl": ttl
        }

        print(f"Adding TXT record for {name} with content {content}")
        result = self._make_request("POST", f"zones/{self.zone_id}/dns_records", data)

        return result.get("success", False)

    def create_caa_record(self, name: str, tag: str, value: str, flags: int = 0, ttl: int = 60) -> bool:
        """Create a CAA record."""
        if not self.zone_id:
            print("Zone ID is required", file=sys.stderr)
            return False

        # Clean up the value - remove any existing quotes that might cause issues
        clean_value = value.strip('"')
        
        # Cloudflare API expects a different structure for CAA records
        # The data field should contain flags, tag, and value separately
        data = {
            "type": "CAA",
            "name": name,
            "ttl": ttl,
            "data": {
                "flags": flags,
                "tag": tag,
                "value": clean_value
            }
        }

        print(f"Adding CAA record for {name} with tag {tag} and value {clean_value}")
        result = self._make_request("POST", f"zones/{self.zone_id}/dns_records", data)

        return result.get("success", False)


def main():
    parser = argparse.ArgumentParser(description="Manage Cloudflare DNS records")
    parser.add_argument("action", choices=["get_zone_id", "set_cname", "set_txt", "set_caa"], 
                        help="Action to perform")
    parser.add_argument("--domain", required=True, help="Domain name")
    parser.add_argument("--api-token", help="Cloudflare API token")
    parser.add_argument("--zone-id", help="Cloudflare Zone ID")
    parser.add_argument("--content", help="Record content (target for CNAME, value for TXT/CAA)")
    parser.add_argument("--caa-tag", choices=["issue", "issuewild", "iodef"], 
                        help="CAA record tag")
    parser.add_argument("--caa-value", help="CAA record value")
    
    args = parser.parse_args()
    
    # Get API token from environment if not provided
    api_token = args.api_token or os.environ.get("CLOUDFLARE_API_TOKEN")
    if not api_token:
        print("Error: Cloudflare API token is required", file=sys.stderr)
        sys.exit(1)
    
    # Create DNS client
    client = CloudflareDNSClient(api_token, args.zone_id)
    
    if args.action == "get_zone_id":
        zone_id = client.get_zone_id(args.domain)
        if not zone_id:
            sys.exit(1)
        print(zone_id)  # Output zone ID for shell script to capture
    
    elif args.action == "set_cname":
        if not args.content:
            print("Error: --content is required for CNAME records", file=sys.stderr)
            sys.exit(1)
        
        # Get zone ID if not provided
        if not client.zone_id:
            zone_id = client.get_zone_id(args.domain)
            if not zone_id:
                sys.exit(1)
            # Make sure to use the zone_id from the client object, not the printed output
            client.zone_id = zone_id
        
        # Check for existing records and delete them
        existing_records = client.get_dns_records(args.domain, "CNAME")
        for record in existing_records:
            client.delete_dns_record(record["id"])
        
        # Create new CNAME record
        success = client.create_cname_record(args.domain, args.content)
        if not success:
            sys.exit(1)
    
    elif args.action == "set_txt":
        # Get zone ID if not provided
        if not client.zone_id:
            zone_id = client.get_zone_id(args.domain)
            if not zone_id:
                sys.exit(1)
            # Make sure to use the zone_id from the client object, not the printed output
            client.zone_id = zone_id
        
        # Check for existing records and delete them
        existing_records = client.get_dns_records(args.domain, "TXT")
        for record in existing_records:
            client.delete_dns_record(record["id"])
        
        # Create new TXT record
        success = client.create_txt_record(args.domain, args.content)
        if not success:
            sys.exit(1)
    
    elif args.action == "set_caa":
        if not args.caa_tag or not args.caa_value:
            print("Error: --caa-tag and --caa-value are required for CAA records", file=sys.stderr)
            sys.exit(1)
        
        # Get zone ID if not provided
        if not client.zone_id:
            zone_id = client.get_zone_id(args.domain)
            if not zone_id:
                sys.exit(1)
            # Make sure to use the zone_id from the client object, not the printed output
            client.zone_id = zone_id
        
        # Check for existing records
        existing_records = client.get_dns_records(args.domain, "CAA")
        for record in existing_records:
            # With the new API format, we need to check the data structure
            record_data = record.get("data", {})
            record_tag = record_data.get("tag", "")
            record_value = record_data.get("value", "")
            
            # If we find a record with the same tag and value, no need to update
            if record_tag == args.caa_tag and record_value == args.caa_value:
                print(f"CAA record with the same content already exists")
                return
            
            # If it's the same tag but different value, delete it
            if record_tag == args.caa_tag:
                client.delete_dns_record(record["id"])
        
        # Create new CAA record
        success = client.create_caa_record(args.domain, args.caa_tag, args.caa_value)
        if not success:
            print(f"Failed to create CAA record for {args.domain}")
            sys.exit(1)


if __name__ == "__main__":
    main()
