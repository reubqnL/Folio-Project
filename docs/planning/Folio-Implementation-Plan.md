# Folio — implementation plan after your 50 answers

**Current stage: Increment 08 — persistent encrypted working storage · Estimated completion: 42% · Owner testing: on hold · Release: blocked**

Your personal answers are the product authority. They override conflicting defaults in the September 2026 baseline. The original baseline PDF, roadmap workbook and browser concept remain reference snapshots, not the current implementation or proof of working native features.

- Exact answers: `decisions/answers.json`
- Human-readable decisions: `decisions/User-Decisions.md`
- Honest implementation status: `decisions/Implementation-Tracker.md`
- Native application source: `App/` (macOS app), `Sources/` and `Tests/` (Swift/C core), with
  `Package.swift` and `project.yml` at the repository root
- Mac build instructions: `../native-development.md`

## 1. Scope now locked

| Area | Your decision |
|---|---|
| Platform sequencing | Finish and secure the native Mac product first. **No Windows toolkit evaluation or implementation before the Mac security-readiness gate and native phases are complete.** |
| Launcher | Always show the launcher. FolioNotes left and active; FolioDev right, visibly disabled in the initial phases. |
| Organisation | Project spaces first. Underlying Markdown file locations remain intact; grouping does not silently move files. |
| Editor | Writing space wins as windows narrow. Ask for title and location before creating a note. Preserve the source cursor; move the preview through an explicit Follow cursor control. |
| Paste | Convert supported formatting, disclose losses in a non-blocking notice and offer Undo. |
| AI and voice | Review the transcript first. Let users choose whole-draft, section or detailed-comparison approval. Show included context persistently. Compare stale results against current writing. |
| Graph | **2D by default; 3D remains opt-in.** One-hop initial scope, graph/list toggle, expandable clusters and inspect-before-open. |
| Planning | Timeline first, with an Unscheduled tray. Visible Move/bulk actions and guided, approved dependency repair. |
| Accessibility | Follow macOS contrast/motion settings, allow editor text-size adjustment, and allow Folio command remapping without disrupting native editing shortcuts. |
| Search | One note/title/content search surface plus a separate command palette. English/general-note relevance first. |
| Performance | Balanced, Low-memory and Large-vault profiles. Adaptive graph caps, CPU layout and Metal drawing initially. Input correctness **and** large-document performance block release. |
| Durability | Brief, bounded save batching around 250 ms. Never show a durable-save acknowledgement before the actual barrier succeeds. |
| Encrypted projects | Separate local durability, archive checkpoint and remote sync states. Keep safe archive snapshots, less frequent for large projects. Portable reviewed Argon2id policy, user-held recovery key and trusted-device enrolment. |
| Collaboration | Long-offline correctness is the priority evaluation case. Revoked edits may become owner-reviewed import proposals, not accepted old-epoch operations. Suspicious sync history creates a recoverable local branch while sync is paused. |
| Metadata | Protect content and disclose remaining metadata; extra traffic-padding modes are not initial approved scope. |
| FolioDev later | Introduce it when actually available, request repository access, and start with read-only source linking/preview. No initial language-server processes or executable tools. |
| Android later | **Read-only for this roadmap.** Editing would need a separately approved future scope. |
| Release authority | **No exceptions to defined release blockers.** Missing or unrun evidence is blocking, not a pass. |

## 2. Current build — Increment 10

The encrypted project foundation is now implemented as a separate, bounded subsystem, and Increment 08 adds persistent encrypted working storage on top of it:

- Pinned Argon2id v1.3 source/provenance, bounded passphrase KDF and protected secret handle.
- AES-256-GCM/HKDF adapters, domain-separated keys/AAD, fresh revisions/nonces and recovery/passphrase slots.
- Strict ZIP64 transport allow-list, encrypted manifest/object records, canonical schema validation and no filesystem extraction.
- Atomic encrypted `.rdm` checkpoint store with parent lineage, stale external-head refusal and lock ownership.
- Recovery/passphrase open, rewrap semantics and strict malformed/tampered/transplant/resource tests.
- Increment 08: persistent encrypted working storage — chained two-slot draft records with fail-closed stale classification and reviewed resolution, an encrypted derived-index cache bound to its archive snapshot, session draft APIs and native draft staging/restore/review wiring.
- Increment 09: honest durability acknowledgement (N01) — the explicit seven-state `VaultDurability` model with barrier-scoped labels, `VaultCheckpointState`/`VaultRemoteState` separation axes, documented 250/500 ms coalescing measurements, and native status surfaces that cannot display queued or timed work as saved.
- Increment 10: incremental Markdown reparse (N02) — `MarkdownReparseSession` splices only the changed region of the reading preview with parse-equal results and stable untouched block identities, with boundary proofs around the splice and a full-parse fallback whenever equivalence cannot be proven.

The focused encrypted suite has **56 passing tests** from Increment 07 (hostile-input, atomic-rebuild and encrypted-session coverage; primitive known-answer tests include AES-GCM, HKDF and Argon2id), plus **23 working-store/session tests (Increment 08) and 10 durability-model tests (Increment 09) that must still be executed** in a Swift-capable environment before counting as evidence. The full regression/package evidence remains bounded Linux evidence pending Mac validation.

### Non-completion boundary

This is not yet encrypted workspace integration or a security audit. Mac CryptoKit/APFS behavior, Keychain slots, on-demand encrypted object caching/WAL and preview/diagnostic boundaries, migrations, fuzzing, power-loss tests, independent crypto review and native privacy UI completion remain required. Current plain vaults and search caches are still plaintext.

## 3. Ordered native build backlog

These are implementation increments, not promises that a feature exists. Exit evidence, not a date, determines progress.

| ID | Increment | Acceptance evidence before advancing |
|---|---|---|
| N00 | Compile and validate the native foundation | Core tests run on an Apple Silicon Mac; AppKit target compiles; local development signature and sandbox entitlement are inspected; manual input, undo, paste, resizing, settings and launcher checks pass. |
| N01 | Project-first local vault service | Explicit user-selected root and scoped permissions; title/location confirmation; stable note identities; no front-matter rewriting; recoverable journal and bounded saves; collision-safe creation; external-edit reconciliation; permission-loss and disk-full states. No reassuring Saved label before tested durability. |
| N02 | Production editor and navigation | Correct IME, emoji, bidirectional text, selection and per-document undo; large-file/long-line benchmarks; incremental parsing rather than whole-document work per keystroke; Source/Preview/Split with explicit Follow cursor; unified note search, separate command palette, compact link repair and safe command remapping. |
| N03 | Roadmap domain and Timeline | One canonical entity model shared with Kanban and notes; date-only semantics; explicit unscheduled items; non-drag movement; reversible bulk changes; cycle detection and guided repair with an impact preview. |
| N04 | Metal graph | 2D default and opt-in 3D; one-hop scope; background CPU layout; adaptive clustering and labelled counts; graph/list equivalence; inspect/open separation; on-demand rendering; no continuous idle or hidden-window rendering. |
| N05 | Local capture and intelligence | Availability-aware Apple speech/model adapters; transcript approval before restructuring; explicit context list; chosen review granularity; revision-aware proposals; cancellation and bounded resource use. Unsupported speech retains text entry—no silent alternate engine or cloud upload. |
| N06 | Encrypted `.rdm` projects | Versioned bounded parser; reviewed cryptographic libraries; authenticated immutable objects/manifests; safe nonces and key lifecycle; encrypted working store and caches; independent atomic archive checkpoints; recovery/enrolment flows; corruption, malicious-header, plaintext-residue, free-space and crash tests. |
| N07 | Mac release and distribution | Native `.pkg` pipeline; correct application and installer identities; notarization/stapling; installer/uninstaller review; dependency provenance; safe update rollback and migrations; accessibility and performance evidence; independent security review and closure of blockers. |

### N01 durability contract — model implemented in Increment 09

1. **Not created:** cancelling the title/location sheet creates no file and no hidden draft on disk.
2. **Editing / saving:** the UI may show pending work, but cannot call it durable simply because a timer fired or a write was queued.
3. **Locally durable:** an acknowledged transaction has crossed the specified storage barrier under the tested filesystem fault model.
4. **Checkpoint pending/current:** `.rdm` archive construction is separate from local durability; a stale archive is not described as up to date.
5. **Remote state:** uploading or synchronising is separate again. A server receipt is not proof that every offline collaborator has received the change.
6. **External conflict:** safe external changes reload; concurrent local changes retain a base and both conflicting versions. Cooperating and non-cooperating external writers must be tested, with limitations documented rather than hidden.
7. **Failure:** permission loss, full disk, cancellation and interrupted migration produce actionable errors without overwriting the last known good state.

The 250 ms value is a coalescing target, not a promise that suspended hardware or failing storage can acknowledge every edit in 250 ms. A bounded maximum delay, filesystem semantics and the displayed acknowledgement must be measured and documented.

**Status:** the seven states are implemented as `VaultDurability` / `VaultCheckpointState` / `VaultRemoteState` with honest labels and help text; the coalescing bounds (250 ms target, 500 ms bounded maximum) are named measurements in `SaveCoalescing`; the filesystem semantics and label claims are documented in `docs/architecture/STORAGE-CONTRACT.md`. Verification of the barrier under real fault/power-loss conditions remains an exit gate (N00/N07 evidence), not a claim.

## 4. Later native work and platform holds

### Native Phase 2

Continue Mac depth, recovery and hardening. Evaluate collaboration against weeks-offline histories, bounded metadata growth, undo correctness and compaction. Enforce membership/revocation order, isolate rejected changes as owner-reviewed proposals, and keep a local branch when relay history is suspicious.

A shared-core extraction strategy is **not yet chosen**: your answer to question 27 set the Mac-first security condition rather than approving a particular Rust migration. Do not interpret that answer as permission to launch a parallel Windows workstream.

### Windows

**On hold, including toolkit evaluation.** The baseline's Tauri preference is no longer an approved implementation choice. Reopen the toolkit decision only after the native phases and Mac security-readiness gates are satisfied. No Tauri, Flutter or WinUI implementation has been created.

### FolioDev

Its initial card stays disabled. The eventual module is introduced deliberately and begins read-only, with repository permission requested explicitly. Broader code execution, LSP processes and developer helpers need a separate privilege review and approved later scope.

### Android

Read-only access and viewing only for this roadmap, after the preceding platform gates. Remove the original tentative light-editing expansion from current scope. Android still needs key-loss, storage-provider and process-death tests for safe viewing/cache behaviour; editing would require a new decision and stronger durability evidence.

## 5. Define “Mac secured” through evidence

This is a release-readiness condition, **not a claim of absolute security or zero future vulnerabilities**. Before lifting the platform hold:

- The release threat model and supported OS/filesystem/hardware assumptions are explicit.
- Native input, large-vault, accessibility, energy and memory gates have reproducible results on the supported hardware.
- Acknowledged edits survive the defined crash/fault matrix; recovery and migration preserve the last known good data.
- Encrypted projects use reviewed implementations and pass format, key-management, malicious-input and plaintext-residue tests.
- Appropriate independent security review is complete, with no unresolved critical/high findings in release scope.
- Dependencies and build provenance are recorded; the actual distributed app/installer is correctly signed, notarized and stapled.
- Update/migration rollback is demonstrated, not merely described.
- Native Phase 2 completion and the relevant collaboration/security gates are explicitly recorded.
- Every defined blocker is resolved. There is no waiver path that turns missing evidence into a pass.

Local ad-hoc signing for a development build is not Developer ID distribution approval, notarization or an independent audit.

## 6. Immediate handoff

On an **Apple Silicon Mac with macOS 26+ and Xcode 26+**, install XcodeGen if needed, then follow `../native-development.md`. The script runs core tests, generates the Xcode project, builds a locally ad-hoc-signed Debug app and checks for the sandbox entitlement. It has not been run in this Linux environment.

The first real Mac compile/runtime check remains an internal engineering prerequisite, not a request for owner testing. Continue to complete the approved feature set and all mandatory evidence before the owner handoff. Linux core tests cannot substitute for Mac, distribution or security review.
