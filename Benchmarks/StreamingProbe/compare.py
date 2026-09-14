"""Private reproducible benchmark driver. Usage: python script.py BASELINE_BINARY CURRENT_BINARY.

Three fresh processes per measurement; timeout and output-size limits contain regressions.
The two binaries must be full Swift/C Release builds. Scratch data is removed afterward.
"""
from pathlib import Path
import random
import resource
import subprocess
import sys
import shutil
import tempfile
import zipfile


def limits():
    resource.setrlimit(resource.RLIMIT_FSIZE, (512 * 1024**2, 512 * 1024**2))


def measure(binary, root, operation, variant):
    return subprocess.check_output([binary, "--benchmark", str(root), operation, variant],
                                   text=True, timeout=120, preexec_fn=limits).strip()


with tempfile.TemporaryDirectory(prefix="magiczip-benchmark-", dir="/tmp") as scratch:
    root = Path(scratch).resolve()
    chunk = random.Random(42).randbytes(65536)
    # Actual file producer; a mix of compressible and incompressible blocks (128 MiB).
    with (root / "payload").open("wb") as file:
        for index in range(2048):
            file.write(chunk if index % 2 else bytes(65536))
    (root / "small").mkdir()
    for index in range(2000):
        (root / "small" / f"f{index:04d}").write_bytes(chunk[:1024])
    print("build,run,operation,variant,seconds,peak_rss_mib,heap_high_water_bytes,live_blocks", flush=True)
    if "--crc" in sys.argv:
        for variant in ("store", "deflate", "store-aes", "deflate-aes"):
            measure(sys.argv[2], root, "write", variant)
            for repetition in range(5):
                for label, binary in zip(("before", "after"), sys.argv[1:3]):
                    print(f"{label},{repetition}," + measure(binary, root, "read", variant), flush=True)
        sys.exit(0)
    for depth in (2000, 4000, 8000):
        path = root / f"depth-{depth}.zip"
        with zipfile.ZipFile(path, "w") as archive:
            archive.writestr("a/" * depth + "f", b"")
        for repetition in range(3):
            for label, binary in zip(("before", "after"), sys.argv[1:3]):
                print(f"{label},{repetition}," + measure(binary, path, "paths", str(depth)), flush=True)
    for variant in ("store", "deflate", "store-aes", "deflate-aes"):
        for workload in ("write", "tree"):
            for repetition in range(3):
                for label, binary in zip(("before", "after"), sys.argv[1:3]):
                    for operation in (workload, "read", "extract"):
                        row = measure(binary, root, operation, variant)
                        print(f"{label},{repetition}," + row.replace(variant, workload + "-" + variant), flush=True)
                    # Extraction replacement/cleanup is excluded from this streaming timing.
                    shutil.rmtree(root / "extracted")
