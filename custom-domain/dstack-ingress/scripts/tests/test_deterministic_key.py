import importlib.util
from pathlib import Path

path = Path(__file__).parents[1] / "deterministic_key.py"
spec = importlib.util.spec_from_file_location("deterministic_key", path)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

def test_derivation_is_stable_and_domain_separated():
    key = bytes(range(32))
    a = mod.derive_private_key(key, "a.example")
    b = mod.derive_private_key(key, "a.example")
    c = mod.derive_private_key(key, "b.example")
    assert a.private_numbers().private_value == b.private_numbers().private_value
    assert a.public_key().public_numbers() != c.public_key().public_numbers()
    assert a.curve.name == "secp256r1"
