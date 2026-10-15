#!/usr/bin/env python3

import os
import socket
import sys

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

    def _prune_records(
        self, name: str, records: List[DNSRecord], wanted, strict: bool = True
    ) -> Optional[bool]:
        """Delete every record that is not wanted.

        Returns whether a wanted record is present, or None if a stale one
        could not be deleted -- reporting success then would leave it in place
        for good, since the next run finds the wanted record and stops there.
        Without `strict`, a failed delete is only a warning.
        """
        found = False
        ok = True
        for record in records:
            if wanted(record):
                found = True
            elif not record.id or not self.delete_dns_record(record.id, name):
                print(
                    f"{'Error' if strict else 'Warning'}: could not delete stale "
                    f"{record.type.value} record for {name}: {record.content}",
                    file=sys.stderr,
                )
                ok = ok and not strict
        return found if ok else None

    def set_a_record(
        self, name: str, ip_address: str, ttl: int = 60, proxied: bool = False
    ) -> bool:
        """Set an A record (create new, then delete the others).

        Args:
            name: The record name
            ip_address: The IP address
            ttl: Time to live
            proxied: Whether to proxy through provider (if supported)

        Returns:
            True if successful, False otherwise
        """
        new_record = DNSRecord(
            id=None,
            name=name,
            type=RecordType.A,
            content=ip_address,
            ttl=ttl,
            proxied=proxied,
        )
        return self._replace_records(
            new_record, lambda r: r.content == ip_address, "same IP"
        )

    def _replace_records(
        self, new_record: DNSRecord, wanted, what: str, strict: bool = True
    ) -> bool:
        """Make `new_record` the only value of its type at its name.

        Stale values go only once the new one is in place: a failed create
        must not leave the name without an answer.
        """
        name, record_type = new_record.name, new_record.type
        records = self.get_dns_records(name, record_type)
        if any(wanted(r) for r in records):
            print(f"{record_type.value} record with the {what} already exists")
        elif not self.create_dns_record(new_record):
            return False
        else:
            # Some providers replace the whole set on create; list it again
            # so the record just written is not mistaken for a stale one.
            records = self.get_dns_records(name, record_type)
        return self._prune_records(name, records, wanted, strict) is not None

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

    # Whether a CAA beside a CNAME at one name takes effect. By the DNS rules
    # a CNAME owns its name, so resolvers follow it and never see the CAA,
    # and Route53 and Linode refuse the pair. Providers whose servers answer a
    # CAA query with the CAA beside the CNAME set this.
    CAA_BESIDE_CNAME = False

    def set_alias_record(
        self,
        name: str,
        content: str,
        ttl: int = 60,
        proxied: bool = False,
        with_caa: bool = False,
    ) -> bool:
        """Point `name` at `content`, in whatever form this provider allows.

        A CNAME follows the gateway wherever it moves, so it is the default.
        Where a CAA shares the name (`with_caa`, or one is already there) and
        the provider cannot serve it beside a CNAME, an address record instead.
        """
        if not self.CAA_BESIDE_CNAME and (with_caa or self._holds_caa(name)):
            return self.set_address_record(name, content, ttl)
        self.clear_conflicting_alias(name, RecordType.CNAME)
        return self.set_cname_record(name, content, ttl, proxied)

    def _holds_caa(self, name: str) -> bool:
        """Whether `name` has a CAA record, which a CNAME would hide.

        One left over from SET_CAA or delegation, or the operator's own: either
        way it cannot be told apart from a wanted one, so keep it meaningful.
        """
        wanted = name.rstrip(".").lower()
        if not any(
            r.name.rstrip(".").lower() == wanted
            for r in self.get_dns_records(name, RecordType.CAA)
        ):
            return False
        print(
            f"{name} has a CAA record, which a CNAME would hide: publishing "
            f"an A record instead. Delete the CAA record to go back to a CNAME."
        )
        return True

    def set_address_record(self, name: str, content: str, ttl: int = 60) -> bool:
        """Point `name` at the address `content` resolves to now.

        For a name that also carries a CAA record, on a provider without
        CAA_BESIDE_CNAME. The cost is that the address is pinned until the
        next run, and only one of the gateway's addresses is published.
        """
        ip_address = socket.gethostbyname(content)
        print(f"Creating A record for {name} pointing to {ip_address} ({content})")
        self.clear_conflicting_alias(name, RecordType.A)
        return self.set_a_record(name, ip_address, ttl)

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
        found = self._prune_records(
            name, existing_records, lambda r: r.content == content
        )
        if found is None:
            return False
        if found:
            print("CNAME record with the same content already exists")
            return True

        new_record = DNSRecord(
            id=None,
            name=name,
            type=RecordType.CNAME,
            content=content,
            ttl=ttl,
            proxied=proxied,
        )
        return self.create_dns_record(new_record)

    def set_txt_record(
        self, name: str, content: str, ttl: int = 60, tolerate_stale: bool = False
    ) -> bool:
        """Set a TXT record (create new, then delete the others).

        Args:
            name: The record name
            content: The TXT content
            ttl: Time to live
            tolerate_stale: Succeed even if other values could not be deleted

        Returns:
            True if successful, False otherwise
        """
        new_record = DNSRecord(
            id=None, name=name, type=RecordType.TXT, content=content, ttl=ttl
        )
        return self._replace_records(
            new_record,
            lambda r: r.content in (content, f'"{content}"'),
            "same content",
            strict=not tolerate_stale,
        )

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
        """Set a CAA record (create new, then delete others with the same tag).

        Args:
            name: The record name
            tag: The CAA tag (issue, issuewild, iodef)
            value: The CAA value
            flags: The CAA flags
            ttl: Time to live

        Returns:
            True if successful, False otherwise
        """
        same_tag = [
            r
            for r in self.get_dns_records(name, RecordType.CAA)
            if r.data and r.data.get("tag") == tag
        ]
        if any(r.data.get("value") == value for r in same_tag):
            print("CAA record with the same content already exists")
        elif not self.create_caa_record(
            CAARecord(name=name, flags=flags, tag=tag, value=value, ttl=ttl)
        ):
            return False
        # Stale values go only once the new one is in place: a failed create
        # must not leave the name without a CAA record.
        found = self._prune_records(
            name, same_tag, lambda r: r.data.get("value") == value
        )
        return found is not None
