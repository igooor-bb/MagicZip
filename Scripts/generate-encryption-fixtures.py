"""Read-compatibility fixtures from pyzipper and the macOS Info-ZIP executable.

Run with the locked fixture environment. Only public test passwords are used.
"""
from pathlib import Path
import hashlib
import json
import struct
import subprocess
import tempfile
import zipfile
import pyzipper

OUT = Path(__file__).resolve().parents[1] / "Tests/MagicZipTests/Fixtures"
PAYLOAD = b"independent encryption fixture " * 4
for bits in (128, 192):
    for version in (1, 2):
        for method, compression in (("store", 0), ("deflate", 8)):
            path = OUT / f"aes{bits}-ae{version}-{method}.zip"
            with pyzipper.AESZipFile(path, "w", compression=compression) as archive:
                archive.setpassword(b"fixture-password")
                archive.setencryption(pyzipper.WZ_AES, nbits=bits, force_wz_aes_version=version)
                archive.writestr("secret.txt", PAYLOAD)
                archive.writestr("empty", b"")
            if version == 2 and method == "store":
                raw = bytearray(path.read_bytes())
                with zipfile.ZipFile(path) as archive:
                    info = archive.getinfo("secret.txt")
                    offset = info.header_offset
                    names, extras = struct.unpack_from("<HH", raw, offset + 26)
                    raw[offset + 30 + names + extras + info.compress_size - 1] ^= 1
                (OUT / f"aes{bits}-corrupt.zip").write_bytes(raw)

with tempfile.TemporaryDirectory() as temporary:
    root = Path(temporary)
    (root / "secret.txt").write_bytes(PAYLOAD)
    (root / "empty").write_bytes(b"")
    for method, level in (("store", "-0"), ("deflate", "-6")):
        path = OUT / f"zipcrypto-{method}.zip"
        path.unlink(missing_ok=True)
        subprocess.run(["/usr/bin/zip", "-q", level, "-P", "fixture-password", str(path), "secret.txt", "empty"], cwd=root, check=True)
    path = OUT / "zipcrypto-store.zip"
    raw = bytearray(path.read_bytes())
    with zipfile.ZipFile(path) as archive:
        info = archive.getinfo("secret.txt")
        names, extras = struct.unpack_from("<HH", raw, info.header_offset + 26)
        raw[info.header_offset + 30 + names + extras + info.compress_size - 1] ^= 1
    (OUT / "zipcrypto-corrupt.zip").write_bytes(raw)

(OUT / "SHA256.json").write_text(json.dumps({p.name: hashlib.sha256(p.read_bytes()).hexdigest()
    for p in sorted(OUT.glob("*.zip"))}, indent=2) + "\n")
