#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/.."
mkdir -p build/sideload

# A device build is mandatory: renaming a Simulator app to .ipa cannot make it installable.
xcodebuild -quiet \
    -project Zotero.xcodeproj \
    -scheme Zotero \
    -configuration Release \
    -sdk iphoneos \
    -destination 'generic/platform=iOS' \
    -derivedDataPath build/SideloadDerivedData \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_ENTITLEMENTS= \
    DEVELOPMENT_TEAM= \
    ARCHS=arm64 \
    ONLY_ACTIVE_ARCH=YES \
    'OTHER_SWIFT_FLAGS=$(inherited) -D SIDELOAD' \
    clean build 2>&1 | tee build/sideload/device-build.log

python3 scripts/package_sideload_ipa.py \
    --app build/SideloadDerivedData/Build/Products/Release-iphoneos/Zotero.app \
    --output build/sideload/Zotero-Translate-Free-unsigned.ipa \
    --target-ios 18.7.8 \
    --commit "$(git rev-parse HEAD)"
