# Evidence

Generated verification output. **This directory's reports and logs are not
committed to Git** — they are regenerated from source and they embed
host-specific build paths. Only this `README.md` is tracked, so the directory
and its purpose stay discoverable after a clean clone.

See the "What is *not* in Git" table in the root [`README.md`](../README.md).

## Regenerating

From the repository root:

```sh
bash scripts/test-core.sh
```

This runs the SwiftPM test suite in Debug and Release, then executes the
storage, reading, planning, capture and speech probes plus the C audio-ring
sanitizer harness. Each writes its report here:

| File | Produced by | Contents |
|---|---|---|
| `core-tests.log` | `scripts/test-core.sh` | XCTest run, Debug |
| `core-tests-release.log` | `scripts/test-core.sh` | XCTest run, Release |
| `process-crash-tests.json` | `scripts/test-storage-processes.py` | SIGKILL recovery matrix for the storage core |
| `roadmap-crash-tests.json` | `scripts/test-roadmap-processes.py` | SIGKILL recovery matrix for the roadmap store |
| `reading-workflow.json` | `folio-reading-probe` | Reading workflow over 1,000 generated notes |
| `planning-workflow.json` | `folio-planning-probe` | Roadmap/graph workflow checks |
| `capture-workflow.json` | `folio-capture-probe` | Capture workflow with a fixed test provider |
| `speech-workflow.json` | `folio-speech-probe` | Synthetic PCM/transcript/handoff cases |
| `audio-ring-sanitizers.json` | `scripts/test-audio-ring.sh` | ASan/UBSan checks on the C audio ring buffer |
| `source-inspection.json` | `tools/package-native.py` | Source hashes and static-analysis results |

`tools/package-native.py` reads these files and will run
`scripts/test-core.sh` automatically when any of them are missing.

## Interpretation

These reports record what was executed on the machine that produced them. They
are not release approval: ASan/UBSan are not ThreadSanitizer, synthetic samples
are not microphone or ASR evaluation, and a Linux core run cannot substitute for
Mac SDK, sandbox, Metal, APFS or independent security review. The current set of
open gates is listed in `docs/progress/PROGRESS.md` and in `Verification.json`
after a packaging run.
