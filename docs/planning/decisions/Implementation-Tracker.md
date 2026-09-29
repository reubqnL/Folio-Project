# Implementation tracker — Increment 12

**Estimated completion: 46% (weighted planning estimate). Release/security readiness: blocked. Owner testing: HOLD.**

All 50 decisions remain authoritative. Every user-facing progress update includes the estimate and completed work; code/test counts do not imply production security.

## Added/tested in the core

- `BenchmarkCorpora`/`BenchmarkStatistics` + `FolioBenchmarkProbe` (N02 "large-file/long-line benchmarks"; decision 26 / gate `inputAndLargeDocumentCorrectness`): deterministic named corpora sized against `MarkdownLimits` and measured editor-critical paths (full parse, per-keystroke incremental reparse including a splice-only figure, link scan, excerpt) with median/p95/min, table or JSON output. Timings are printed and never asserted (decision 50 — no waiver path); they become evidence only when recorded on the release machine via `scripts/run-benchmarks.sh`.
- 9 focused tests: corpus determinism and unique edit markers, budget targeting (near/over the parse cap, line cap), parse outcomes including the limitation path, incremental-vs-full parse equality on every corpus, link-scan span round-trips, statistics definitions (median odd/even, nearest-rank p95, empty input). Suite total is now 421 test functions in source.

## Native source updated; unverified on Mac

- `MarkdownPreviewView` keeps one session per document and preview mode, runs `reparse` on a detached task, and rebuilds the session when excerpt mode toggles or the document changes. No SwiftUI/AppKit compile of these changes has run in this environment.

## Current evidence and limits

- First Mac build attempt (Swift 6.3.2 / macOS 26 / Xcode 26) reached compilation and failed only on missing libarchive headers (macOS ships the compiled system library without headers). Fixed by vendoring a declaration-verbatim subset of the libarchive 3.7.7 public headers (`Sources/FolioRDMPrimitives/vendor/libarchive/`, BSD-2-Clause) and linking the system library. Release-track note: Mac App Store distribution would require a statically linked libarchive instead (App Review flags system-libarchive references); direct distribution is unaffected.
- **The recorded full Debug/Release run remains Increment 07's 333 tests with 0 failures.** This increment's sources and tests pass full swift-syntax parsing (118 Swift files, 0 syntax failures).
- The Increment 10 reparse algorithm additionally survived 32,000 randomized edit-sequence equivalence checks via an out-of-repository Python mirror of the same algorithm — design evidence only; the harness is not shipped and does not replace the Swift run.
- This development environment cannot install a Swift toolchain (network policy), so the new tests have not been executed here. They must pass `bash scripts/test-core.sh` in a Swift-capable environment before they count as evidence; unrun evidence is blocking, not a pass.
- The storage barrier's APFS/power-loss behaviour is unverified; the labels claim exactly the fsync/exchange/parent-flush barrier and no more.
- **No real microphone, recognition accuracy, AVFoundation/TCC lifecycle, live LLM, Metal, AppKit, APFS, accessibility/performance or independent security approval has run here.**

## Remaining before owner handoff

Actual Mac compilation and device/API/fault/privacy validation; execution of the new working-store test suite in CI; live speech/model quality and resource evidence; editor/undo/accessibility and large-vault gates; encrypted native workspace/keychain/recovery UX completion; fault/power-loss coverage for the working slots and checkpoints; CRDT/MLS collaboration; signing/notarization, installer/updater/migrations; and independent security review.

Current plain-vault data remains plaintext. Deferred FolioDev/Windows/Android scope is unchanged. Do not ask the owner to test an incomplete build or waive a blocker to raise the percentage.
