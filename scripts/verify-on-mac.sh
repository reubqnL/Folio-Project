#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo 'Native verification requires an Apple Silicon Mac with macOS 26+ and Xcode 26+.' >&2
  exit 1
fi
if [[ "$(uname -m)" != "arm64" ]]; then
  echo 'Use a native arm64 Terminal session on Apple Silicon, not Rosetta.' >&2
  exit 1
fi
for tool in swift xcodebuild xcodegen codesign; do
  if ! command -v "$tool" >/dev/null; then
    echo "Missing $tool. Select Xcode with xcode-select; install XcodeGen separately if needed." >&2
    exit 1
  fi
done
OS_VERSION="$(sw_vers -productVersion)"
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
if (( ${OS_VERSION%%.*} < 26 || ${SDK_VERSION%%.*} < 26 )); then
  echo "This baseline targets macOS 26+. Host: $OS_VERSION; SDK: $SDK_VERSION" >&2
  exit 1
fi
xcodebuild -version
swift --version
swift test --scratch-path .build-output/core-tests
PROBE_DIR=$(swift build --scratch-path .build-output/core-tests --show-bin-path)
python3 scripts/test-storage-processes.py --probe "$PROBE_DIR/folio-storage-probe"
"$PROBE_DIR/folio-reading-probe" Evidence/reading-workflow.json
"$PROBE_DIR/folio-planning-probe" scenario Evidence/planning-workflow.json
"$PROBE_DIR/folio-capture-probe" Evidence/capture-workflow.json
"$PROBE_DIR/folio-speech-probe" Evidence/speech-workflow.json
bash scripts/test-audio-ring.sh
python3 scripts/test-roadmap-processes.py --probe "$PROBE_DIR/folio-planning-probe"
xcodegen generate --spec project.yml
xcodebuild -project Folio.xcodeproj -scheme Folio -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath .build-output/native \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= \
  PROVISIONING_PROFILE_SPECIFIER= build
APP='.build-output/native/Build/Products/Debug/Folio.app'
codesign --verify --deep --strict "$APP"
codesign --display --entitlements - "$APP" > .build-output/debug-entitlements.plist
SANDBOX=$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' .build-output/debug-entitlements.plist)
FILE_ACCESS=$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.files.user-selected.read-write' .build-output/debug-entitlements.plist)
AUDIO_INPUT=$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.device.audio-input' .build-output/debug-entitlements.plist)
if [[ "$SANDBOX" != 'true' || "$FILE_ACCESS" != 'true' || "$AUDIO_INPUT" != 'true' ]]; then
  echo 'The local app is missing its sandbox, user-selected-file or audio-input entitlement. Do not continue to runtime testing.' >&2
  exit 1
fi
printf '\nLocal ad-hoc-signed development build completed.\n'
printf 'Run explicitly with: open %s\n' "$APP"
printf 'Ad-hoc signing is only for local development: no Developer ID, notarization, installer or production security approval is implied.\n'
