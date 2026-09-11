#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Compile before limiting descriptors; only the selected suite runs in the child process.
swift build --build-tests
export MAGICZIP_TREE_PROBE=1
python3 -c 'import subprocess; subprocess.run(["swift", "test", "--skip-build", "--filter", "TreeResourceTests"], check=True, timeout=120)'
