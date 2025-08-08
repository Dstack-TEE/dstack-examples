#!/usr/bin/env python3

import argparse
import os
import sys

sys.path.append(os.path.dirname(os.path.abspath(__file__)))

from dns_providers import DNSProviderFactory


def main():
    parser = argparse.ArgumentParser(
        description="Manage DNS records across multiple providers"
    )
    parser.add_argument(
        "action",
        choices=["get_zone_id", "set_cname", "set_alias", "set_txt", "set_caa"],
        help="Action to perform",
    )
    parser.add_argument("--domain", required=True, help="Domain name")
    parser.add_argument("--provider", help="DNS provider (cloudflare, linode)")
    parser.add_argument("--zone-id", help="Zone ID (if already known)")
    parser.add_argument(
        "--content", help="Record content (target for alias/CNAME, value for TXT/CAA)"
    )
    parser.add_argument(
        "--caa-tag", choices=["issue", "issuewild", "iodef"], help="CAA record tag"
    )
    parser.add_argument("--caa-value", help="CAA record value")

    args = parser.parse_args()

    try:
        # Create DNS provider instance
        provider = DNSProviderFactory.create_provider(args.provider)

        # Get zone ID if not provided
        zone_id = args.zone_id
        if not zone_id:
            zone_id = provider.get_zone_id(args.domain)
            if not zone_id:
                print(
                    f"Error: Could not find zone for domain {args.domain}",
                    file=sys.stderr,
                )
                sys.exit(1)

        if args.action == "get_zone_id":
            print(zone_id)  # Output zone ID for shell script to capture

        elif args.action == "set_cname":
            # Legacy action - redirects to set_alias for backward compatibility
            if not args.content:
                print("Error: --content is required for CNAME records", file=sys.stderr)
                sys.exit(1)

            success = provider.set_alias_record(zone_id, args.domain, args.content)
            if not success:
                print(f"Failed to set alias record for {args.domain}", file=sys.stderr)
                sys.exit(1)
            print(f"Successfully set alias record for {args.domain}")

        elif args.action == "set_alias":
            if not args.content:
                print("Error: --content is required for alias records", file=sys.stderr)
                sys.exit(1)

            success = provider.set_alias_record(zone_id, args.domain, args.content)
            if not success:
                print(f"Failed to set alias record for {args.domain}", file=sys.stderr)
                sys.exit(1)
            print(f"Successfully set alias record for {args.domain}")

        elif args.action == "set_txt":
            if not args.content:
                print("Error: --content is required for TXT records", file=sys.stderr)
                sys.exit(1)

            success = provider.set_txt_record(zone_id, args.domain, args.content)
            if not success:
                print(f"Failed to set TXT record for {args.domain}", file=sys.stderr)
                sys.exit(1)
            print(f"Successfully set TXT record for {args.domain}")

        elif args.action == "set_caa":
            if not args.caa_tag or not args.caa_value:
                print(
                    "Error: --caa-tag and --caa-value are required for CAA records",
                    file=sys.stderr,
                )
                sys.exit(1)

            success = provider.set_caa_record(
                zone_id, args.domain, args.caa_tag, args.caa_value
            )
            if not success:
                print(f"Failed to set CAA record for {args.domain}", file=sys.stderr)
                sys.exit(1)
            print(f"Successfully set CAA record for {args.domain}")

    except ValueError as e:
        print(f"Error: {str(e)}", file=sys.stderr)
        sys.exit(1)
    except Exception as e:
        print(f"Unexpected error: {str(e)}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
