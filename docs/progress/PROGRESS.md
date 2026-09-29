# Folio — completion estimate and evidence

**Estimated completion: 43% · Release readiness: blocked · Owner testing: HOLD**

Subjective weighted planning estimate; not verified security/correctness, percentage of code, or a release certificate.

| Area | Scope weight | Credited points |
|---|---:|---:|
| Product/design/decisions | 5 | 5 |
| Notes, project storage and search | 20 | 13 |
| Native editing, reading and accessibility | 15 | 7 |
| Roadmap and connections | 15 | 10 |
| AI capture and speech | 12 | 5 |
| Encrypted .rdm and key recovery | 13 | 2 |
| E2EE collaboration | 10 | 0 |
| Installer, updater and migrations | 5 | 0 |
| Mac integration, security review and release evidence | 5 | 1 |
| **Total** | **100** | **43** |

## Completed in this increment (09 — honest durability acknowledgement, N01 contract)

- Implemented the N01 durability contract as the explicit `VaultDurability` model: seven states (`notCreated`, `loadedFromDisk`, `editsPending`, `writing`, `durableOnDisk`, `externalConflict`, `failed`) with honest labels and scoped explanations. Only `durableOnDisk` acknowledges durability, and only after the write crossed the storage barrier (staged-file flush, atomic install, parent-directory flush). A timer firing or a queued write is never displayed as a save.
- The two separation axes from the contract are first-class: `VaultCheckpointState` keeps `.rdm` archive construction apart from local durability (a stale archive is never called up to date), and `VaultRemoteState.unavailable` states "Local only — no sync" instead of leaving sync implied.
- `SaveCoalescing` now carries the measured, documented bounds the plan demanded: 250 ms coalescing target after the latest edit, 500 ms bounded maximum after the first dirty edit — explicitly scheduling values, not acknowledgement promises.
- The plain editor status line derives from the model with barrier-scoped help text (including the unverified power-loss caveat); the notes status bar shows the sync axis. The encrypted workspace shows all three axes — working-copy draft durability (confirmed/pending/editor-only, generation-guarded against superseded debounced writes), checkpoint state (including failed-without-discard), and no sync — as one summary with per-axis explanations.
- Contract state 1 is stated in the UI: cancelling the new-note sheet creates no file and no hidden draft on disk.
- New focused tests: resolution/precedence matrix, label-honesty rules (unacknowledged states may never say "Durable"/"Saved"), scoped explanation content, checkpoint/remote separation wording, and the measured coalescing bounds including a 40-edit continuous-typing simulation.
- Fixed stale development captions (launcher increment/memory-only/read-only wording, encrypted landing gate list, unlock notice about unpersisted search results).

## Evidence status

- The full Debug/Release core run recorded at Increment 07 remains the last complete execution evidence (333 tests, 0 failures).
- This increment's source and tests pass full swift-syntax parsing (110 Swift files, 0 syntax failures); the 10 new tests (366 total in source) must run with `bash scripts/test-core.sh` in a Swift-capable environment before they count as evidence. Unrun checks are blocking, not a pass.
- No Mac SDK, CryptoKit/APFS, Keychain, accessibility, power-loss or independent security evidence exists here.

## Not established

- No Mac CryptoKit/APFS parity, fault/power-loss matrix, migrations or independent crypto review.
- No Keychain/device slot/recovery rotation, collaboration, installer or updater.
- No Mac SDK runtime/security/accessibility/performance signoff.
- Consistent rollback of both working slots to an older complete pair is not locally detectable (documented in the contract); the archive checkpoint remains the durable trust anchor.

No owner testing is requested until the approved feature set and mandatory gates are complete.
