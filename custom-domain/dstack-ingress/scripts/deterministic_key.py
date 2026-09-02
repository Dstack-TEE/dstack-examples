#!/usr/bin/env python3
"""Derive a deterministic P-256 TLS key from the dstack v0 GetKey API."""
import hashlib, json, os, sys, urllib.parse, urllib.request
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography import x509
from cryptography.x509.oid import NameOID
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

def derive_private_key(key: bytes, domain: str) -> ec.EllipticCurvePrivateKey:
    material = HKDF(algorithm=hashes.SHA256(), length=48,
                    salt=b"dstack-ingress/tls-p256/v1",
                    info=domain.encode()).derive(key)
    order = 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551
    n = int.from_bytes(material, "big") % order or 1
    return ec.derive_private_key(n, ec.SECP256R1())

def main(domain: str, key_path: str, csr_path: str) -> None:
    q = urllib.parse.urlencode({"path": f"tls/{domain}", "purpose": "tls", "algorithm": "secp256k1"})
    sock = "/var/run/dstack.sock"
    req = urllib.request.Request(f"http://localhost/GetKey?{q}")
    req.add_header("Host", "localhost")
    # urllib does not support unix sockets; use curl, which is measured in the image.
    import subprocess
    raw = subprocess.check_output(["curl", "--fail", "--silent", "--unix-socket", sock, req.full_url])
    key = bytes.fromhex(json.loads(raw)["key"])
    private = derive_private_key(key, domain)
    os.makedirs(os.path.dirname(key_path), exist_ok=True)
    os.makedirs(os.path.dirname(csr_path), exist_ok=True)
    for path, data in ((key_path, private.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.TraditionalOpenSSL, serialization.NoEncryption())),
                       (csr_path, x509.CertificateSigningRequestBuilder().subject_name(x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, domain)])).sign(private, hashes.SHA256()).public_bytes(serialization.Encoding.PEM))):
        with open(path, "wb") as f: f.write(data)
        os.chmod(path, 0o600)
if __name__ == "__main__": main(sys.argv[1], sys.argv[2], sys.argv[3])
