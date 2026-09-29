# Implementation tracker — Increment 08

**Estimated completion: 42% (weighted planning estimate). Release/security readiness: blocked. Owner testing: HOLD.**

All 50 decisions remain authoritative. Every user-facing progress update includes the estimate and completed work; code/test counts do not imply production security.

## Added/tested in the core

- `RDMWorkingStore`: persistent encrypted working storage for open `.rdm` projects. Unsaved drafts are sealed (AES-256-GCM, domain-separated HKDF key/AAD) into two alternating slot records chained by generation and previous-record digest; writes use the existing atomic `.folio` staging path; no plaintext draft/index bytes leave the process.
- Fail-closed restore classification (`.empty` / `.current` / `.stale`): torn writes, missing history slots, single-slot rollback that breaks the chain, mixed epochs and unauthenticated copies surface as stale review items; draft writes refuse (`recoveryRequired`) until `resolve()` explicitly re-anchors a fresh epoch after preserving the set-aside bytes privately.
- Encrypted derived-index cache bound to its archive snapshot (`FRX1` record). Cache hits skip the in-memory rebuild; every cache failure mode falls back to the full rebuild from the authenticated project and cannot corrupt search.
- `RDMProjectSession` working-state API (`restoreWorkingState`, `stageDraft`, `discardDraft`, `resolveWorkingState`) plus checkpoint-then-cache ordering; `EncryptedWorkingIndex.rebuild(notes:)` supports validated cache restore.
- New focused tests (working-store round trip/chaining, stale detection matrix, reviewed resolution with byte preservation, draft bounds/validation, plaintext-canary scan, index-cache round trip/corruption/snapshot binding, session draft survive-close/reopen, discard, stale-block, cache refresh and fallback).

## Native source updated; unverified on Mac

- The encrypted project UI debounces draft edits into the encrypted local working copy (250 ms coalescing), restores the most recent unsaved draft on unlock, discards the local draft after a successful checkpoint, and exposes an explicit "Review local working copies" resolution action; in-app captions now describe the real draft/index behaviour.
- No SwiftUI/AppKit compile of these changes has run in this environment.

## Current evidence and limits

- **The recorded full Debug/Release run remains Increment 07's 333 tests with 0 failures.** This increment's sources and tests pass full swift-syntax parsing (108 Swift files, 0 syntax failures).
- This development environment cannot install a Swift toolchain (network policy), so the new tests have not been executed here. They must pass `bash scripts/test-core.sh` in a Swift-capable environment before they count as evidence; unrun evidence is blocking, not a pass.
- **No real microphone, recognition accuracy, AVFoundation/TCC lifecycle, live LLM, Metal, AppKit, APFS, accessibility/performance or independent security approval has run here.**

## Remaining before owner handoff

Actual Mac compilation and device/API/fault/privacy validation; execution of the new working-store test suite in CI; live speech/model quality and resource evidence; editor/undo/accessibility and large-vault gates; encrypted native workspace/keychain/recovery UX completion; fault/power-loss coverage for the working slots and checkpoints; CRDT/MLS collaboration; signing/notarization, installer/updater/migrations; and independent security review.

Current plain-vault data remains plaintext. Deferred FolioDev/Windows/Android scope is unchanged. Do not ask the owner to test an incomplete build or waive a blocker to raise the percentage.
