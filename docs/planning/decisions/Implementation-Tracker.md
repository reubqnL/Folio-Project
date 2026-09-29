# Implementation tracker — Increment 09

**Estimated completion: 43% (weighted planning estimate). Release/security readiness: blocked. Owner testing: HOLD.**

All 50 decisions remain authoritative. Every user-facing progress update includes the estimate and completed work; code/test counts do not imply production security.

## Added/tested in the core

- `VaultDurability`: the N01 seven-state durability acknowledgement model (`notCreated`, `loadedFromDisk`, `editsPending`, `writing`, `durableOnDisk`, `externalConflict`, `failed`) with honest labels, scoped explanations and `acknowledgesDurability` true only after the storage barrier (staged-file flush, atomic install, parent-directory flush). Queued/timed work can never be displayed as saved.
- `VaultCheckpointState` / `VaultRemoteState`: contract separation axes — `.rdm` archive construction is shown apart from local durability, and this build's missing sync is explicit ("Local only — no sync") rather than implied.
- `SaveCoalescing` named measurements (250 ms edit debounce target, 500 ms bounded maximum after first dirty) — documented as scheduling values, not acknowledgement promises.
- 10 focused tests: resolution/precedence matrix, label-honesty rules (only acknowledged states may say "Durable"/"Saved"), scoped explanations, checkpoint/remote separation wording, coalescing constants and a 40-edit continuous-typing bound simulation. Suite total is now 366 test functions in source.

## Native source updated; unverified on Mac

- Plain editor status derives from the model (`OpenNoteDocument.durability`) with barrier-scoped help text including the unverified power-loss caveat; the notes status bar shows the sync axis; the new-note sheet states that cancelling creates no file and no hidden draft.
- Encrypted workspace shows the three axes as one summary (working-copy draft durability with confirmed/pending/editor-only states, generation-guarded so a superseded debounced write cannot confirm newer text; checkpoint state including failed-without-discard; no sync).
- Fixed stale captions (launcher increment/memory-only/read-only wording, encrypted landing gate list, unlock notice). No SwiftUI/AppKit compile of these changes has run in this environment.

## Current evidence and limits

- **The recorded full Debug/Release run remains Increment 07's 333 tests with 0 failures.** This increment's sources and tests pass full swift-syntax parsing (110 Swift files, 0 syntax failures).
- This development environment cannot install a Swift toolchain (network policy), so the new tests have not been executed here. They must pass `bash scripts/test-core.sh` in a Swift-capable environment before they count as evidence; unrun evidence is blocking, not a pass.
- The storage barrier's APFS/power-loss behaviour is unverified; the labels claim exactly the fsync/exchange/parent-flush barrier and no more.
- **No real microphone, recognition accuracy, AVFoundation/TCC lifecycle, live LLM, Metal, AppKit, APFS, accessibility/performance or independent security approval has run here.**

## Remaining before owner handoff

Actual Mac compilation and device/API/fault/privacy validation; execution of the new working-store test suite in CI; live speech/model quality and resource evidence; editor/undo/accessibility and large-vault gates; encrypted native workspace/keychain/recovery UX completion; fault/power-loss coverage for the working slots and checkpoints; CRDT/MLS collaboration; signing/notarization, installer/updater/migrations; and independent security review.

Current plain-vault data remains plaintext. Deferred FolioDev/Windows/Android scope is unchanged. Do not ask the owner to test an incomplete build or waive a blocker to raise the percentage.
