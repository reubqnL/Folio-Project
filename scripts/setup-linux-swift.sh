#!/bin/bash
# Optional reproducible Linux CORE-test toolchain; not a macOS application SDK.
set -euo pipefail
if [[ "$(uname -s)" != Linux || "$(uname -m)" != x86_64 ]]; then
  echo 'This optional test bootstrap is for Linux x86_64 only. Use Xcode on macOS.' >&2
  exit 1
fi
CACHE="${HOME}/.cache/folio-swift"
DIR='swift-6.0.3-RELEASE-ubuntu22.04'
URL='https://download.swift.org/swift-6.0.3-release/ubuntu2204/swift-6.0.3-RELEASE/swift-6.0.3-RELEASE-ubuntu22.04.tar.gz'
SHA='09d0a53fbddf2878673dd12c1504e7143c788f195caec9f2329740946eba525c'
if [[ ! -x "$CACHE/$DIR/usr/bin/swift" ]]; then
  mkdir -p "$CACHE"
  curl --fail --location --retry 3 "$URL" -o "$CACHE/toolchain.tar.gz"
  printf '%s  %s\n' "$SHA" "$CACHE/toolchain.tar.gz" | sha256sum -c -
  tar -xzf "$CACHE/toolchain.tar.gz" -C "$CACHE"
fi
"$CACHE/$DIR/usr/bin/swift" --version
printf '\nUse: export PATH="%s/usr/bin:$PATH"\n' "$CACHE/$DIR"
printf 'Linux core tests also require system OpenSSL and SQLite3 development headers/libraries and a linker.\n'
printf 'Pinned SHA records the tested official-download artifact; it is not a claim of an independently audited compiler.\n'
