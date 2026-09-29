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

# Build products are written outside the checkout by default.
#
# Why: codesign refuses a bundle that carries extended attributes such as
# com.apple.FinderInfo or com.apple.ResourceFork ("resource fork, Finder
# information, or similar detritus not allowed"). Cloud file providers
# (OneDrive, iCloud Drive, Dropbox) attach exactly those attributes to every
# file under their folder, including the ones a build writes. A build tree that
# lives inside a synced folder therefore fails at the signing step with an error
# that names the bundle, not the folder. `~/.cache` is never synced, so the
# default here avoids the whole class of failure. Override with
# FOLIO_BUILD_DIR if you want the products kept somewhere else.
BUILD_ROOT="${FOLIO_BUILD_DIR:-$HOME/.cache/folio-mac-build}"
CORE_SCRATCH="$BUILD_ROOT/core-tests"
NATIVE_DERIVED="$BUILD_ROOT/native"
FIXTURES="$BUILD_ROOT/process-fixtures"
mkdir -p "$BUILD_ROOT" "$FIXTURES"

REPO_ROOT="$(pwd -P)"
case "$REPO_ROOT" in
  *"/Library/CloudStorage/"*|*"/Library/Mobile Documents/"*|*"/Dropbox/"*|*"/com~apple~CloudDocs/"*)
    echo "Note: this checkout is inside a cloud-synced folder."
    echo "      Build products go to $BUILD_ROOT, which is not synced."
    echo "      Keep it that way: signing a bundle with file-provider attributes fails."
    echo
    ;;
esac

# Belt and braces for anything that does end up carrying detritus: signing and
# bundle verification are the two steps that reject it.
strip_detritus() {
  if [[ -e "$1" ]]; then xattr -cr "$1" 2>/dev/null || true; fi
}

xcodebuild -version
swift --version
swift test --scratch-path "$CORE_SCRATCH"
PROBE_DIR=$(swift build --scratch-path "$CORE_SCRATCH" --show-bin-path)
python3 scripts/test-storage-processes.py --probe "$PROBE_DIR/folio-storage-probe" --temp-parent "$FIXTURES"
"$PROBE_DIR/folio-reading-probe" Evidence/reading-workflow.json
"$PROBE_DIR/folio-planning-probe" scenario Evidence/planning-workflow.json
"$PROBE_DIR/folio-capture-probe" Evidence/capture-workflow.json
"$PROBE_DIR/folio-speech-probe" Evidence/speech-workflow.json
bash scripts/test-audio-ring.sh
python3 scripts/test-roadmap-processes.py --probe "$PROBE_DIR/folio-planning-probe" --temp-parent "$FIXTURES"

xcodegen generate --spec project.yml
strip_detritus Folio.xcodeproj
xcodebuild -project Folio.xcodeproj -scheme Folio -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$NATIVE_DERIVED" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= \
  PROVISIONING_PROFILE_SPECIFIER= build

APP="$NATIVE_DERIVED/Build/Products/Debug/Folio.app"
if [[ ! -d "$APP" ]]; then
  echo "The build reported success but $APP does not exist." >&2
  exit 1
fi
strip_detritus "$NATIVE_DERIVED/Build/Products"
codesign --verify --deep --strict "$APP"
codesign --display --entitlements - "$APP" > "$BUILD_ROOT/debug-entitlements.plist"
SANDBOX=$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' "$BUILD_ROOT/debug-entitlements.plist")
FILE_ACCESS=$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.files.user-selected.read-write' "$BUILD_ROOT/debug-entitlements.plist")
AUDIO_INPUT=$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.device.audio-input' "$BUILD_ROOT/debug-entitlements.plist")
if [[ "$SANDBOX" != 'true' || "$FILE_ACCESS" != 'true' || "$AUDIO_INPUT" != 'true' ]]; then
  echo 'The local app is missing its sandbox, user-selected-file or audio-input entitlement. Do not continue to runtime testing.' >&2
  exit 1
fi
printf '\nLocal ad-hoc-signed development build completed.\n'
printf 'Launch it with:\n  bash scripts/run-app.sh\n'
printf 'or directly with:\n  open "%s"\n' "$APP"
printf 'Ad-hoc signing is only for local development: no Developer ID, notarization, installer or production security approval is implied.\n'
