# Increment 09 — honest durability acknowledgement (N01 contract)

## Added

- `VaultDurability` (`Sources/FolioCore/Storage/VaultDurability.swift`): the N01 seven-state acknowledgement model — `notCreated`, `loadedFromDisk`, `editsPending`, `writing`, `durableOnDisk`, `externalConflict`, `failed` — with honest labels, scoped explanations and `acknowledgesDurability` true only after the storage barrier is crossed. Queued or timed work can never be displayed as saved.
- `VaultCheckpointState` and `VaultRemoteState`: the contract's separation axes — `.rdm` archive construction is displayed apart from local durability (a stale archive is never described as up to date), and this build's missing sync is shown explicitly as "Local only — no sync" rather than implied.
- `SaveCoalescing` named, documented measurements: 250 ms edit debounce target and 500 ms bounded maximum delay after the first dirty edit; the docs state plainly that these schedule writes and do not acknowledge them.
- Editor status line now derives from the model (`OpenNoteDocument.durability`) with barrier-scoped help text; the notes status bar shows the remote-state axis. Encrypted workspace shows all three axes (working-copy draft durability, checkpoint state, sync) as one summary line with per-axis explanations, tracks confirmed vs pending working-copy writes with a generation guard so a superseded debounced write cannot confirm newer text, and reports checkpoint failures without discarding drafts.
- "Cancelling creates no file and no hidden draft on disk" is now stated on the new-note sheet (contract state 1).
- 10 focused tests: resolution/precedence matrix, label-honesty rules (only acknowledged states may say "Durable"/"Saved"), scoped explanations, checkpoint/remote separation wording, and measured coalescing bounds including a 40-edit continuous-typing simulation.

## Fixed

- Stale development captions: the launcher no longer calls the encrypted preview "memory-only"/"read-only" or Increment 07, the encrypted landing no longer lists the persistent encrypted index as a future gate, and the unlock notice no longer claims search results are unpersisted.

## Evidence and limits

The recorded full Debug/Release run remains Increment 07's 333 tests with 0 failures. This increment's sources and tests pass full swift-syntax parsing (110 Swift files, 0 syntax failures); the 10 new tests must run via `bash scripts/test-core.sh` in a Swift-capable environment before they count as evidence. The storage barrier's APFS/power-loss behaviour remains unverified on Mac. This is not safe for sensitive data or release; plain-vault data remains plaintext.

---

# Increment 08 — persistent encrypted working storage

## Added

- `RDMWorkingStore`: unsaved encrypted-project drafts persist locally as two alternating AES-256-GCM sealed slot records (`.folio/<name>.rdmworking.0/1`) chained by generation and previous-record digest, written through the atomic `.folio` staging path with no plaintext residue.
- Fail-closed restore classification (`.empty` / `.current` / `.stale`): torn writes, missing history, single-slot rollback, mixed epochs and unauthenticated copies surface for explicit review and block further draft writes until a reviewed `resolve()` re-anchors a fresh epoch; set-aside bytes are preserved as private `.folio` copies rather than destroyed.
- Encrypted derived-index cache (`.folio/<name>.rdmindex`) bound to its archive snapshot; cache hits warm the search index on open, and every cache failure mode falls back to the in-memory rebuild without affecting search correctness.
- `RDMProjectSession` working-state API (`restoreWorkingState`, `stageDraft`, `discardDraft`, `resolveWorkingState`) with checkpoint-first, cache-second ordering.
- Native encrypted UI: 250 ms debounced draft staging into the encrypted working copy, restore of the most recent unsaved draft after unlock, local-draft discard after a successful checkpoint, an explicit "Review local working copies" action, and captions that describe the real draft/index behaviour.
- Focused tests for chaining/round trip, the stale-detection matrix, reviewed resolution with byte preservation, draft bounds/validation, plaintext canaries, index-cache round trip/corruption/snapshot binding, and session-level draft survive-close/reopen, discard, stale-block and cache fallback scenarios.

## Evidence and limits

The recorded full Debug/Release run remains Increment 07's 333 tests with 0 failures. This increment's sources and tests pass full swift-syntax parsing (108 Swift files, 0 syntax failures); the new test executions must run via `bash scripts/test-core.sh` in a Swift-capable environment before they count as evidence. Mac SDK/CryptoKit/APFS, power-loss, Keychain, accessibility and independent security evidence remain blocked. This is not safe for sensitive data or release; plain-vault data remains plaintext.

---

# Increment 07 — encrypted `.rdm` foundation

## Added

- Pinned upstream Argon2id source with provenance/license notice and fixed bounded compatibility profile.
- Protected secret allocation/zeroing, AES-256-GCM/HKDF primitives and known-answer tests.
- Strict ZIP64 encrypted manifest/object envelope; no plaintext member names/content except the bounded clear header.
- Passphrase/recovery credential slots, authenticated object/manifest AAD, fresh snapshot/object revisions and parent lineage.
- Atomic `.rdm` file creation/checkpoint/open with lock and stale external-head protection.
- Bounded memory-only encrypted working index with close/delete erasure and no persistent plaintext cache/WAL.
- 56 passing encrypted primitive/archive/checkpoint/working-index/hostile-input/session tests; license/protocol contract retained.
- Encrypted project session and native encrypted-project preview/editor source with explicit recovery review, lock/close erasure, new-note creation, reviewed checkpoint-draft flow and non-destructive plain-to-encrypted-copy preparation with progress, cancellation and source-preservation failure handling.
- Encrypted archive creation now refuses any existing destination and has a regression test proving the sentinel bytes remain unchanged.
- Recorded full Debug/Release core runs at 333 tests with 0 failures.

## Still blocked

CryptoKit/Mac SDK parity, Keychain/device slots, persistent encrypted working/index/cache, hostile-input/fault coverage, APFS/power-loss, migrations, independent security review and native encrypted workspace UI. This is not safe for sensitive data or release. Existing plain-vault data remains plaintext.

---

# Increment 06 — explicit on-device voice capture

## Added

- Separate asset-download and Record/microphone consent, project/capture-bound voice state and explicit stop/finalization acknowledgement.
- Bounded transcript assembly, provisional/final handling, correction, partial-warning approval and stale-safe handoff to Capture.
- Preallocated SPSC PCM queue with overflow/format/reentrancy guards and stopped-buffer clearing.
- Native macOS-26 AVAudioEngine/SpeechAnalyzer/SpeechTranscriber source; bounded conversion/input streaming, lifecycle observers and teardown.
- Recorder/review UI, visible microphone indicator, purpose string and audio-input entitlement. No cloud fallback or raw recording file store.
- Synthetic speech workflow and ASan/UBSan C queue harness; referenced Apple sample license preserved.

## Evidence and remaining gates

277 unit tests pass in Debug/Release on Linux; 69 workflow/process scenarios and 6 separate audio sanitizer checks pass. No actual Mac microphone/recognition/teardown or live model evaluation ran. Native SDK, privacy, accuracy, real-time performance and independent review remain blocked.

The weighted estimate is 40%, not a security score. Owner testing remains held. No percentage increase waives a blocker.

---

# Increment 05 — explicit-context capture and review

## Added and checked

- Frozen context selection, transcript confirmation and profile-bounded request preparation.
- A text-only broker with single-operation ownership, deadline/cancellation handling and rejected late results.
- Whole-draft/section/line-change review, bound selections, Unicode/front-matter protections, fresh approvals after rebase/edit, and stale-safe apply/undo plans.
- A deterministic 250-case diff reconstruction corpus plus provider, scope, selection and cancellation tests.
- Native composer/review/editor-transaction source and an Apple on-device provider adapter with no tools or cloud fallback.
- A generated capture-to-storage probe clearly labelled as a fixed provider fixture, not LLM execution.
- A weighted progress ledger: 38% estimated implementation/planning completion, with release/security readiness still blocked.

## Evidence and limits

235 unit tests pass in Debug/Release on Linux. 57 generated workflow/process checks pass, including 11 capture checks. Native SDK/LLM/editor behaviour is unverified. No speech recording, encrypted `.rdm`, collaboration or installer/update release is claimed. Prompt/data separation is not a claim of perfect prompt-injection resistance.

The owner's requirement remains: no rushed work, and no owner testing before the approved feature set and mandatory gates are complete.

---

# Increment 04 — linked planning and connections

## Added

- Date-only task/milestone model, Timeline/Unscheduled/Kanban projections, stable note links and dependency graph.
- Explicit proposal validation/repair, bulk moves, ordering, deletion and session undo/redo with fresh revisions and content checks.
- Versioned roadmap persistence inside the vault actor, sealed transactions, conflicts and crash recovery.
- Shared authored-link graph, missing-link disclosure, one/two-hop scope, bounded clustering, deterministic layout, picking and opt-in 3D projection.
- Native planning, task editing, dependency inspection, graph/list/selection source and MetalKit on-demand rendering with separate in-flight vertex buffers.
- New typed commands and generated planning/SIGKILL probes.

## Verified here

180 tests in Debug and Release on Linux; 13 note-process, 12 roadmap-process, 11 reading and 10 planning/graph workflow checks. Mac source is syntax-parsed, not SDK/GPU/runtime tested.

## Delivery and cleanup

Owner testing is held until the approved Mac feature set and mandatory engineering gates are complete. Historical duplicate exports, obsolete tooling and old incremental ZIPs were removed; one current `Folio-Source.zip` replaces the archive pile. Source, all 50 decisions, useful evidence/design references and the unchanged logo were preserved.

AI/speech, encryption/container, collaboration, installer/updater and native/security validation remain unfinished. This is not a released or feature-complete app.

---

# Increment 03 — reading, search and commands

## Added

- A disposable, workspace-bound SQLite FTS5 cache outside the vault, literal/phrase/prefix queries, title-first ranking, tag scopes and plain-text excerpts.
- Transactionally maintained external-content FTS rows, stale-update reservations, rebuild generations, bounded query work and explicit cache disposal/rebuild.
- Search-resource profiles with actual SQLite page-cache settings.
- Bounded UTF-16-mapped Markdown block/inline parsing and native SwiftUI preview source; explicit Follow cursor and excerpt consent.
- Literal HTML, non-loading image placeholders, safe external-link confirmation, known-note-only wikilinks and ambiguity chooser source.
- A separate typed command palette and remappable Folio shortcuts protecting native editing/system/accessibility chords.
- Source/Preview/Split source layout retaining the native editor, in-note Find wiring and IME provisional-text guards.
- Constant-time note-ID lookup and indexed missing-path rename matching in the vault store.

## Evidence

137 unit tests in Debug and Release, 13 process/storage checks and 11 generated 1,000-note reading-workflow checks. All execution evidence is Linux/core scope. Mac source is syntax-parsed, not SDK-typechecked or runtime-validated.

## Still blocked

Full native UI/input/undo/accessibility and APFS evidence; complete Markdown dialect support; 100k-note/energy/memory/frame budgets; recursive reconciliation; independent security and distribution gates. Graph, planning, AI/speech, encryption/sync and installer/updater are still later work.

Historical source ZIPs were subsequently superseded and removed under the workspace-cleanup request.

---

# Increment 02 — local project storage

## Added

- A real, actor-isolated plain-vault store and bounded POSIX file-I/O layer.
- Explicit project initialisation, stable IDs, note creation/open/save, safe relative path handling and a single-Folio-writer lock.
- Staged journals, flushed payloads, non-clobbering creation and atomic exchange with retained displaced bytes.
- Conflict preservation, review-only drafts, idempotent recovery, committed-history bounds and journal quotas.
- Byte-preserving UTF-8 import, unknown-schema rejection, read-only protection and supported file-metadata copying.
- Native folder-picker/grant integration, project explorer, bounded autosave, explicit Save, conflict/recovery views and save-aware quit source.
- Active-file/parent observation; filename picker/filter; source-selection retention and external-reload undo resets.
- A developer storage probe, reproducible core test scripts and real process-kill tests.

## Verified in this environment

- Swift 6.0.3 Linux compilation of the core, C I/O target and probe.
- 73 unit tests in both Debug and Release configurations; 13 process/storage scenarios.
- C compiler warning/static-analysis checks and syntax parsing of the Mac Swift source.
- Approved logo identity unchanged.

## Important fixes while building

- Async XCTest discovery now uses stateless test containers compatible with Linux Swift 6; the production actor boundaries remain intact.
- Recovery never automatically overwrites a changed/read-only head, replays a review-only proposal or rolls back a later edit from a committed record.
- Copied projects can quarantine pending old proposals before receiving a new identity.
- New typing after a conflict is preserved before Use Disk Version can discard the editing buffer.
- A changed comparison is presented again before Keep My Text proceeds.
- The autosave path retains a follow-up wakeup if a previous write is still finishing.
- Ownership/mode and supported xattrs/ACLs are copied rather than silently dropped; Linux destination-only inherited xattrs are removed.
- Invalid resource limits and extreme filesystem timestamps are bounded.

## Still not approved for release

The Mac target is not built or runtime-tested. Native IME/undo/accessibility, recursive filesystem reconciliation, APFS barriers/metadata, real power-loss and fault-matrix testing, large-vault performance, security audit, signing/notarization and installer/updater gates are outstanding. Graph/planning/AI/speech/encryption/sync remain unimplemented.

The active `native/` tree is the source of truth; old incremental ZIPs were subsequently superseded and removed under the cleanup request.
