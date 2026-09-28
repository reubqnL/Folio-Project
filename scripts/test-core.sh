#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
SWIFT="${SWIFT_BIN:-swift}"
SCRATCH="${FOLIO_TEST_SCRATCH:-$HOME/.cache/folio-core-build}"
FIXTURES="${FOLIO_TEST_TEMP:-$HOME/.cache/folio-core-fixtures}"
mkdir -p "$FIXTURES" Evidence
export TMPDIR="$FIXTURES"
"$SWIFT" --version
"$SWIFT" test --scratch-path "$SCRATCH" 2>&1 | tee Evidence/core-tests.log
"$SWIFT" test -c release --scratch-path "$SCRATCH" 2>&1 | tee Evidence/core-tests-release.log
BIN_DIR=$("$SWIFT" build --scratch-path "$SCRATCH" --show-bin-path)
python3 scripts/test-storage-processes.py --probe "$BIN_DIR/folio-storage-probe" --temp-parent "$FIXTURES"
"$BIN_DIR/folio-reading-probe" Evidence/reading-workflow.json
"$BIN_DIR/folio-planning-probe" scenario Evidence/planning-workflow.json
"$BIN_DIR/folio-capture-probe" Evidence/capture-workflow.json
"$BIN_DIR/folio-speech-probe" Evidence/speech-workflow.json
bash scripts/test-audio-ring.sh
python3 scripts/test-roadmap-processes.py --probe "$BIN_DIR/folio-planning-probe" --temp-parent "$FIXTURES"
printf '\nCore and process tests complete. This is not AppKit, power-loss or release-security approval.\n'
