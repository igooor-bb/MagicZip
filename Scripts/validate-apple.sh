#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
build_root="${MAGICZIP_BUILD_ROOT:-/tmp/MagicZipAppleValidation}"
for platform in macOS iOS 'iOS Simulator'; do
    slug="${platform// /-}"
    xcodebuild -quiet -scheme MagicZip -configuration Release \
        -destination "generic/platform=$platform" -derivedDataPath "$build_root/$slug" \
        CODE_SIGNING_ALLOWED=NO build
 done
xcodebuild -quiet -scheme MagicZip -destination 'generic/platform=macOS' \
    -derivedDataPath "$build_root/Documentation" CODE_SIGNING_ALLOWED=NO \
    OTHER_DOCC_FLAGS='--warnings-as-errors' docbuild
