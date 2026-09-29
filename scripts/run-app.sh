#!/bin/bash
# Generate, build and launch the native Folio app.
#
# Why this script exists: the Swift package at the repository root defines six
# executable *probes* (storage, reading, planning, capture, speech, benchmark).
# The app is not one of them — it is the Xcode target defined in `project.yml`,
# because it needs an Info.plist, an asset catalog and sandbox entitlements.
# `swift run` therefore cannot launch Folio; it only reports that several
# executable products are available. Use this script, or run
# `bash scripts/verify-on-mac.sh`, which additionally runs the core checks and
# asserts the entitlements.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo 'Building the app requires an Apple Silicon Mac with macOS 26+ and Xcode 26+.' >&2
  exit 1
fi
if [[ "$(uname -m)" != "arm64" ]]; then
  echo 'Use a native arm64 Terminal session on Apple Silicon, not Rosetta.' >&2
  exit 1
fi
for tool in xcodebuild codesign; do
  if ! command -v "$tool" >/dev/null; then
    echo "Missing $tool. Select Xcode with xcode-select --install or xcode-select -s." >&2
    exit 1
  fi
done

# Products stay outside the checkout, so a cloud-synced folder (OneDrive, iCloud
# Drive, Dropbox) cannot attach the file-provider attributes that make codesign
# refuse the bundle. See scripts/verify-on-mac.sh for the full explanation.
BUILD_ROOT="${FOLIO_BUILD_DIR:-$HOME/.cache/folio-mac-build}"
NATIVE_DERIVED="$BUILD_ROOT/native"
APP="$NATIVE_DERIVED/Build/Products/Debug/Folio.app"
mkdir -p "$BUILD_ROOT"

if [[ ! -d Folio.xcodeproj || project.yml -nt Folio.xcodeproj || App -nt Folio.xcodeproj || Sources -nt Folio.xcodeproj ]]; then
  if ! command -v xcodegen >/dev/null; then
    echo 'Missing xcodegen. Install it with: brew install xcodegen' >&2
    echo 'Then re-run this script so Folio.xcodeproj exists.' >&2
    exit 1
  fi
  xcodegen generate --spec project.yml
fi

xcodebuild -project Folio.xcodeproj -scheme Folio -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$NATIVE_DERIVED" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= \
  PROVISIONING_PROFILE_SPECIFIER= build

if [[ ! -d "$APP" ]]; then
  echo "The build reported success but $APP does not exist." >&2
  exit 1
fi
xattr -cr "$APP" 2>/dev/null || true
codesign --verify --deep --strict "$APP"

printf '\nLaunching %s\n' "$APP"
open "$APP"
printf 'Ad-hoc signing is only for local development: no Developer ID, notarization, installer or production security approval is implied.\n'
