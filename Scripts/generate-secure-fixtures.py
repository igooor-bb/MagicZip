"""Independent CDCD fixtures built with pyzipper and explicit ZIP structures.

No MagicZip/minizip code is used. Local names are replaced with opaque equal-length
names so original offsets stay valid; the real central directory is AES-encrypted.
"""
from pathlib import Path
import hashlib
import io
import json
import struct
import pyzipper

OUT = Path(__file__).resolve().parents[1] / "Tests/MagicZipTests/Fixtures"
PASSWORD = b"fixture-password"


class ExtraZipInfo(pyzipper.zipfile_aes.AESZipInfo):
    # pyzipper 0.4 omits caller extras in central_directory(); preserve CDCD explicitly.
    def encode_central_directory(self, **kwargs):
        kwargs["extra_data"] += self.extra
        return super().encode_central_directory(**kwargs)


def encrypted_zip(entries):
    output = io.BytesIO()
    with pyzipper.AESZipFile(output, "w", compression=pyzipper.ZIP_DEFLATED) as archive:
        archive.zipinfo_cls = ExtraZipInfo
        archive.setpassword(PASSWORD)
        archive.setencryption(pyzipper.WZ_AES, nbits=256)
        for name, data, extra in entries:
            info = archive.zipinfo_cls(name)
            info.compress_type = pyzipper.ZIP_DEFLATED
            info.extra = extra
            archive.writestr(info, data)
    return bytearray(output.getvalue())


def end_info(raw):
    end = raw.rindex(b"PK\x05\x06")
    return end, struct.unpack_from("<I", raw, end + 16)[0]


def make_archive(name, path):
    raw = encrypted_zip([(path, b"independent secure payload", b"")])
    end, cd = end_info(raw)
    catalog = bytearray(raw[cd:end])
    # Mask local header and signal masking in the corresponding central record.
    struct.pack_into("<H", raw, 6, struct.unpack_from("<H", raw, 6)[0] | 0x2000)
    struct.pack_into("<H", catalog, 8, struct.unpack_from("<H", catalog, 8)[0] | 0x2000)
    raw[10:18] = b"\0" * 8  # timestamp and CRC
    length = struct.unpack_from("<H", raw, 26)[0]
    raw[30:30 + length] = b"x" * length
    prefix = raw[:cd]
    outer = encrypted_zip([("__cdcd__", bytes(catalog), struct.pack("<HHQ", 0xcdcd, 8, 1))])
    outer_end, outer_cd = end_info(outer)
    struct.pack_into("<I", outer, outer_cd + 42, len(prefix))
    struct.pack_into("<I", outer, outer_end + 16, len(prefix) + outer_cd)
    result = prefix + outer
    (OUT / name).write_bytes(result)
    return result, len(prefix), len(prefix) + outer_cd


raw, local, cd = make_archive("secure-independent.zip", "private/report.txt")
make_archive("secure-unsafe-path.zip", "../escape.txt")
corrupt = bytearray(raw)
corrupt[local - 1] ^= 0x80
(OUT / "secure-payload-corrupt.zip").write_bytes(corrupt)
corrupt = bytearray(raw)
# Corrupt the final authentication byte of the catalog entry.
corrupt[cd - 1] ^= 0x80
(OUT / "secure-catalog-corrupt.zip").write_bytes(corrupt)
corrupt = bytearray(raw)
# Catalog announces an allocation exceeding the fixed 64 MiB metadata cap.
struct.pack_into("<I", corrupt, cd + 24, 64 * 1024 * 1024 + 1)
(OUT / "secure-catalog-oversized.zip").write_bytes(corrupt)
corrupt = bytearray(raw)
# The header's unauthenticated count must be checked against the decoded directory.
extra = cd + 46 + len("__cdcd__")
while struct.unpack_from("<H", corrupt, extra)[0] != 0xcdcd:
    extra += 4 + struct.unpack_from("<H", corrupt, extra + 2)[0]
assert struct.unpack_from("<H", corrupt, extra + 2)[0] == 8
struct.pack_into("<Q", corrupt, extra + 4, 2)
(OUT / "secure-count-mismatch.zip").write_bytes(corrupt)
(OUT / "SHA256.json").write_text(json.dumps({p.name: hashlib.sha256(p.read_bytes()).hexdigest()
    for p in sorted(OUT.glob("*.zip"))}, indent=2) + "\n")
