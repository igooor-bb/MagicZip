"""Generate test-only independent fixtures (Python zipfile + pyzipper 0.4.0).

Run `mise run fixtures-python` with the checked-in uv.lock. AES salts are random;
checked-in fixture hashes identify the exact test corpus. No runtime dependency.
"""
from pathlib import Path
import hashlib
import json
import struct
import zipfile
import pyzipper

OUT = Path(__file__).resolve().parents[1] / "Tests/MagicZipTests/Fixtures"
OUT.mkdir(parents=True, exist_ok=True)
with zipfile.ZipFile(OUT / "python.zip", "w") as archive:
    archive.writestr("hello.txt", b"independent zipfile\n", compress_type=zipfile.ZIP_DEFLATED)
    archive.writestr("assets/", b"")
    archive.writestr("assets/привет.txt", "Привет, ZIP!".encode(), compress_type=zipfile.ZIP_DEFLATED)
    archive.writestr("empty", b"")
    archive.writestr("empty-dir/", b"")
    archive.writestr("stored.bin", bytes(range(256)))
    with archive.open("zip64.txt", "w", force_zip64=True) as entry:
        entry.write(b"forced ZIP64")

for version in (1, 2):
    with pyzipper.AESZipFile(OUT / f"aes{version}.zip", "w", compression=pyzipper.ZIP_DEFLATED) as archive:
        archive.setpassword(b"fixture-password")
        archive.setencryption(pyzipper.WZ_AES, nbits=256, force_wz_aes_version=version)
        archive.writestr("secret.txt", b"independent AES fixture " * 4)
        archive.writestr("empty", b"")

for filename, names in {
    "traversal.zip": ["../outside"], "absolute.zip": ["/outside"], "windows.zip": ["C:\\outside"],
    "duplicate.zip": ["same", "same"], "case-alias.zip": ["File", "file"],
    "unicode-alias.zip": ["é", "e\u0301"], "prefix-conflict.zip": ["a", "a/b"],
    "dot.zip": ["a/./b"], "empty-component.zip": ["a//b"],
}.items():
    with zipfile.ZipFile(OUT / filename, "w") as archive:
        for name in names:
            archive.writestr(name, b"unsafe")

with zipfile.ZipFile(OUT / "symlink.zip", "w") as archive:
    info = zipfile.ZipInfo("link")
    info.create_system = 3
    info.external_attr = 0o120777 << 16
    archive.writestr(info, b"../outside")

with zipfile.ZipFile(OUT / "unsupported.zip", "w") as archive:
    archive.writestr("good", b"selected")
    archive.writestr("bzip2", b"unsupported", compress_type=zipfile.ZIP_BZIP2)

with zipfile.ZipFile(OUT / "selective-corrupt.zip", "w") as archive:
    archive.writestr("good", b"selected")
    archive.writestr("bad", b"corrupt-me")
raw = bytearray((OUT / "selective-corrupt.zip").read_bytes())
raw[raw.index(b"corrupt-me")] ^= 0xFF
(OUT / "selective-corrupt.zip").write_bytes(raw)
raw = (OUT / "python.zip").read_bytes()
(OUT / "truncated.zip").write_bytes(raw[:-13])
# Corrupt only the AES authentication code; compressed ciphertext remains intact.
raw = bytearray((OUT / "aes2.zip").read_bytes())
with zipfile.ZipFile(OUT / "aes2.zip") as archive:
    info = archive.getinfo("secret.txt")
    offset = info.header_offset
    name_len, extra_len = struct.unpack_from("<HH", raw, offset + 26)
    authentication = offset + 30 + name_len + extra_len + info.compress_size - 1
raw[authentication] ^= 1
(OUT / "aes-auth-corrupt.zip").write_bytes(raw)
(OUT / "SHA256.json").write_text(json.dumps({p.name: hashlib.sha256(p.read_bytes()).hexdigest()
    for p in sorted(OUT.glob("*.zip"))}, indent=2) + "\n")
print("Generated", len(list(OUT.glob("*.zip"))), "independent fixtures")
