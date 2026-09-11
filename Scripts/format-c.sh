#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Explicit owned-code roots: never descend into vendor/.
options=(-i)
if [[ "${1:-}" == "--check" ]]; then
    options=(--dry-run --Werror)
elif [[ $# -gt 0 ]]; then
    echo "Usage: $0 [--check]" >&2
    exit 2
fi
clang-format "${options[@]}" Sources/CMinizip/MagicZipAdapter.c Sources/CMinizip/include/CMinizip.h \
    Tests/CMinizipTestSupport/FinalizationProbe.c Tests/CMinizipTestSupport/include/FinalizationProbe.h
