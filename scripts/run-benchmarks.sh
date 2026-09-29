#!/bin/bash
# Large-file/long-line benchmark evidence (N02; decision 26 — measured
# large-document performance is a release gate with no waiver path).
#
# Builds the probe in release and records measurements to Evidence/.
# Evidence/ is intentionally not committed; attach the JSON and the machine
# details (model, OS, thermal state) when using results as gate evidence.
# Timings are never asserted anywhere — they are recorded, reviewed and
# credited as evidence only on the machine class that will sign the release.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --product FolioBenchmarkProbe
mkdir -p Evidence
echo "Recording measurements to Evidence/benchmarks.json ..."
.build/release/FolioBenchmarkProbe --json > Evidence/benchmarks.json
echo
.build/release/FolioBenchmarkProbe
echo
echo "Done. Evidence/benchmarks.json holds machine-readable results."
echo "Record them with the machine class that will sign the release (decision 26)."
