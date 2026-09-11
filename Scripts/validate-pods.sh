#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
build_root="${MAGICZIP_POD_BUILD_ROOT:-/tmp/MagicZipPodValidation}"
bundle exec ruby Validation/PodClient/generate.rb
bundle exec pod install --project-directory=Validation/PodClient
for platform in macOS iOS 'iOS Simulator'; do
    scheme=ClientIOS
    if [[ "$platform" == macOS ]]; then scheme=ClientMac; fi
    slug="${platform// /-}"
    xcodebuild -quiet -workspace Validation/PodClient/Client.xcworkspace -scheme "$scheme" \
        -configuration Release -destination "generic/platform=$platform" -derivedDataPath "$build_root/$slug" \
        CODE_SIGNING_ALLOWED=NO build
done
"$build_root/macOS/Build/Products/Release/ClientMac.app/Contents/MacOS/ClientMac"
# Unpublished source/homepage URLs and upstream SDK warnings are allowed; compilation errors are not.
bundle exec pod lib lint MagicZip.podspec --include-podspecs=MagicZipCMinizip.podspec \
    --platforms=ios,osx --skip-tests --use-libraries --allow-warnings
