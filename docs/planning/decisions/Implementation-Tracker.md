# Implementation tracker — Increment 11

**Estimated completion: 45% (weighted planning estimate). Release/security readiness: blocked. Owner testing: HOLD.**

All 50 decisions remain authoritative. Every user-facing progress update includes the estimate and completed work; code/test counts do not imply production security.

## Added/tested in the core

- `NoteLinkRepair` (N02 compact link repair; baseline §4.2, decision 12): broken and ambiguous note links are visible and repairable. A span-preserving scanner recognises authored note links with exactly `MarkdownInlineParser`/`GraphLinkExtractor` semantics (pinned by equivalence tests) and records exact target spans; only verbatim-round-tripping targets are rewritable.
- Confirmed single-link rewrites: labels and `|alias` survive, `#section` anchors and authored form (title vs path) are preserved, every edit is digest-bound to its source (stale application refuses) and blocked if the replacement would not re-parse as a note link at the same site. The original link is kept until the replacement is confirmed; refusals never change the note.
- 24 focused tests: scanner/parser/graph equivalence over an adversarial corpus, block-kind and table-cell policy (including the pipe-split and escaped-pipe behaviours), CRLF/emoji span round-trips, resolution inspection, form-preserving replacement text, single-occurrence rewrites, stale/span/blocked refusals, and the `repairLinks` command's reachability and note scoping. Suite total is now 412 test functions in source.

## Native source updated; unverified on Mac

- `MarkdownPreviewView` keeps one session per document and preview mode, runs `reparse` on a detached task, and rebuilds the session when excerpt mode toggles or the document changes. No SwiftUI/AppKit compile of these changes has run in this environment.

## Current evidence and limits

- **The recorded full Debug/Release run remains Increment 07's 333 tests with 0 failures.** This increment's sources and tests pass full swift-syntax parsing (115 Swift files, 0 syntax failures).
- The Increment 10 reparse algorithm additionally survived 32,000 randomized edit-sequence equivalence checks via an out-of-repository Python mirror of the same algorithm — design evidence only; the harness is not shipped and does not replace the Swift run.
- This development environment cannot install a Swift toolchain (network policy), so the new tests have not been executed here. They must pass `bash scripts/test-core.sh` in a Swift-capable environment before they count as evidence; unrun evidence is blocking, not a pass.
- The storage barrier's APFS/power-loss behaviour is unverified; the labels claim exactly the fsync/exchange/parent-flush barrier and no more.
- **No real microphone, recognition accuracy, AVFoundation/TCC lifecycle, live LLM, Metal, AppKit, APFS, accessibility/performance or independent security approval has run here.**

## Remaining before owner handoff

Actual Mac compilation and device/API/fault/privacy validation; execution of the new working-store test suite in CI; live speech/model quality and resource evidence; editor/undo/accessibility and large-vault gates; encrypted native workspace/keychain/recovery UX completion; fault/power-loss coverage for the working slots and checkpoints; CRDT/MLS collaboration; signing/notarization, installer/updater/migrations; and independent security review.

Current plain-vault data remains plaintext. Deferred FolioDev/Windows/Android scope is unchanged. Do not ask the owner to test an incomplete build or waive a blocker to raise the percentage.
