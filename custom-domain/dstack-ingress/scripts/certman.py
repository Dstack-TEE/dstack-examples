#!/usr/bin/env python3

from dns_providers import DNSProviderFactory
import argparse
import os
import subprocess
import sys
from typing import List, Optional, Tuple

# Add script directory to path to import dns_providers
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))


class CertManager:
    """Certificate management using DNS provider infrastructure."""

    def __init__(self, provider_type: Optional[str] = None):
        """Initialize cert manager with DNS provider."""
        # Use the same DNS provider factory
        self.provider_type = provider_type or self._detect_provider_type()
        self.provider = DNSProviderFactory.create_provider(self.provider_type)

    def _detect_provider_type(self) -> str:
        """Detect provider type (reuse factory logic)."""
        return DNSProviderFactory._detect_provider_type()

    def install_plugin(self) -> bool:
        """Install certbot plugin for the current provider."""
        if not self.provider.CERTBOT_PACKAGE:
            print(f"No certbot package defined for {self.provider_type}")
            return False

        print(f"Installing certbot plugin: {self.provider.CERTBOT_PACKAGE}")

        # Use virtual environment pip if available
        pip_cmd = ["pip", "install", self.provider.CERTBOT_PACKAGE]
        if "VIRTUAL_ENV" in os.environ:
            venv_pip = os.path.join(os.environ["VIRTUAL_ENV"], "bin", "pip")
            if os.path.exists(venv_pip):
                pip_cmd[0] = venv_pip

        try:
            result = subprocess.run(pip_cmd, capture_output=True, text=True)
            if result.returncode != 0:
                print(f"Failed to install plugin: {result.stderr}", file=sys.stderr)
                return False
            print(f"Successfully installed {self.provider.CERTBOT_PACKAGE}")
            return True
        except Exception as e:
            print(f"Error installing plugin: {e}", file=sys.stderr)
            return False

    def setup_credentials(self) -> bool:
        """Setup credentials file for certbot using provider implementation."""
        return self.provider.setup_certbot_credentials()

    def _build_certbot_command(self, action: str, domain: str, email: str) -> List[str]:
        """Build certbot command using provider configuration."""
        plugin = self.provider.CERTBOT_PLUGIN
        if not plugin:
            raise ValueError(f"No certbot plugin configured for {self.provider_type}")

        propagation_seconds = self.provider.CERTBOT_PROPAGATION_SECONDS

        base_cmd = ["certbot", action]

        # Add DNS plugin configuration
        base_cmd.extend(
            [
                f"--{plugin}",
                f"--{plugin}-propagation-seconds",
                str(propagation_seconds),
                "--non-interactive",
            ]
        )

        # Add credentials file if provider has one configured
        if self.provider.CERTBOT_CREDENTIALS_FILE:
            credentials_file = os.path.expanduser(
                self.provider.CERTBOT_CREDENTIALS_FILE
            )
            if os.path.exists(credentials_file):
                base_cmd.extend([f"--{plugin}-credentials", credentials_file])

        if action == "certonly":
            base_cmd.extend(
                ["--email", email, "--agree-tos", "--no-eff-email", "-d", domain]
            )

        return base_cmd

    def obtain_certificate(self, domain: str, email: str) -> bool:
        """Obtain a new certificate for the domain."""
        print(f"Obtaining new certificate for {domain} using {self.provider_type}")

        cmd = self._build_certbot_command("certonly", domain, email)

        try:
            result = subprocess.run(cmd, capture_output=True, text=True)
            if result.returncode != 0:
                print(f"Certificate obtaining failed: {result.stderr}", file=sys.stderr)
                return False

            print(f"Certificate obtained successfully for {domain}")
            return True

        except Exception as e:
            print(f"Error running certbot: {e}", file=sys.stderr)
            return False

    def renew_certificate(self, domain: str) -> Tuple[bool, bool]:
        """Renew certificates.

        Returns:
            (success, renewed): success status and whether renewal was actually performed
        """
        print(f"Renewing certificate using {self.provider_type}")

        cmd = self._build_certbot_command("renew", domain, "")

        try:
            result = subprocess.run(cmd, capture_output=True, text=True)
            if result.returncode != 0:
                print(f"Certificate renewal failed: {result.stderr}", file=sys.stderr)
                return False, False

            # Check if no renewals were needed
            if "No renewals were attempted" in result.stdout:
                print("No certificates need renewal")
                return True, False

            print("Certificate renewed successfully")
            return True, True

        except Exception as e:
            print(f"Error running certbot: {e}", file=sys.stderr)
            return False, False

    def certificate_exists(self, domain: str) -> bool:
        """Check if certificate already exists for domain."""
        cert_path = f"/etc/letsencrypt/live/{domain}/fullchain.pem"
        return os.path.isfile(cert_path)

    def run_action(
        self, domain: str, email: str, action: str = "auto"
    ) -> Tuple[bool, bool]:
        """High-level certificate management.

        Returns:
            (success, needs_evidence): success status and whether evidence should be generated
        """
        if action == "auto":
            if self.certificate_exists(domain):
                success, renewed = self.renew_certificate(domain)
                return success, renewed  # Only generate evidence if actually renewed
            else:
                success = self.obtain_certificate(domain, email)
                return success, success  # Always generate evidence for new certificates
        elif action == "obtain":
            success = self.obtain_certificate(domain, email)
            return success, success
        elif action == "renew":
            success, renewed = self.renew_certificate(domain)
            return success, renewed
        else:
            raise ValueError(f"Invalid action: {action}")


def main():
    parser = argparse.ArgumentParser(
        description="Manage SSL certificates with certbot using DNS providers"
    )
    parser.add_argument(
        "action", choices=["obtain", "renew", "auto", "setup"], help="Action to perform"
    )
    parser.add_argument("--domain", help="Domain name")
    parser.add_argument("--email", help="Email for Let's Encrypt registration")
    parser.add_argument("--provider", help="DNS provider (cloudflare, linode, etc)")

    args = parser.parse_args()

    try:
        manager = CertManager(args.provider)

        # Handle setup action
        if args.action == "setup":
            if not manager.install_plugin():
                sys.exit(1)
            if not manager.setup_credentials():
                sys.exit(1)
            print(f"Setup completed for {manager.provider_type} provider")
            return

        # Domain is required for certificate operations
        if not args.domain:
            print(
                "Error: --domain is required for certificate operations",
                file=sys.stderr,
            )
            sys.exit(1)

        # Email is required for obtain and auto actions
        if args.action in ["obtain", "auto"] and not args.email:
            if not os.environ.get("CERTBOT_EMAIL"):
                print(
                    "Error: --email is required or set CERTBOT_EMAIL environment variable",
                    file=sys.stderr,
                )
                sys.exit(1)
            args.email = os.environ["CERTBOT_EMAIL"]

        success, needs_evidence = manager.run_action(
            args.domain, args.email, args.action
        )

        if not success:
            sys.exit(1)

        # Exit with code 2 if no evidence generation is needed (no renewal was performed)
        if not needs_evidence:
            sys.exit(2)

    except ValueError as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)
    except Exception as e:
        print(f"Unexpected error: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
