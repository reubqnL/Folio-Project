# Folio — feature-complete handoff checklist

**Estimated completion: 41% (weighted planning estimate, not security/correctness) · User-testing status: HOLD.** You asked to test only after the approved Mac feature set is complete. Development and engineering verification continue; these source packages are not requests for you to beta-test unfinished features.

## Scope retained from your decisions

The initial product is native macOS FolioNotes. FolioDev stays visible but disabled initially; its later first capability is read-only. Windows evaluation remains blocked by Mac readiness, and Android remains read-only in its later phase. “All features before my test” does not silently enable those deliberately deferred modules/platforms.

## Current completion map

| Area | Current state | Remaining before feature-complete handoff |
|---|---|---|
| Approved branding / launcher | Source uses your unchanged logo and disabled FolioDev | Native visual/accessibility verification and polish |
| Local Markdown projects | Persistent core, journal, conflict/recovery, scoped-folder UI source | Full Mac fault/platform validation, recursive reconciliation, recovery-management completion |
| Editing / reading | Native source editor, Source/Preview/Split source, UTF-16 mapping, bounded Markdown subset | Full required dialect/IME/undo/focus/accessibility/large-document quality gates |
| Search / commands | FTS5 core, separate search/palette, protected shortcut mapping | Large-vault and native integration/performance validation |
| Roadmap | Persistent tasks/milestones, Timeline/Kanban source, Unscheduled tray, bulk moves, links, dependency repair, undo/redo core | Native UI verification, remaining interaction polish and complete metadata-conflict recovery UX |
| Connections graph | Shared note/task/dependency model, one-hop 2D default, clusters/list, opt-in 3D math, native Metal source | Real Metal shader/device/UI testing, accessible interaction and performance/battery budgets |
| AI capture | Tested context/approval/cancellation/review/apply core; native composer/editor bridge and Apple local-model adapter source | Real Mac SDK/inference/quality/resource tests; native undo/rollback and integration hardening |
| Speech | Tested lifecycle/consent/PCM/transcript policy, native microphone/SpeechAnalyzer source and review UI | Actual Mac TCC/audio/conversion/teardown/asset/ASR quality and accessibility/resource evidence; text fallback remains mandatory |
| `.rdm` encrypted projects | Bounded crypto/archive/checkpoint foundation; 56 focused tests passing, including hostile-input, atomic-rebuild and encrypted-session coverage; explicit session-bound preview/editor, reviewed checkpoint-draft and non-destructive plain-to-encrypted-copy source; single-file atomic checkpoint source; bounded memory-only derived index | Persistent encrypted working store/index, CryptoKit/Mac runtime validation, Keychain/recovery UX, editing/runtime accessibility validation, fuzzing, power-loss, independent review and migrations |
| E2EE collaboration | Specification only | Maintained CRDT/MLS integration, service/identity/membership, long-offline merge, revocation/history safeguards and independent review |
| Installer / updates | Specification and local development build script | Developer ID ownership/signing, notarization/stapling, professional `.pkg`, updater, rollback and migration evidence |
| Release trust | Blocking policy implemented | Every actual required check must pass; no waiver path |

## Latest engineering evidence

Increment 07 has **333 core tests passing in the Debug and Release runs**; the encrypted foundation includes **56 focused crypto/archive/checkpoint/working-index/hostile-input/session tests passing**. Existing workflow/process checks and audio sanitizers remain. Crypto tests include published AES-GCM/HKDF/Argon2 vectors; archive tests use no plaintext canaries and stale-checkpoint cases. `PROGRESS.md` explains the 41% estimate and weighted scope. The recorded full-regression evidence and current source archive are retained; Mac/runtime and release gates remain open.

This proves those bounded core scenarios, not a complete Mac product. The environment cannot run Xcode/AppKit/Metal, and no Mac `.app` or installer has been built. Native execution, physical power-loss, performance/accessibility and independent security evidence remain outstanding.

## Next development sequence

1. Complete remaining native editor/storage/planning integration and fault handling while keeping the canonical data model stable.
2. Integrate encrypted projects into the native workspace with explicit keychain/recovery UX and no plaintext cache/WAL path.
3. Complete hostile-input, interruption, persistence and migration coverage around `.rdm`, then validate CryptoKit/APFS on a real Mac.
4. Implement and independently evaluate the collaboration/security programme.
5. Finish native distribution/update/migration workflows and run the required Mac/security test matrices.
6. Offer your feature-complete build only after both implementation scope and mandatory engineering gates are satisfied.

Missing Mac infrastructure/signing identities and independent audit work must be obtained as engineering prerequisites; Linux core tests cannot stand in for them. No claim of absolute security is made.
