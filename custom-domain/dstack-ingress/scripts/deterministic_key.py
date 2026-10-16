"""Deterministic per-domain TLS keys derived from the dstack GetKey API.

The key depends only on the app's KMS-derived key and the domain, so every
instance and every restart of the app serves the same public key.
"""
import json
import os
import subprocess
import tempfile
import urllib.parse

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.kdf.hkdf import HKDF
from cryptography.x509.oid import NameOID

DSTACK_SOCKET = "/var/run/dstack.sock"
P256_ORDER = 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551


def enabled() -> bool:
    return os.environ.get("DETERMINISTIC_TLS_KEY") == "true"


def derive_private_key(key: bytes, domain: str) -> ec.EllipticCurvePrivateKey:
    material = HKDF(algorithm=hashes.SHA256(), length=48,
                    salt=b"dstack-ingress/tls-p256/v1",
                    info=domain.encode()).derive(key)
    return ec.derive_private_key(int.from_bytes(material, "big") % P256_ORDER or 1, ec.SECP256R1())


def private_key(domain: str) -> ec.EllipticCurvePrivateKey:
    query = urllib.parse.urlencode({"path": f"tls/{domain}", "purpose": "tls", "algorithm": "secp256k1"})
    raw = subprocess.check_output(["curl", "--fail", "--silent", "--show-error",
                                   "--unix-socket", DSTACK_SOCKET, f"http://localhost/GetKey?{query}"])
    return derive_private_key(bytes.fromhex(json.loads(raw)["key"]), domain)


def key_pem(key: ec.EllipticCurvePrivateKey) -> bytes:
    return key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                             serialization.NoEncryption())


def csr_pem(key: ec.EllipticCurvePrivateKey, domain: str) -> bytes:
    return (x509.CertificateSigningRequestBuilder()
            .subject_name(x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, domain)]))
            .add_extension(x509.SubjectAlternativeName([x509.DNSName(domain)]), critical=False)
            .sign(key, hashes.SHA256())
            .public_bytes(serialization.Encoding.PEM))


def write_file(path: str, data: bytes) -> None:
    """Atomically replace path with data, readable by root only."""
    directory = os.path.dirname(path)
    os.makedirs(directory, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=directory)
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
        os.replace(tmp, path)
    except BaseException:
        os.unlink(tmp)
        raise


def cert_matches(cert_path: str, key: ec.EllipticCurvePrivateKey) -> bool:
    """Whether the leaf certificate at cert_path carries key's public key."""
    try:
        with open(cert_path, "rb") as f:
            cert = x509.load_pem_x509_certificate(f.read())
    except (OSError, ValueError):
        return False
    spki = (serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo)
    return cert.public_key().public_bytes(*spki) == key.public_key().public_bytes(*spki)
