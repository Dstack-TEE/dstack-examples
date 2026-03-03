#!/usr/bin/env python3

import os

from abc import ABC, abstractmethod
from typing import Dict, List, Optional, Any
from dataclasses import dataclass
from enum import Enum


class RecordType(Enum):
    A = "A"
    AAAA = "AAAA"
    CNAME = "CNAME"
    TXT = "TXT"
    MX = "MX"
    NS = "NS"
    CAA = "CAA"
    SRV = "SRV"
    PTR = "PTR"


@dataclass
class DNSRecord:
    """Represents a DNS record."""

    id: Optional[str]
    name: str
    type: RecordType
    content: str
    ttl: int = 60
    proxied: bool = False
    priority: Optional[int] = None
    data: Optional[Dict[str, Any]] = None


@dataclass
class CAARecord:
    """Represents a CAA record with specific fields."""

    name: str
    flags: int
    tag: str
    value: str
    ttl: int = 60


class DNSProvider(ABC):
    """Abstract base class for DNS providers."""

    DETECT_ENV = ""

    # Certbot configuration - override in subclasses
    CERTBOT_PLUGIN = ""
    CERTBOT_PLUGIN_MODULE = ""
    CERTBOT_PACKAGE = ""
    CERTBOT_PROPAGATION_SECONDS = 120
    CERTBOT_CREDENTIALS_FILE = ""  # Path to credentials file

    def __init__(self):
        """Initialize the DNS provider."""
        pass

    def setup_certbot_credentials(self) -> bool:
        """Setup credentials file for certbot. Override in subclasses if needed."""
        return True  # Default: no setup needed

    def validate_credentials(self) -> bool:
        """Validate provider credentials. Override in subclasses if needed."""
        return True  # Default: no validation needed

    @classmethod
    def suitable(cls) -> bool:
        """Check if the current environment is suitable for this DNS provider."""
        return os.environ.get(cls.DETECT_ENV) is not None

    @abstractmethod
    def get_dns_records(
        self, name: str, record_type: Optional[RecordType] = None
    ) -> List[DNSRecord]:
        """Get DNS records for a domain.

        Args:
            name: The record name
            record_type: Optional record type filter

        Returns:
            List of DNS records
        """
        pass

    @abstractmethod
    def create_dns_record(self, record: DNSRecord) -> bool:
        """Create a DNS record.

        Args:
            record: The DNS record to create

        Returns:
            True if successful, False otherwise
        """
        pass

    @abstractmethod
    def delete_dns_record(self, record_id: str, domain: str) -> bool:
        """Delete a DNS record.

        Args:
            record_id: The record ID to delete
            domain: The domain name (for zone lookup)

        Returns:
            True if successful, False otherwise
        """
        pass

    @abstractmethod
    def create_caa_record(self, caa_record: CAARecord) -> bool:
        """Create a CAA record.

        Args:
            caa_record: The CAA record to create

        Returns:
            True if successful, False otherwise
        """
        pass

    def set_a_record(
        self, name: str, ip_address: str, ttl: int = 60, proxied: bool = False
    ) -> bool:
        """Set an A record (delete existing and create new).

        Args:
            name: The record name
            ip_address: The IP address
            ttl: Time to live
            proxied: Whether to proxy through provider (if supported)

        Returns:
            True if successful, False otherwise
        """
        existing_records = self.get_dns_records(name, RecordType.A)
        for record in existing_records:
            # Check if record already exists with same IP
            if record.content == ip_address:
                print("A record with the same IP already exists")
                return True
            if record.id:
                self.delete_dns_record(record.id, name)

        new_record = DNSRecord(
            id=None,
            name=name,
            type=RecordType.A,
            content=ip_address,
            ttl=ttl,
            proxied=proxied,
        )
        return self.create_dns_record(new_record)

    def set_alias_record(
        self,
        name: str,
        content: str,
        ttl: int = 60,
        proxied: bool = False,
    ) -> bool:
        """Set an alias record (delete existing and create new).

        Creates a CNAME record by default. Some providers may override this
        to use A records instead (e.g., Linode to avoid CAA conflicts).

        Args:
            name: The record name
            content: The alias target (domain name)
            ttl: Time to live
            proxied: Whether to proxy through provider (if supported)

        Returns:
            True if successful, False otherwise
        """
        return self.set_cname_record(name, content, ttl, proxied)

    def set_cname_record(
        self,
        name: str,
        content: str,
        ttl: int = 60,
        proxied: bool = False,
    ) -> bool:
        """Set an alias record (delete existing and create new).

        Creates a CNAME record by default. Some providers may override this
        to use A records instead (e.g., Linode to avoid CAA conflicts).

        Args:
            name: The record name
            content: The alias target (domain name)
            ttl: Time to live
            proxied: Whether to proxy through provider (if supported)

        Returns:
            True if successful, False otherwise
        """
        existing_records = self.get_dns_records(name, RecordType.CNAME)
        for record in existing_records:
            # Check if record already exists with same content
            if record.content == content:
                print("CNAME record with the same content already exists")
                return True
            if record.id:
                self.delete_dns_record(record.id, name)

        new_record = DNSRecord(
            id=None,
            name=name,
            type=RecordType.CNAME,
            content=content,
            ttl=ttl,
            proxied=proxied,
        )
        return self.create_dns_record(new_record)

    def set_txt_record(self, name: str, content: str, ttl: int = 60) -> bool:
        """Set a TXT record (delete existing and create new).

        Args:
            name: The record name
            content: The TXT content
            ttl: Time to live

        Returns:
            True if successful, False otherwise
        """
        existing_records = self.get_dns_records(name, RecordType.TXT)
        for record in existing_records:
            # Check if record already exists with same content
            if record.content == content or record.content == f'"{content}"':
                print("TXT record with the same content already exists")
                return True
            if record.id:
                self.delete_dns_record(record.id, name)

        new_record = DNSRecord(
            id=None, name=name, type=RecordType.TXT, content=content, ttl=ttl
        )
        return self.create_dns_record(new_record)

    def set_weighted_cname_record(
        self,
        name: str,
        content: str,
        weight: int,
        set_identifier: str,
        ttl: int = 60,
    ) -> bool:
        """Set a weighted CNAME record.

        Default implementation ignores weight/set_identifier and creates a plain
        CNAME. Providers that support weighted routing (e.g. Route53) should
        override this method.

        Args:
            name: The record name (ALIAS_DOMAIN)
            content: The CNAME target (primary DOMAIN)
            weight: Routing weight (0 = registered but receives no traffic)
            set_identifier: Unique identifier for this node in the weighted pool
            ttl: Time to live

        Returns:
            True if successful, False otherwise
        """
        print(
            f"Note: provider does not support weighted CNAMEs; "
            f"creating plain CNAME for {name}"
        )
        return self.set_cname_record(name, content, ttl)

    def set_caa_record(
        self,
        name: str,
        tag: str,
        value: str,
        flags: int = 0,
        ttl: int = 60,
    ) -> bool:
        """Set a CAA record (delete existing with same tag and create new).

        Args:
            name: The record name
            tag: The CAA tag (issue, issuewild, iodef)
            value: The CAA value
            flags: The CAA flags
            ttl: Time to live

        Returns:
            True if successful, False otherwise
        """
        existing_records = self.get_dns_records(name, RecordType.CAA)
        for record in existing_records:
            if record.data and record.data.get("tag") == tag:
                if record.data.get("value") == value:
                    print("CAA record with the same content already exists")
                    return True
                if record.id:
                    self.delete_dns_record(record.id, name)

        caa_record = CAARecord(name=name, flags=flags, tag=tag, value=value, ttl=ttl)
        return self.create_caa_record(caa_record)
