import datetime
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys

def command(*args):
    return subprocess.check_output(args, text=True).strip()

swift = command("swift", "--version")
metadata = {
    "baseline": sys.argv[1],
    "date": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "commit": command("git", "rev-parse", "HEAD"),
    "status": command("git", "status", "--short"),
    "tracked_diff_sha256": hashlib.sha256(subprocess.check_output(["git", "diff", "HEAD"])).hexdigest(),
    "fixture_revision": 1,
    "mac_model": command("sysctl", "-n", "hw.model"),
    "macos": command("sw_vers"),
    "swift": swift,
    "jemalloc_packages": [json.loads(p.read_text()) for p in sorted(Path(sys.argv[2], "conda-meta").glob("*.json"))],
}
# Preserve the exact versioned benchmark sources even before their first commit.
digest = hashlib.sha256()
sources = list(Path("Benchmarks/Benchmarks").rglob("*.swift")) + list(Path("Benchmarks/Support").rglob("*.h"))
sources += [Path("Benchmarks/Package.swift"), Path("Benchmarks/Package.resolved"), Path("Scripts/benchmark.swift"), Path("Scripts/benchmark-metadata.py")]
for path in sorted(sources):
    digest.update(str(path).encode())
    digest.update(path.read_bytes())
metadata["benchmark_sources_sha256"] = digest.hexdigest()
version = re.search(r"Swift version (\d+)\.(\d+)", swift)
if version is None:
    raise RuntimeError("Cannot identify Swift allocator backend")
metadata["allocator_backend"] = "jemalloc" if tuple(map(int, version.groups())) < (6, 3) else "malloc-interposer"
directory = Path("Benchmarks/results")
directory.mkdir(exist_ok=True)
path = directory / (datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%S%fZ") + ".environment.json")
path.write_text(json.dumps(metadata, indent=2) + "\n")
print(f"Environment metadata: {path}")
