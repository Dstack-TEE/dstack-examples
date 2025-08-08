#!/usr/bin/env python3

import os
from typing import Optional
from .base import DNSProvider
from .cloudflare import CloudflareDNSProvider
from .linode import LinodeDNSProvider


class DNSProviderFactory:
    """Factory class for creating DNS provider instances."""

    PROVIDERS = {
        "cloudflare": CloudflareDNSProvider,
        "linode": LinodeDNSProvider,
    }

    @classmethod
    def create_provider(
        cls,
        provider_type: Optional[str] = None,
    ) -> DNSProvider:
        """Create a DNS provider instance.

        Args:
            provider_type: Type of DNS provider
                          If not specified, will be detected from environment variables

        Returns:
            DNSProvider instance

        Raises:
            ValueError: If provider type is invalid
        """
        # Auto-detect provider type from environment if not specified
        if not provider_type:
            provider_type = cls._detect_provider_type()

        provider_type = provider_type.lower()

        if provider_type not in cls.PROVIDERS:
            raise ValueError(
                f"Unsupported DNS provider: {provider_type}. Supported providers: {', '.join(cls.PROVIDERS.keys())}"
            )

        # Lazy import the provider class
        provider_class = cls.PROVIDERS[provider_type]
        return provider_class()

    @classmethod
    def _detect_provider_type(cls) -> str:
        """Detect DNS provider type from environment variables."""
        if os.environ.get("DNS_PROVIDER"):
            return os.environ["DNS_PROVIDER"]

        for name, provider in cls.PROVIDERS.items():
            if provider.suitable():
                return name

        raise ValueError(
            "Could not detect DNS provider type from environment variables. "
            "Please set DNS_PROVIDER environment variable."
        )

    @classmethod
    def get_supported_providers(cls) -> list:
        """Get list of supported DNS providers."""
        return list(cls.PROVIDERS.keys())
