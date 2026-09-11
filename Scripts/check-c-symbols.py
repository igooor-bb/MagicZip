"""Verify defined C globals, not just Clang module names, are isolated."""
from pathlib import Path
import subprocess
import sys

objects = sorted(Path(sys.argv[1]).rglob("*.o"))
if not objects:
    raise SystemExit("No CMinizip object files found")
output = subprocess.check_output(["nm", "-gjU", *(str(path) for path in objects)], text=True)
symbols = [line.strip() for line in output.splitlines() if line.strip() and not line.endswith(":")]
unexpected = [name for name in symbols if not name.startswith("_magiczip_")]
if not symbols or unexpected:
    raise SystemExit("Unisolated C symbols: " + repr(unexpected))
print(f"PASS: all {len(symbols)} defined C globals have the MagicZip prefix")
