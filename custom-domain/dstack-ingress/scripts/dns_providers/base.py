#!/usr/bin/env python3

import os

from abc import ABC, abstractmethod
from typing import Dict, List, Optional, Any
from dataclasses import dataclass
from enum import Enum

# Seconds to wait on a DNS provider API before giving up, so a stalled
# connection fails the call instead of hanging the renewal loop.
HTTP_TIMEOUT = 30


def write_secret_file(path: str, content: str) -> None:
    """Write `path` readable by the owner only, never exposing it wider."""
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        os.fchmod(fd, 0o600)
        f.write(content)


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
            List of DNS records; empty only if there are none

        Raises:
            RuntimeError: if the zone or its records could not be looked up.
            Callers decide what to delete or keep from this list, so a failed
            read must not pass for an empty one.
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

    def clear_conflicting_alias(self, name: str, keep: "RecordType") -> None:
        """Remove address/alias records at `name` other than `keep`.

        DNS forbids a CNAME beside anything else, and the set_* helpers only
        look at the type they are about to write, so a name that already holds
        the other form blocks the write. That happens whenever the form changes
        -- a provider gaining an override, or a deployment moving between
        providers -- and the failure looks like a permissions problem rather
        than a leftover record.
        """
        for record_type in (RecordType.CNAME, RecordType.A, RecordType.AAAA):
            if record_type == keep:
                continue
            for record in self.get_dns_records(name, record_type):
                if record.id:
                    self.delete_dns_record(record.id, name)

    def set_alias_record(
        self,
        name: str,
        content: str,
        ttl: int = 60,
        proxied: bool = False,
    ) -> bool:
        """Point `name` at `content`, in whatever form this provider allows.

        A CNAME by default. Providers override this where a CNAME will not do
        -- Linode publishes an address record instead, because it refuses a CAA
        beside a CNAME, and delegation needs both on one name.

        Callers should not second-guess the form: which one works is a property
        of the provider, and this is where that knowledge lives.
        """
        self.clear_conflicting_alias(name, RecordType.CNAME)
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

    def unset_records(self, name: str, record_type: RecordType) -> bool:
        """Delete every record of one type at a name.

        Used to clean up an ACME challenge, and to clear a record type before
        publishing a different one at the same name -- the set_* helpers only
        look at the type they are about to write, so a leftover CNAME would
        otherwise block an A record and vice versa.

        Args:
            name: The record name
            record_type: Which type to remove

        Returns:
            True if all matching records were removed (or none existed).
        """
        ok = True
        for record in self.get_dns_records(name, record_type):
            if not record.id:
                print(f"Warning: {record_type.value} record for {name} has no id; cannot delete")
                ok = False
                continue
            if not self.delete_dns_record(record.id, name):
                ok = False
        return ok

    def unset_txt_record(self, name: str) -> bool:
        """Delete all TXT records for a name."""
        return self.unset_records(name, RecordType.TXT)

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
