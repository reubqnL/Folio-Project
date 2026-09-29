# Folio — active native development source

> **Where things live.** This document was `native/README.md`. The Swift package
> now sits at the repository root (`Package.swift`, `Sources/`, `Tests/`, `App/`),
> so commands below are run from the repository root unless stated otherwise, and
> relative links are relative to `docs/`. See the root `README.md` for the map.

**Increment 07 · Estimated completion: 41% of approved Mac scope · Release: blocked · Owner testing: HOLD**

The percentage is a weighted planning estimate, not measured security or correctness. The owner's requirement remains careful construction and a feature-complete handoff before their testing. See `progress/PROGRESS.md`.

## Added this increment

- Scope-bound speech consent/lifecycle/transcript policy and exact reviewed handoff into Capture.
- Separate capability checks, explicit language-asset download and explicit Record/microphone permission.
- Bounded preallocated PCM transport; overflow/invalid audio is signalled, not silently dropped.
- Stop/cancel/finalization acknowledgements, late-event rejection, partial-result warnings and manual correction.
- Native AVAudioEngine/SpeechTranscriber/SpeechAnalyzer source, bounded conversion/streaming and guarded teardown.
- Recorder/review UI source, visible microphone state and stop paths for closing, app inactivity, sleep, permission/device changes and duration limits.
- Microphone purpose string/audio-input entitlement; no app networking entitlement or cloud-recognizer fallback.
- Synthetic PCM/lifecycle workflow and a C sanitizer/concurrency harness.

**No real microphone or SpeechAnalyzer execution took place here.** The new Mac source has not been SDK-typechecked or run, and transcription accuracy, conversion/tap semantics, TCC, device interruptions and real-time behaviour remain open gates.

## Evidence obtained on Linux

- **333 core XCTest cases pass in Debug and Release on the recorded Linux runs.** Increment 08 adds 23 focused working-store/session tests (356 total) whose execution still has to run on a Swift toolchain before counting as evidence.
- **69 generated workflow/process scenarios pass:** 13 note storage, 12 roadmap storage, 11 reading, 10 planning/graph, 11 capture/storage and 12 synthetic speech/handoff.
- **6 separate C audio-ring checks pass with AddressSanitizer and UndefinedBehaviorSanitizer**, including 100,000 accepted threaded frames.
- C warning/static-analysis checks cover Linux sources. Mac Swift is syntax-parsed only.

Synthetic samples/transcript events and a fixed test model are not microphone/ASR/LLM evaluation. ASan/UBSan are not ThreadSanitizer or independent proof of race freedom. See `../Evidence/` and `../Verification.json`.

## Privacy and workflow boundaries

Speech assets require explicit download approval; Apple manages shared models and possible retries. Recording is a separate action. No raw audio file recorder exists in Folio's source. The transcript stays in memory until explicitly reviewed and moved into Capture. That handoff does not run AI or save a note automatically.

Model capture remains explicit-context, review-before-apply and stale-edit protected. Native application/undo is distinct from a successful disk save. Current plain-vault notes, roadmap/recovery and outside-vault search cache remain plaintext. Encrypted `.rdm` now has an experimental authenticated archive/checkpoint foundation, a persistent encrypted local working store (unsaved drafts) with an encrypted derived-index cache, and a source-level session/preview/editor boundary; Mac runtime, editing integration, Keychain/recovery UX completion and fault/power-loss evidence are not complete.

## Still incomplete

Mac app compilation/runtime, Foundation Models/SpeechAnalyzer/TCC, Metal, native editor/undo/accessibility, APFS/power-loss, minimum-Mac and large-vault performance and independent security evidence remain blocked.

Encrypted-workspace UI/keychain/recovery lifecycle completion, E2EE collaboration, installer/updater/migrations and remaining native/editor/reconciliation/recovery polish are not complete. FolioDev/Windows/Android keep the approved deferred scope. No `.app` or `.pkg` has been built here.

## Internal engineering commands

These are engineering validation steps, not a request for the owner to test an unfinished app.

On Apple Silicon, macOS 26+, Xcode 26+, Python 3 and XcodeGen:

```sh
brew install xcodegen
bash ../scripts/verify-on-mac.sh
```

This runs core/probe checks, generates the Xcode project, attempts an ad-hoc Debug build and checks sandbox/file-picker/audio-input entitlements. Run microphone tests only through the actual app with its purpose string and explicit Record action. Ad-hoc signing is not distribution approval; the bundle identifier remains a development placeholder.

On the supported core-test host:

```sh
bash ../scripts/test-core.sh
```

Linux needs Swift 6, Clang with sanitizer runtimes, OpenSSL/SQLite development libraries and Python 3. The optional setup script restores the tested Linux toolchain into a cache. All probes generate fresh fixtures; never run crash helpers against real work.

## Internal Mac speech gates

1. Verify capability checks/download UI never activate the microphone.
2. Test first-use, denied, restricted and revoked microphone permission; cancel while the permission dialog/preparation is pending.
3. Confirm actual format validation, buffer-copy ownership, overflow failure, resampling and final converter tail handling.
4. Stop/close/sleep/lose focus/change input devices at every lifecycle stage. The UI must not announce off/closed before acknowledgement.
5. Verify finalized/provisional ordering, partial warnings, corrections and immutable review/capture bindings.
6. Profile callback real-time characteristics, memory/energy, timer/resource bounds and long/rapid restart sessions.
7. Confirm no app audio file, unintended transcript log, cloud fallback or hidden network request is introduced; review OS/framework limits separately.

No speech/audio gate is considered passed because this checklist or native adapter exists.

## Contracts and progress

- `../architecture/SPEECH-SECURITY-CONTRACT.md` and `../architecture/ENCRYPTED-RDM-CONTRACT.md`, `../architecture/CAPTURE-SECURITY-CONTRACT.md`, and the existing storage/reading/planning contracts.
- `notices/Apple-Speech-Sample-License.txt` — sample attribution for referenced AVFoundation integration.
- `progress/PROGRESS.md`, `planning/Folio-Feature-Completion.md`, `planning/Folio-Implementation-Plan.md`, `planning/decisions/`.

The supplied logo remains unchanged. The workspace retains one current source archive. Every reported percentage remains separate from mandatory security and release evidence.

## Encrypted `.rdm` container

The active source contains a pinned Argon2id implementation, AES-256-GCM/HKDF adapters, strict ZIP64 encrypted manifest/object transport, passphrase/recovery slots and an atomic checkpoint actor. Increment 08 adds the persistent encrypted local working store (chained sealed draft records with fail-closed stale review) and the encrypted derived-index cache. The recorded encrypted suite has 56 passing tests from Increment 07, with 23 working-store/session tests added in Increment 08 pending execution; the last full core runs have 333 Debug and 333 Release tests passing on Linux.

This is not production encryption approval. Mac CryptoKit/APFS parity, Keychain/device-slot runtime validation, recovery rotation, on-demand encrypted object caching, fuzzing, power-loss, migration and independent cryptographic review remain open. Read `../architecture/ENCRYPTED-RDM-CONTRACT.md`; do not use it for sensitive projects.
