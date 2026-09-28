#!/bin/bash
# Engineering-only C memory/undefined-behaviour checks with generated samples.
set -euo pipefail
cd "$(dirname "$0")/.."
CLANG="${CLANG_BIN:-clang}"
SCRATCH="${FOLIO_AUDIO_CHECK_SCRATCH:-$HOME/.cache/folio-audio-checks}"
mkdir -p "$SCRATCH" Evidence
"$CLANG" -std=c11 -O1 -g -Wall -Wextra -Werror -pthread \
  -fsanitize=address,undefined -fno-omit-frame-pointer \
  -I Sources/FolioFileIO/include Sources/FolioFileIO/FolioAudioRing.c \
  Tests/AudioRingChecks/audio-ring-check.c -o "$SCRATCH/audio-ring-check"
ASAN_OPTIONS=detect_leaks=1:halt_on_error=1 UBSAN_OPTIONS=halt_on_error=1 \
  python3 - "$SCRATCH/audio-ring-check" <<'PY'
import json, subprocess, sys
from pathlib import Path
result = subprocess.run([sys.argv[1]], capture_output=True, text=True, timeout=30, check=True)
if result.stderr.strip():
    raise RuntimeError(result.stderr)
report = json.loads(result.stdout)
assert report['status'] == 'PASS' and report['checks'] == 6
Path('Evidence/audio-ring-sanitizers.json').write_text(json.dumps(report, indent=2))
print(json.dumps(report, indent=2))
PY
