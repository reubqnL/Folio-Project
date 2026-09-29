# Folio — completion estimate and evidence

**Estimated completion: 42% · Release readiness: blocked · Owner testing: HOLD**

Subjective weighted planning estimate; not verified security/correctness, percentage of code, or a release certificate.

| Area | Scope weight | Credited points |
|---|---:|---:|
| Product/design/decisions | 5 | 5 |
| Notes, project storage and search | 20 | 12 |
| Native editing, reading and accessibility | 15 | 7 |
| Roadmap and connections | 15 | 10 |
| AI capture and speech | 12 | 5 |
| Encrypted .rdm and key recovery | 13 | 2 |
| E2EE collaboration | 10 | 0 |
| Installer, updater and migrations | 5 | 0 |
| Mac integration, security review and release evidence | 5 | 1 |
| **Total** | **100** | **42** |

## Completed in this increment (08 — persistent encrypted working storage)

- Designed and implemented `RDMWorkingStore`: unsaved encrypted-project drafts now persist locally in two alternating AES-256-GCM sealed slot records chained by generation (`.folio/<name>.rdmworking.0/1`), with no plaintext residue and atomic `.folio` staging writes.
- Restore classification is fail-closed: intact chained pairs restore as current; torn, mixed-epoch, single-slot-rollback or unauthenticated copies surface as `.stale` for explicit review and block further draft writes (`recoveryRequired`) until `resolve()` re-anchors a fresh epoch; set-aside bytes are preserved as private `.folio` copies instead of being destroyed.
- Encrypted derived-index cache (`.folio/<name>.rdmindex`): sealed record bound to the archive snapshot it was built from; any absent, stale or invalid cache falls back to the in-memory rebuild and can never corrupt search.
- `RDMProjectSession` gains `restoreWorkingState` / `stageDraft` / `discardDraft` / `resolveWorkingState`; checkpoint flow stays archive-first and refreshes the encrypted cache after the durable write.
- Native encrypted UI now debounces draft text into the encrypted working copy, restores the most recent unsaved draft after unlock, discards local drafts after a successful checkpoint, and offers an explicit "Review local working copies" resolution flow; in-app captions updated to describe the real behaviour.
- New focused tests: chained round trip, stale detection (tampered ciphertext/header, missing history slot, single-slot rollback, mixed epochs, foreign project), reviewed resolution with byte preservation, draft bounds/validation, no-plaintext canary scan, index-cache round trip/corruption/snapshot binding, and session-level draft survive-close/reopen, discard, stale-block, cache-refresh and cache-fallback scenarios.

## Evidence status

- The full Debug/Release core run recorded at Increment 07 remains the last complete execution evidence (333 tests, 0 failures).
- This increment's source and tests pass full swift-syntax parsing (108 Swift files, 0 syntax failures); semantic/type validation and the new test executions must be run with `bash scripts/test-core.sh` in a Swift-capable environment before they count as evidence. Unrun checks are blocking, not a pass.
- No Mac SDK, CryptoKit/APFS, Keychain, accessibility, power-loss or independent security evidence exists here.

## Not established

- No Mac CryptoKit/APFS parity, fault/power-loss matrix, migrations or independent crypto review.
- No Keychain/device slot/recovery rotation, collaboration, installer or updater.
- No Mac SDK runtime/security/accessibility/performance signoff.
- Consistent rollback of both working slots to an older complete pair is not locally detectable (documented in the contract); the archive checkpoint remains the durable trust anchor.

No owner testing is requested until the approved feature set and mandatory gates are complete.
