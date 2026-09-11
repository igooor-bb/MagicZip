"""Independent path/tree and Store AES fixtures; called by generate-fixtures.py."""
from pathlib import Path
import hashlib
import json
import zipfile
import pyzipper

OUT = Path(__file__).resolve().parents[1] / "Tests/MagicZipTests/Fixtures"
for filename, entries in {
    "directory-no-slash.zip": [("assets", True), ("assets-old/file", False)],
    "directory-slash.zip": [("assets/", True), ("assets/child", False), ("assets-old/file", False)],
    "directory-implicit.zip": [("assets/child", False), ("assets-old/file", False)],
    "directory-file.zip": [("assets", False), ("assets-old/file", False)],
    "directory-unicode.zip": [("ресурсы", True), ("ресурсы/файл", False)],
    "deep-valid.zip": [("a/" * 96 + "f", False)],
}.items():
    with zipfile.ZipFile(OUT / filename, "w") as archive:
        for name, directory in entries:
            info = zipfile.ZipInfo(name)
            info.create_system = 3
            info.external_attr = (0o40755 if directory else 0o100644) << 16
            archive.writestr(info, b"" if directory else b"fixture-payload")
raw = bytearray((OUT / "deep-valid.zip").read_bytes())
raw[raw.index(b"fixture-payload")] ^= 0xFF
(OUT / "deep-corrupt.zip").write_bytes(raw)
for version in (1, 2):
    with pyzipper.AESZipFile(OUT / f"aes-store{version}.zip", "w", compression=pyzipper.ZIP_STORED) as archive:
        archive.setpassword(b"fixture-password")
        archive.setencryption(pyzipper.WZ_AES, nbits=256, force_wz_aes_version=version)
        archive.writestr("secret.txt", b"independent AES fixture " * 4)
        archive.writestr("empty", b"")

(OUT / "SHA256.json").write_text(json.dumps({p.name: hashlib.sha256(p.read_bytes()).hexdigest()
    for p in sorted(OUT.glob("*.zip"))}, indent=2) + "\n")
