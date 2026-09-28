# Folio — completion estimate and evidence

**Estimated completion: 41% · Release readiness: blocked · Owner testing: HOLD**

Subjective weighted planning estimate; not verified security/correctness, percentage of code, or a release certificate.

| Area | Scope weight | Credited points |
|---|---:|---:|
| Product/design/decisions | 5 | 5 |
| Notes, project storage and search | 20 | 12 |
| Native editing, reading and accessibility | 15 | 7 |
| Roadmap and connections | 15 | 10 |
| AI capture and speech | 12 | 5 |
| Encrypted .rdm and key recovery | 13 | 1 |
| E2EE collaboration | 10 | 0 |
| Installer, updater and migrations | 5 | 0 |
| Mac integration, security review and release evidence | 5 | 1 |
| **Total** | **100** | **41** |

## Completed in this increment
- Pinned upstream Argon2id v1.3 source with provenance/license notice and fixed bounded KDF profile.
- AES-256-GCM/HKDF primitives with known-answer vectors, protected secret handle and fail-closed authentication.
- Strict ZIP64 encrypted manifest/object envelope and passphrase/recovery credential slots.
- Atomic encrypted `.rdm` create/open/checkpoint store with stale-head refusal and lock ownership.
- 333 unit tests pass in Debug/Release; 56 focused encrypted tests (archive/crypto/file-store/memory-index/hostile-input/session) plus existing workflow/process checks pass.

## Not established
- No Mac CryptoKit/APFS parity, persistent encrypted working/index/cache/WAL integration or independent crypto review.
- No independent cryptographic review, broad parser fuzzing or power-loss checkpoint matrix; deterministic hostile-input coverage is present.
- No Keychain/device slot/recovery rotation, collaboration, installer or updater.
- No Mac SDK runtime/security/accessibility/performance signoff.

No owner testing is requested until the approved feature set and mandatory gates are complete.
