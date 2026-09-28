# Implementation tracker — Increment 07

**Estimated completion: 41% (weighted planning estimate). Release/security readiness: blocked. Owner testing: HOLD.**

All 50 decisions remain authoritative. Every user-facing progress update includes the estimate and completed work; code/test counts do not imply production security.

## Added/tested in the core

- Authenticated `.rdm` envelope with pinned Argon2id v1.3, AES-256-GCM/HKDF adapters, strict ZIP64 member bounds and encrypted manifest/object records.
- Passphrase and recovery-code credential slots, fresh snapshot/object revisions, parent lineage, atomic checkpoint writes and stale external-head refusal.
- Memory-only bounded derived index for encrypted projects; no SQLite file, WAL, temp file or persistent plaintext search cache is created by this component.
- **333 unit tests pass in the Debug and Release Linux runs**, including **56 focused encrypted archive/crypto/checkpoint/working-index/hostile-input/session tests**.
- Existing workflow/process checks, static analysis and separate audio sanitizer evidence remain retained.
- Encrypted creation now rejects an existing destination instead of exchanging over it; the original sentinel is asserted unchanged by a focused regression test.

## Native source added; unverified on Mac

- AVAudioEngine input, SpeechTranscriber/SpeechAnalyzer, AssetInventory ownership checks and bounded conversion/delivery.
- Explicit Record/download controls, microphone indicator, transcript correction and stop-on-interruption paths.
- Encrypted project UI/keychain/recovery integration is not complete; the working index is intentionally memory-only until persistent encrypted storage is designed and reviewed.
- Audio-input entitlement and clear microphone usage description; no cloud-recognizer fallback or raw audio file recording.

## Current evidence and limits

- Debug/Release logs show 333 tests with 0 failures.
- **No real microphone, recognition accuracy, AVFoundation/TCC lifecycle, live LLM, Metal, AppKit, APFS, accessibility/performance or independent security approval has run here.**
- Mac Swift source is syntax-parsed only; no `.app` or `.pkg` was built.

## Remaining before owner handoff

Actual Mac compilation and device/API/fault/privacy validation; live speech/model quality and resource evidence; editor/undo/accessibility and large-vault gates; encrypted native workspace/keychain/recovery UX; persistent encrypted working storage; fault/power-loss coverage; CRDT/MLS collaboration; signing/notarization, installer/updater/migrations; and independent security review.

Current plain-vault data remains plaintext. Deferred FolioDev/Windows/Android scope is unchanged. Do not ask the owner to test an incomplete build or waive a blocker to raise the percentage.
