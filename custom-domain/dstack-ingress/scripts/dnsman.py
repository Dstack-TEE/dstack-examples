#!/usr/bin/env python3

from dns_providers import DNSProviderFactory
import argparse
import os
import sys

sys.path.append(os.path.dirname(os.path.abspath(__file__)))


def main():
    parser = argparse.ArgumentParser(
        description="Manage DNS records across multiple providers"
    )
    parser.add_argument(
        "action",
        choices=["set_cname", "set_alias", "set_txt", "set_txt_append", "set_caa", "set_weighted_cname"],
        help="Action to perform",
    )
    parser.add_argument("--domain", required=True, help="Domain name")
    parser.add_argument("--provider", help="DNS provider (cloudflare, linode)")
    # Zone ID is now handled internally by each provider
    parser.add_argument(
        "--content", help="Record content (target for alias/CNAME, value for TXT/CAA)"
    )
    parser.add_argument(
        "--caa-tag", choices=["issue", "issuewild", "iodef"], help="CAA record tag"
    )
    parser.add_argument("--caa-value", help="CAA record value")
    parser.add_argument(
        "--weight", type=int, help="Routing weight for weighted CNAME records"
    )
    parser.add_argument(
        "--set-identifier",
        help="Unique identifier for this record in a weighted record set",
    )

    args = parser.parse_args()

    try:
        # Create DNS provider instance
        provider = DNSProviderFactory.create_provider(args.provider)

        if args.action == "set_cname":
            if not args.content:
                print("Error: --content is required for CNAME records", file=sys.stderr)
                sys.exit(1)

            success = provider.set_alias_record(args.domain, args.content)
            if not success:
                print(f"Failed to set alias record for {args.domain}", file=sys.stderr)
                sys.exit(1)
            print(f"Successfully set alias record for {args.domain}")

        elif args.action == "set_alias":
            if not args.content:
                print("Error: --content is required for alias records", file=sys.stderr)
                sys.exit(1)

            success = provider.set_alias_record(args.domain, args.content)
            if not success:
                print(f"Failed to set alias record for {args.domain}", file=sys.stderr)
                sys.exit(1)
            print(f"Successfully set alias record for {args.domain}")

        elif args.action == "set_txt":
            if not args.content:
                print("Error: --content is required for TXT records", file=sys.stderr)
                sys.exit(1)

            success = provider.set_txt_record(args.domain, args.content)
            if not success:
                print(f"Failed to set TXT record for {args.domain}", file=sys.stderr)
                sys.exit(1)
            print(f"Successfully set TXT record for {args.domain}")

        elif args.action == "set_txt_append":
            if not args.content:
                print("Error: --content is required for TXT records", file=sys.stderr)
                sys.exit(1)

            success = provider.append_txt_record(args.domain, args.content)
            if not success:
                print(f"Failed to append TXT record for {args.domain}", file=sys.stderr)
                sys.exit(1)
            print(f"Successfully appended TXT record for {args.domain}")

        elif args.action == "set_weighted_cname":
            if not args.content:
                print(
                    "Error: --content is required for weighted CNAME records",
                    file=sys.stderr,
                )
                sys.exit(1)
            if args.weight is None:
                print(
                    "Error: --weight is required for weighted CNAME records",
                    file=sys.stderr,
                )
                sys.exit(1)
            set_identifier = args.set_identifier or args.domain
            success = provider.set_weighted_cname_record(
                args.domain, args.content, args.weight, set_identifier
            )
            if not success:
                print(
                    f"Failed to set weighted CNAME record for {args.domain}",
                    file=sys.stderr,
                )
                sys.exit(1)
            print(f"Successfully set weighted CNAME record for {args.domain}")

        elif args.action == "set_caa":
            if not args.caa_tag or not args.caa_value:
                print(
                    "Error: --caa-tag and --caa-value are required for CAA records",
                    file=sys.stderr,
                )
                sys.exit(1)

            success = provider.set_caa_record(args.domain, args.caa_tag, args.caa_value)
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
