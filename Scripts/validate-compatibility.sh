#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift run --package-path Validation/Compatibility CompatibilityValidation
build_directory="$(swift build --package-path Validation/Compatibility --show-bin-path)"
python3 Scripts/check-c-symbols.py "$build_directory/CMinizip.build"
