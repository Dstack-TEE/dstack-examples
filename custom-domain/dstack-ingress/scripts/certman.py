#!/usr/bin/env python3

from dns_providers import DNSProviderFactory
import argparse
import os
import re
import subprocess
import sys
import pkg_resources
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


# Time a certbot run needs on top of the DNS propagation wait: ACME round
# trips, plugin setup, the cleanup hook, and certbot's own bookkeeping.
CERTBOT_TIMEOUT_HEADROOM = 180

# Never allow less than the cap this replaced. route53 declares no propagation
# wait at all, so sizing purely from the wait would cut its budget from 300s to
# 180s and fail renewals that used to fit. The sizing exists to raise the cap
# where a provider needs more, not to lower it anywhere.
CERTBOT_TIMEOUT_FLOOR = 300


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

        # First ensure certbot is installed in the current environment
        self._ensure_certbot_in_env()

        # Check if plugin is already installed
        try:
            __import__(self.provider.CERTBOT_PLUGIN_MODULE)
            print(
                f"Plugin {self.provider.CERTBOT_PACKAGE} is already installed")
            return True
        except ImportError:
            pass  # Plugin not installed, continue with installation

        print(f"Installing certbot plugin: {self.provider.CERTBOT_PACKAGE}")

        # Try multiple installation methods
        install_methods = []

        # Method 1: Use the same python executable that's running this script
        install_methods.append(
            [sys.executable, "-m", "pip", "install", self.provider.CERTBOT_PACKAGE])

        # Method 2: Use virtual environment pip if available
        if "VIRTUAL_ENV" in os.environ:
            venv_pip = os.path.join(os.environ["VIRTUAL_ENV"], "bin", "pip")
            if os.path.exists(venv_pip):
                install_methods.append(
                    [venv_pip, "install", self.provider.CERTBOT_PACKAGE])

        # Method 3: Use system pip
        install_methods.append(
            ["pip", "install", self.provider.CERTBOT_PACKAGE])

        # Method 4: Use pip3
        install_methods.append(
            ["pip3", "install", self.provider.CERTBOT_PACKAGE])

        success = False
        for i, pip_cmd in enumerate(install_methods):
            print(f"Trying installation method {i+1}")
            print(f"Command: {' '.join(pip_cmd)}")
            try:
                result = subprocess.run(
                    pip_cmd, capture_output=True, text=True)
                if result.returncode == 0:
                    print(f"Installation method {i+1} succeeded")
                    success = True
                    break
                else:
                    print(f"Installation method {i+1} failed: {result.stderr}")
            except Exception as e:
                print(f"Installation method {i+1} exception: {e}")

        if not success:
            print(f"All installation methods failed", file=sys.stderr)
            return False

        print(f"Successfully installed {self.provider.CERTBOT_PACKAGE}")

        # Diagnostic information for troubleshooting
        try:
            print(f"Installed to Python: {sys.executable}")

            # Show certbot command
            certbot_cmd = self._get_certbot_command()
            print(f"Using certbot: {' '.join(certbot_cmd)}")

            try:
                dist = pkg_resources.get_distribution(
                    self.provider.CERTBOT_PACKAGE)
                print(f"Package version: {dist.version} at {dist.location}")
            except pkg_resources.DistributionNotFound:
                print("Warning: Package not found in current environment")
        except Exception as diag_error:
            print(f"Diagnostic error: {diag_error}")

        # Verify plugin installation
        try:
            __import__(self.provider.CERTBOT_PLUGIN_MODULE)
            print(
                f"Plugin {self.provider.CERTBOT_PLUGIN} successfully imported")

            # Test if plugin is recognized by certbot
            certbot_cmd = self._get_certbot_command()
            test_cmd = certbot_cmd + ["plugins"]
            test_result = subprocess.run(
                test_cmd, capture_output=True, text=True, timeout=10)

            if test_result.returncode == 0 and self.provider.CERTBOT_PLUGIN in test_result.stdout:
                print(
                    f"✓ Plugin {self.provider.CERTBOT_PLUGIN} is available in certbot")
                return True
            else:
                print(
                    f"Warning: {self.provider.CERTBOT_PLUGIN} plugin not found in certbot plugins list")
                if test_result.stderr:
                    print(f"Plugin test stderr: {test_result.stderr}")

                # Debug plugin registration
                self._debug_plugin_registration()

                # Try force reinstall to fix plugin registration
                print("Attempting to fix plugin registration...")
                try:
                    force_cmd = [sys.executable, "-m", "pip", "install", "--force-reinstall",
                                 "--no-deps", self.provider.CERTBOT_PACKAGE]
                    print(f"Running: {' '.join(force_cmd)}")
                    force_result = subprocess.run(
                        force_cmd, capture_output=True, text=True)

                    if force_result.returncode == 0:
                        # Test again after reinstall
                        retest_cmd = certbot_cmd + ["plugins"]
                        retest_result = subprocess.run(
                            retest_cmd, capture_output=True, text=True, timeout=10)
                        if retest_result.returncode == 0 and self.provider.CERTBOT_PLUGIN in retest_result.stdout:
                            print(f"✓ Plugin registration fixed after reinstall")
                            return True
                        else:
                            print(f"Plugin still not registered, may work anyway")
                    else:
                        print(f"Force reinstall failed: {force_result.stderr}")
                except Exception as fix_error:
                    print(f"Plugin fix attempt failed: {fix_error}")

                # Continue anyway - may work in Docker environments
                return True

        except Exception as e:
            print(f"Plugin verification warning: {e}")
            return True

    def _ensure_certbot_in_env(self) -> None:
        """Ensure certbot is installed in the current Python environment."""

        # Try to import certbot to check if it's installed
        try:
            import certbot
            print(f"✓ Certbot module available in current environment")
            return
        except ImportError:
            print(f"Certbot module not found, installing...")

        # Install certbot if not available
        try:
            install_cmd = [sys.executable, "-m", "pip", "install", "certbot"]
            print(f"Running: {' '.join(install_cmd)}")
            result = subprocess.run(
                install_cmd, capture_output=True, text=True)

            if result.returncode == 0:
                print(f"✓ Certbot installed successfully in current environment")
            else:
                print(f"Failed to install certbot: {result.stderr}")
                # Continue anyway - may still work
        except Exception as e:
            print(f"Error installing certbot: {e}")
            # Continue anyway - may still work

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
            import pkg_resources
            print("=== Plugin Registration Debug ===")

            # Show which certbot we're using
            certbot_cmd = self._get_certbot_command()
            print(f"Using certbot: {' '.join(certbot_cmd)}")

            # Check entry points
            try:
                entry_points = list(
                    pkg_resources.iter_entry_points('certbot.plugins'))
                print(f"Found {len(entry_points)} certbot plugins:")
                for ep in entry_points:
                    print(f"  - {ep.name}: {ep.module_name}")

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
            if action == "renew":
                base_cmd.extend(["--cert-name", self._lineage_name(domain)])
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
        if action == "renew":
            # Without this, `certbot renew` renews *every* lineage in
            # /etc/letsencrypt/renewal. run_pass calls this once per domain, so
            # N domains meant N passes over all N lineages, and the result was
            # then reported against whichever domain happened to ask.
            base_cmd.extend(["--cert-name", self._lineage_name(domain)])
        if staging_enabled():
            base_cmd.extend(["--staging"])

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
        timeout = self._certbot_timeout()

        try:
            result = subprocess.run(
                cmd, capture_output=True, text=True, timeout=timeout)

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
            print(f"Certbot command timed out after {timeout} seconds",
                  file=sys.stderr)
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
        timeout = self._certbot_timeout()

        try:
            result = subprocess.run(
                cmd, capture_output=True, text=True, timeout=timeout)

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

        except subprocess.TimeoutExpired:
            print(
                f"Certbot renew for {domain} timed out after {timeout} seconds. "
                f"If this provider needs a longer DNS propagation wait, raise "
                f"CERTBOT_TIMEOUT.",
                file=sys.stderr,
            )
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

    def _renewal_conf_path(self, domain: str) -> str:
        """Where certbot keeps this lineage's renewal config."""
        return f"/etc/letsencrypt/renewal/{self._lineage_name(domain)}.conf"

    def _certbot_timeout(self) -> int:
        """How long one certbot run may take.

        The dominant term is the DNS propagation wait, which the plugin -- or,
        under delegation, the auth hook -- sleeps through inside the process.
        A single fixed cap cannot fit every provider: linode's own default
        propagation is 300s, so a 300s cap could never be met and dns-01 on
        linode timed out every time, on issuance as well as renewal.

        Size the cap from the wait instead, and let a deployment override it.
        Never below CERTBOT_TIMEOUT_FLOOR: a provider that declares no
        propagation wait (route53) still spends time on ACME round trips, and
        this change should not shorten anyone's budget. An explicit
        CERTBOT_TIMEOUT is taken literally -- that one is the operator's call.
        """
        override = os.environ.get("CERTBOT_TIMEOUT", "").strip()
        if override.isdigit() and int(override) > 0:
            return int(override)

        if os.environ.get("DELEGATION_ZONE", "").strip():
            # Kept in step with acme-dns-alias-hook.sh, which does the sleeping.
            wait = os.environ.get("DELEGATION_PROPAGATION_SECONDS", "").strip()
            propagation = int(wait) if wait.isdigit() else 120
        else:
            propagation = getattr(
                self.provider, "CERTBOT_PROPAGATION_SECONDS", None) or 0

        return max(CERTBOT_TIMEOUT_FLOOR, propagation + CERTBOT_TIMEOUT_HEADROOM)

    def apply_renewal_window(self, domain: str) -> None:
        """Make RENEW_DAYS_BEFORE mean the same thing here as it does for lego.

        lego takes the renewal window as a flag (`--renew-days`). certbot has no
        equivalent: it reads `renew_before_expiry` out of the lineage's renewal
        config, so the setting has to be written there before `certbot renew`
        runs. Without this the variable is silently tls-alpn-01 only, which also
        left the dns-01 renewal branch with no way to be exercised on demand.

        Unsetting it has to remove the setting again, not merely stop writing
        it: the lineage config lives in the certificate volume and outlives the
        container, so a value written once would otherwise be permanent, and
        the documented way to leave the renewal window -- unset the variable --
        would do nothing while the certificate stayed permanently due.

        This assumes the container owns the lineage config: clearing removes
        any active renew_before_expiry, including one a human put there, since
        nothing distinguishes the two. That holds for the volume this image
        manages. Mounting a certbot directory maintained elsewhere is out of
        scope -- set RENEW_DAYS_BEFORE to the value you want in that case,
        rather than leaving it unset and expecting the file to be left alone.
        """
        days = os.environ.get("RENEW_DAYS_BEFORE", "").strip()
        if days and (not days.isdigit() or int(days) < 1):
            print(
                f"Warning: ignoring invalid RENEW_DAYS_BEFORE={days!r} "
                f"(expected a positive number of days)",
                file=sys.stderr,
            )
            return

        path = self._renewal_conf_path(domain)
        if not os.path.isfile(path):
            # No lineage yet: the first issuance has not happened, and certbot
            # writes this file itself. Nothing to do.
            return

        setting = f"renew_before_expiry = {days} days" if days else None
        try:
            with open(path, encoding="utf-8") as fh:
                lines = fh.read().splitlines()
        except OSError as exc:
            print(f"Warning: cannot read {path}: {exc}", file=sys.stderr)
            return

        out, replaced, removed = [], False, False
        for line in lines:
            # The key ships commented out, so match both forms when writing.
            # When clearing, drop only the active setting: the commented
            # template is certbot's own and carries no value.
            active = re.match(r"\s*renew_before_expiry\s*=", line)
            if setting is not None and re.match(
                r"\s*#?\s*renew_before_expiry\s*=", line
            ):
                if not replaced:
                    out.append(setting)
                    replaced = True
                continue
            if setting is None and active:
                removed = True
                continue
            out.append(line)

        if setting is not None and not replaced:
            # Must land before the first section header; the key is top-level.
            insert_at = next(
                (i for i, line in enumerate(out) if line.strip().startswith("[")),
                len(out),
            )
            out.insert(insert_at, setting)
            replaced = True

        if out == lines:
            # Nothing to do: already correct, or already absent. Rewriting the
            # file every pass would only add noise and a chance to corrupt it.
            return

        # Write through a temporary file and rename over the original. Opening
        # the live config with "w" truncates it before anything is written, so
        # a crash or a full disk mid-write would leave certbot with a truncated
        # lineage config -- and a lineage certbot cannot parse is one it cannot
        # renew. os.replace is atomic, so a reader sees the old file or the new
        # one, never a half-written one.
        tmp = f"{path}.dstack-tmp"
        try:
            with open(tmp, "w", encoding="utf-8") as fh:
                fh.write("\n".join(out) + "\n")
                fh.flush()
                os.fsync(fh.fileno())
            os.replace(tmp, path)
        except OSError as exc:
            print(f"Warning: cannot write {path}: {exc}", file=sys.stderr)
            try:
                os.unlink(tmp)
            except OSError:
                pass
            return

        if removed:
            print(
                f"Renewal window for {domain} cleared; "
                f"certbot's default applies again"
            )
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
