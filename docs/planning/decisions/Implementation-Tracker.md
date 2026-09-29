# Implementation tracker — Increment 10

**Estimated completion: 44% (weighted planning estimate). Release/security readiness: blocked. Owner testing: HOLD.**

All 50 decisions remain authoritative. Every user-facing progress update includes the estimate and completed work; code/test counts do not imply production security.

## Added/tested in the core

- `MarkdownReparseSession` (N02 incremental Markdown reparse): the reading preview splices only the changed region of a note per keystroke — line-level diff, bounded reparse window, blocks outside it reused with exact spans, content+occurrence identities and merged warnings. The result is always parse-equal to `MarkdownParser.parse` on the same source; every unprovable case falls back to a full parse.
- Boundary proofs around the splice: 2-line lookahead window floor (setext underlines, table alignment rows), window-EOF proofs (`rule`/`listItem` can pair with a suffix line; blank-extension; fence-close scan), straddle growth so no old block tail is dropped, front-matter scan treated as document-wide (edits in the first 129 lines reparse from line 0; mid-document windows can never form metadata blocks), and metadata blocks never reused on the suffix side.
- `MarkdownParser` internals restructured for the splice (`parseDetailed`/`project`/`splitLines`) with byte-identical public `parse`/`excerpt` output.
- 23 focused tests: adversarial splice swallows, unclosed/closing fences, setext partner changes across the splice, front-matter formation/removal/instability regressions, the two-line lookahead hazard, edit-then-undo, duplicate-block renumbering, untouched-block id stability, empty/CRLF/emoji sources, budget fallbacks and a 4,000-block metrics bound. Suite total is now 389 test functions in source.

## Native source updated; unverified on Mac

- `MarkdownPreviewView` keeps one session per document and preview mode, runs `reparse` on a detached task, and rebuilds the session when excerpt mode toggles or the document changes. No SwiftUI/AppKit compile of these changes has run in this environment.

## Current evidence and limits

- **The recorded full Debug/Release run remains Increment 07's 333 tests with 0 failures.** This increment's sources and tests pass full swift-syntax parsing (112 Swift files, 0 syntax failures).
- The reparse algorithm additionally survived 32,000 randomized edit-sequence equivalence checks via an out-of-repository Python mirror of the same algorithm — design evidence only; the harness is not shipped and does not replace the Swift run.
- This development environment cannot install a Swift toolchain (network policy), so the new tests have not been executed here. They must pass `bash scripts/test-core.sh` in a Swift-capable environment before they count as evidence; unrun evidence is blocking, not a pass.
- The storage barrier's APFS/power-loss behaviour is unverified; the labels claim exactly the fsync/exchange/parent-flush barrier and no more.
- **No real microphone, recognition accuracy, AVFoundation/TCC lifecycle, live LLM, Metal, AppKit, APFS, accessibility/performance or independent security approval has run here.**

## Remaining before owner handoff

Actual Mac compilation and device/API/fault/privacy validation; execution of the new working-store test suite in CI; live speech/model quality and resource evidence; editor/undo/accessibility and large-vault gates; encrypted native workspace/keychain/recovery UX completion; fault/power-loss coverage for the working slots and checkpoints; CRDT/MLS collaboration; signing/notarization, installer/updater/migrations; and independent security review.

Current plain-vault data remains plaintext. Deferred FolioDev/Windows/Android scope is unchanged. Do not ask the owner to test an incomplete build or waive a blocker to raise the percentage.
