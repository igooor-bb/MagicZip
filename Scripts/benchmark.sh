#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ -n "${BENCHMARK_DISABLE_JEMALLOC+x}" || -n "${BENCHMARK_DISABLE_MALLOC_INTERPOSER+x}" ]]; then
    echo "Benchmark allocation metrics require the allocator backend; unset BENCHMARK_DISABLE_* variables." >&2
    exit 1
fi

jemalloc_prefix=$(mise where conda:jemalloc)
if [[ ! -f "$jemalloc_prefix/include/jemalloc/jemalloc.h" || ! -f "$jemalloc_prefix/lib/libjemalloc.dylib" ]]; then
    echo "Missing jemalloc: run mise install conda:jemalloc@5.3.0." >&2
    exit 1
fi

# The command plugin performs nested builds, so propagate the adapter through
# pkg-config rather than command-line -Xcc flags (which nested builds discard).
mkdir -p Benchmarks/.build/jemalloc-pkgconfig
cat > Benchmarks/.build/jemalloc-pkgconfig/jemalloc.pc <<EOF
Name: jemalloc
Description: mise conda jemalloc with Benchmark statistics names
Version: 5.3.0
Cflags: -I"$PWD/Benchmarks/Support" -I"$jemalloc_prefix/include"
Libs: -L"$jemalloc_prefix/lib" -ljemalloc
EOF
export PKG_CONFIG_PATH="$PWD/Benchmarks/.build/jemalloc-pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

# Conda's dylib uses @rpath; resolve it without relying on Homebrew or global DYLD variables.
swift package --package-path Benchmarks -c release \
    -Xlinker -rpath -Xlinker "$jemalloc_prefix/lib" \
    --allow-writing-to-package-directory benchmark "$@"

if [[ "${1:-}" == baseline && "${2:-}" == update ]]; then
    python3 - "${3:-}" "$jemalloc_prefix" <<'PY'
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
sources += [Path("Benchmarks/Package.swift"), Path("Benchmarks/Package.resolved"), Path("Scripts/benchmark.sh")]
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
PY
fi
