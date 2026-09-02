#!/usr/bin/env python3

from dns_providers import DNSProviderFactory
import argparse
import os
import re
import subprocess
import sys
from importlib import metadata
from typing import List, Optional, Tuple

# Add script directory to path to import dns_providers
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))


def staging_enabled() -> bool:
    """Whether to use Let's Encrypt staging.

    entrypoint.sh normalises the two names, but certman.py is also runnable on
    its own, so accept both here as well. ACME_STAGING wins: the setting is
    about the ACME server, not about certbot.
    """
    value = os.environ.get("ACME_STAGING") or os.environ.get("CERTBOT_STAGING", "false")
    return value == "true"


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

    @staticmethod
    def _cert_name(domain: str) -> str:
        """Match certbot's stable lineage name for a domain."""
        return domain.lstrip("*.").replace("*", "wildcard-")

    def install_plugin(self) -> bool:
        """Install certbot plugin for the current provider."""
        if not self.provider.CERTBOT_PACKAGE:
            print(f"No certbot package defined for {self.provider_type}")
            return False

        try:
            self._ensure_certbot_in_env()
            __import__(self.provider.CERTBOT_PLUGIN_MODULE)
            print(f"Plugin {self.provider.CERTBOT_PACKAGE} is available")
            return True
        except (ImportError, RuntimeError) as exc:
            print(f"Required certbot dependency is missing from the measured image: {exc}", file=sys.stderr)
            return False

    def _ensure_certbot_in_env(self) -> None:
        """Ensure certbot is installed in the current Python environment."""

        # Try to import certbot to check if it's installed
        try:
            import certbot
            print(f"✓ Certbot module available in current environment")
            return
        except ImportError as exc:
            raise RuntimeError("certbot is missing from the measured image") from exc

    def _get_certbot_command(self) -> List[str]:
        """Get the correct certbot command that uses the same Python environment."""

        # Always use certbot from the same Python environment
        python_dir = os.path.dirname(sys.executable)
        venv_certbot = os.path.join(python_dir, "certbot")

        if os.path.exists(venv_certbot):
            cmd = [venv_certbot]
            print(f"Using certbot from virtual environment: {venv_certbot}")
            return cmd

        # If certbot doesn't exist in venv, this is an error condition
        raise RuntimeError(
            f"Certbot not found in virtual environment: {venv_certbot}. "
            f"This indicates the environment setup failed. "
            f"Python executable: {sys.executable}"
        )

    def _debug_plugin_registration(self) -> None:
        """Debug why plugin is not being registered by certbot."""
        try:
            print("=== Plugin Registration Debug ===")

            # Show which certbot we're using
            certbot_cmd = self._get_certbot_command()
            print(f"Using certbot: {' '.join(certbot_cmd)}")

            # Check entry points
            try:
                entry_points = list(metadata.entry_points(group='certbot.plugins'))
                print(f"Found {len(entry_points)} certbot plugins:")
                for ep in entry_points:
                    print(f"  - {ep.name}: {ep.value}")

                # Look specifically for our plugin
                plugin_eps = [ep for ep in entry_points if ep.name ==
                              self.provider.CERTBOT_PLUGIN]
                if plugin_eps:
                    print(
                        f"✓ Found {self.provider.CERTBOT_PLUGIN} entry point: {plugin_eps[0]}")
                else:
                    print(
                        f"✗ {self.provider.CERTBOT_PLUGIN} entry point not found")
            except Exception as ep_error:
                print(f"Entry point check failed: {ep_error}")

            # Check if certbot can import the plugin module
            try:
                imported_module = __import__(
                    self.provider.CERTBOT_PLUGIN_MODULE)
                print(f"✓ Plugin module can be imported")

                # Check if it has the right class
                if hasattr(imported_module, 'Authenticator'):
                    print(f"✓ Authenticator class found")
                else:
                    print(f"✗ Authenticator class not found")
            except Exception as import_error:
                print(f"✗ Plugin module import failed: {import_error}")

            print("=== End Debug ===")
        except Exception as debug_error:
            print(f"Debug failed: {debug_error}")

    def setup_credentials(self) -> bool:
        """Setup credentials file for certbot using provider implementation."""
        result = self.provider.setup_certbot_credentials()
        if not result:
            print(f"Failed to setup credentials file for {self.provider_type}")
        return result

    def _build_certbot_command(self, action: str, domain: str, email: str) -> List[str]:
        """Build certbot command using provider configuration."""
        certbot_cmd = self._get_certbot_command()
        deterministic = os.environ.get("DETERMINISTIC_TLS_KEY", "false").lower() == "true"
        if deterministic and action == "certonly":
            key_path = f"/etc/letsencrypt/live/{self._cert_name(domain)}/privkey.pem"
            csr_path = f"/etc/letsencrypt/csr/{self._cert_name(domain)}.csr"
            subprocess.run(["python3", "/scripts/deterministic_key.py", domain, key_path, csr_path], check=True)

        # Challenge-delegation mode: when DELEGATION_ZONE is set, answer the
        # DNS-01 challenge in a delegated zone via a manual hook instead of the
        # provider's certbot plugin, so our DNS token never needs access to the
        # served domain's own zone. See scripts/acme-dns-alias-hook.sh.
        if os.environ.get("DELEGATION_ZONE", "").strip():
            hook = "/scripts/acme-dns-alias-hook.sh"
            base_cmd = certbot_cmd + [action, "--non-interactive", "-v"]
            if action == "certonly":
                base_cmd.extend([
                    "--manual",
                    "--preferred-challenges=dns",
                    f"--manual-auth-hook={hook} auth",
                    f"--manual-cleanup-hook={hook} cleanup",
                    "--agree-tos", "--no-eff-email",
                ])
                # Same optional-contact handling as the plugin path below.
                if email:
                    base_cmd.extend(["--email", email])
                else:
                    base_cmd.append("--register-unsafely-without-email")
                base_cmd.extend(["-d", domain])
            # For `renew`, certbot reuses the authenticator + hooks saved in the
            # renewal config from the initial `certonly`, so we don't re-specify
            # them here (and must not fall back to the DNS plugin).
            if staging_enabled():
                base_cmd.append("--staging")
            masked = [a if not (i > 0 and base_cmd[i - 1] == "--email") else "<email>"
                      for i, a in enumerate(base_cmd)]
            print(f"Executing (challenge-delegation): {' '.join(masked)}")
            return base_cmd

        plugin = self.provider.CERTBOT_PLUGIN
        if not plugin:
            raise ValueError(
                f"No certbot plugin configured for {self.provider_type}")

        # Use Python module execution to ensure same environment
        base_cmd = certbot_cmd + [action, "-a",
                                  plugin, "--non-interactive", "-v"]

        # Add credentials file if configured
        if self.provider.CERTBOT_CREDENTIALS_FILE:
            credentials_file = os.path.expanduser(
                self.provider.CERTBOT_CREDENTIALS_FILE)
            if os.path.exists(credentials_file):
                base_cmd.extend([f"--{plugin}-credentials={credentials_file}"])
            else:
                raise ValueError(
                    f"Credentials file does not exist: {credentials_file}")

        if action == "certonly":
            if deterministic:
                base_cmd.extend(["--csr", csr_path, "--cert-path", f"/etc/letsencrypt/live/{self._cert_name(domain)}/cert.pem", "--fullchain-path", f"/etc/letsencrypt/live/{self._cert_name(domain)}/fullchain.pem", "--chain-path", f"/etc/letsencrypt/live/{self._cert_name(domain)}/chain.pem"])
            base_cmd.extend(["--agree-tos", "--no-eff-email"])
            # The ACME contact address is optional (RFC 8555 section 7.3), and
            # it is published: the account document is served as attestation
            # evidence, so an address set here is readable by anyone who
            # fetches it. certbot will not simply omit the flag, so ask for a
            # contactless account explicitly. Its "unsafely" naming predates
            # Let's Encrypt dropping expiry notification mail in 2025.
            if email:
                base_cmd.extend(["--email", email])
            else:
                base_cmd.append("--register-unsafely-without-email")
            base_cmd.extend(["-d", domain])
        if staging_enabled():
            base_cmd.extend(["--staging"])
        # Allow local ACME test servers (for example Pebble) without changing
        # the production/staging defaults.
        acme_server = os.environ.get("ACME_DIRECTORY_URL", "").strip()
        if acme_server:
            base_cmd.extend(["--server", acme_server])

        if getattr(self.provider, 'CERTBOT_PROPAGATION_SECONDS'):
            propagation_seconds = self.provider.CERTBOT_PROPAGATION_SECONDS
            propagation_param = f"--dns-{self.provider_type}-propagation-seconds={propagation_seconds}"
            base_cmd.extend([propagation_param])

        # Log command with masked email for debugging
        masked_cmd = [arg if not (i > 0 and base_cmd[i-1] == "--email") else "<email>"
                      for i, arg in enumerate(base_cmd)]
        print(f"Executing: {' '.join(masked_cmd)}")

        return base_cmd

    def obtain_certificate(self, domain: str, email: str) -> bool:
        """Obtain a new certificate for the domain."""
        print(f"Obtaining certificate for {domain} using {self.provider_type}")

        # Ensure plugin is installed
        if not self.install_plugin():
            print(
                f"Failed to install plugin for {self.provider_type}", file=sys.stderr)
            return False

        # Validate credentials before proceeding
        if not self.provider.validate_credentials():
            print(
                f"Failed to validate credentials for {self.provider_type}", file=sys.stderr)
            return False

        # Setup credentials file
        if not self.setup_credentials():
            print(
                f"Failed to setup credentials for {self.provider_type}", file=sys.stderr)
            return False

        cmd = self._build_certbot_command("certonly", domain, email)

        try:
            result = subprocess.run(
                cmd, capture_output=True, text=True, timeout=300)

            if result.returncode == 0:
                print(f"✓ Certificate obtained successfully for {domain}")
                return True
            else:
                print(
                    f"✗ Certificate obtaining failed (exit code: {result.returncode})")

                # Check for specific error patterns
                error_output = result.stderr.strip() if result.stderr else ""
                stdout_output = result.stdout.strip() if result.stdout else ""

                if "unrecognized arguments" in error_output:
                    print(f"Plugin arguments not recognized by certbot")
                    print(f"This suggests the plugin is not properly registered")
                elif "DNS problem" in error_output or "DNS problem" in stdout_output:
                    print(f"DNS validation failed - check domain configuration")
                elif "Rate limited" in error_output or "Rate limited" in stdout_output:
                    print(f"Rate limited by Let's Encrypt")

                if error_output:
                    print(f"stderr: {error_output}")
                if stdout_output:
                    print(f"stdout: {stdout_output}")

                return False

        except subprocess.TimeoutExpired:
            print(f"Certbot command timed out after 300 seconds", file=sys.stderr)
            return False
        except Exception as e:
            print(f"Error running certbot: {e}", file=sys.stderr)
            return False

    def renew_certificate(self, domain: str) -> Tuple[bool, bool]:
        """Renew certificates.

        Returns:
            (success, renewed): success status and whether renewal was actually performed
        """
        print(f"Renewing certificate using {self.provider_type}")

        # Ensure plugin is installed
        if not self.install_plugin():
            print(f"Failed to install plugin for renewal", file=sys.stderr)
            return False, False

        self.apply_renewal_window(domain)
        cmd = self._build_certbot_command("renew", domain, "")

        try:
            result = subprocess.run(
                cmd, capture_output=True, text=True, timeout=300)

            stdout_output = result.stdout.strip() if result.stdout else ""
            error_output = result.stderr.strip() if result.stderr else ""

            if result.returncode == 0:
                # Check if certbot actually renewed anything
                if "No renewals were attempted" in stdout_output:
                    print("No certificates need renewal")
                    return True, False
                print(f"✓ Certificate renewal completed")
                return True, True
            else:
                print(
                    f"✗ Certificate renewal failed (exit code: {result.returncode})")

                # Check for specific error patterns
                if "unrecognized arguments" in error_output:
                    print(f"Plugin arguments not recognized by certbot")
                elif "No renewals were attempted" in stdout_output:
                    print(f"No certificates need renewal")
                    return True, False  # Success but no renewal needed
                elif "DNS problem" in error_output or "DNS problem" in stdout_output:
                    print(f"DNS validation failed during renewal")

                if error_output:
                    print(f"stderr: {error_output}")
                if stdout_output:
                    print(f"stdout: {stdout_output}")

                return False, False

        except Exception as e:
            print(f"Error running certbot: {e}", file=sys.stderr)
            return False, False

    def certificate_exists(self, domain: str) -> bool:
        """Check if certificate already exists for domain."""
        cert_path = f"/etc/letsencrypt/live/{domain}/fullchain.pem"
        return os.path.isfile(cert_path)

    @staticmethod
    def _lineage_name(domain: str) -> str:
        """certbot stores a wildcard lineage under the bare name."""
        return domain[2:] if domain.startswith("*.") else domain

    def apply_renewal_window(self, domain: str) -> None:
        """Make RENEW_DAYS_BEFORE mean the same thing here as it does for lego.

        lego takes the renewal window as a flag (`--renew-days`). certbot has no
        equivalent: it reads `renew_before_expiry` out of the lineage's renewal
        config, so the setting has to be written there before `certbot renew`
        runs. Without this the variable is silently tls-alpn-01 only, which also
        left the dns-01 renewal branch with no way to be exercised on demand.

        Leaving it unset keeps certbot's own default (30 days).
        """
        days = os.environ.get("RENEW_DAYS_BEFORE", "").strip()
        if not days:
            return
        if not days.isdigit() or int(days) < 1:
            print(
                f"Warning: ignoring invalid RENEW_DAYS_BEFORE={days!r} "
                f"(expected a positive number of days)",
                file=sys.stderr,
            )
            return

        path = f"/etc/letsencrypt/renewal/{self._lineage_name(domain)}.conf"
        if not os.path.isfile(path):
            # No lineage yet: the first issuance has not happened, and certbot
            # writes this file itself. Nothing to do.
            return

        setting = f"renew_before_expiry = {days} days"
        try:
            with open(path, encoding="utf-8") as fh:
                lines = fh.read().splitlines()
        except OSError as exc:
            print(f"Warning: cannot read {path}: {exc}", file=sys.stderr)
            return

        out, replaced = [], False
        for line in lines:
            # The key ships commented out, so match both forms.
            if re.match(r"\s*#?\s*renew_before_expiry\s*=", line):
                if not replaced:
                    out.append(setting)
                    replaced = True
                continue
            out.append(line)

        if not replaced:
            # Must land before the first section header; the key is top-level.
            insert_at = next(
                (i for i, line in enumerate(out) if line.strip().startswith("[")),
                len(out),
            )
            out.insert(insert_at, setting)

        try:
            with open(path, "w", encoding="utf-8") as fh:
                fh.write("\n".join(out) + "\n")
        except OSError as exc:
            print(f"Warning: cannot write {path}: {exc}", file=sys.stderr)
            return
        print(f"Renewal window for {domain} set to {days} days before expiry")

    def acme_account_exists(self) -> bool:
        """Check if an ACME account exists for the current server (staging or production).

        The account directory differs between staging and production:
        - production: /etc/letsencrypt/accounts/acme-v02.api.letsencrypt.org/directory/
        - staging:    /etc/letsencrypt/accounts/acme-staging-v02.api.letsencrypt.org/directory/

        When switching between staging and production, the cert file persists
        on the volume but the account only exists for the previous server.
        """
        import glob
        api_endpoint = "acme-v02.api.letsencrypt.org"
        if staging_enabled():
            api_endpoint = "acme-staging-v02.api.letsencrypt.org"
        pattern = f"/etc/letsencrypt/accounts/{api_endpoint}/directory/*/regr.json"
        return len(glob.glob(pattern)) > 0

    def run_action(
        self, domain: str, email: str, action: str = "auto"
    ) -> Tuple[bool, bool]:
        """High-level certificate management.

        Returns:
            (success, needs_evidence): success status and whether evidence should be generated
        """
        if action == "auto":
            if self.certificate_exists(domain) and self.acme_account_exists():
                success, renewed = self.renew_certificate(domain)
                return success, renewed  # Only generate evidence if actually renewed
            else:
                if self.certificate_exists(domain) and not self.acme_account_exists():
                    print(f"Certificate exists for {domain} but ACME account is missing "
                          f"(staging/production switch?), re-obtaining")
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
    parser.add_argument(
        "--provider", help="DNS provider (cloudflare, linode, etc)")

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

        # The contact address is optional; see _build_certbot_command.
        if not args.email:
            args.email = os.environ.get("ACME_EMAIL") or os.environ.get(
                "CERTBOT_EMAIL", ""
            )

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
