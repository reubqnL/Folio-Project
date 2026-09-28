# Encrypted `.rdm` checkpoint contract — Increment 07

**Development crypto/container foundation. 309 Linux core tests pass after this increment; no production/security approval is implied. Mac CryptoKit/APFS, independent review and native encrypted-workspace integration remain open.**

## What `.rdm` is

v1 is a single regular file containing a bounded ZIP64 transport envelope. It is **not** a renamed plaintext ZIP and not a directory bundle. The ZIP member names are a fixed allow-list:

```text
header.json          # clear routing/version/suite/project and credential-slot metadata
manifest.enc         # encrypted logical project/object map
objects/<64 hex>     # encrypted immutable object records
```

Clear header fields reveal format/suite, project UUID, snapshot ID, manifest revision, KDF-slot salts/parameters and wrapped-key ciphertext lengths. It does not reveal project name, note paths, bodies, roadmap titles or connection text. A service/observer can still infer archive size/timing; the accepted initial privacy scope discloses such metadata rather than promising traffic hiding.

The archive uses libarchive's ZIP writer/parser with forced ZIP64, store/no compression and fixed entry paths. ZIP AES encryption is not used: application members are encrypted with the protocol below, avoiding a second password/crypto implementation in the transport layer. A future production archive may change the transport only through a versioned reviewed migration.

## Key hierarchy and algorithms

- Project master key: random 256-bit secret held in a dedicated protected allocation where possible; `mlock`/dump exclusion is best effort.
- Passphrase slot: random 128-bit salt, fixed Argon2id v1.3 compatibility profile `m=65536 KiB, t=3, p=4`, output 256 bits. Header parameters are validated before any KDF allocation; hostile parameters cannot request arbitrary cost.
- Recovery slot: a displayed user-held recovery code unwraps the same master key through a separate derived credential key. The recovery code is never written into the archive or ordinary logs.
- Per immutable object/manifest revision: fresh 256-bit revision ID, domain-separated HKDF-SHA-256 derived object key, fresh 96-bit AES-GCM nonce. The revision ID is also the `objects/<hex>` member name; duplicate IDs are rejected.
- AES-256-GCM authenticates ciphertext and fixed-length associated data containing protocol domain, project UUID, snapshot ID, object kind, logical UUID, revision, chunk index/count and header digest.
- Manifest authenticates the complete object list, member names, expected plaintext/sealed lengths and digests, snapshot lineage and logical names. It is encrypted as an object with its own revision.
- Plaintext SHA-256 values in the encrypted manifest are integrity metadata, not standalone authentication. Ciphertext tags and manifest authentication are required.

The Linux adapter uses pinned upstream PHC Argon2 source, OpenSSL EVP AES-GCM/HKDF and libarchive. The Mac adapter is intended to use CryptoKit AES.GCM/HKDF and the same portable Argon2 implementation through an audited integration. AES, HKDF, Argon2 and ratchets are not implemented from scratch here.

## Credential and lock behaviour

Successful passphrase/recovery open requires header validation, bounded slot parsing, KDF/authentication and complete object/manifest validation before returning plaintext. Wrong credentials and tag failures do not return partial content. The in-memory key handle can be explicitly locked/erased; callers must not use it afterward.

Changing a passphrase rewraps a fresh credential slot around the same master and does **not** claim that old copied archives are revoked. Full content rekey, device Keychain slots, recovery rotation and collaboration membership are later security work. The current recovery code can unlock an archive; it is not a service-held backdoor.

## Checkpoint and crash rules

`RDMFileStore` owns a selected parent folder lock and the `.rdm` regular file. It never writes plaintext project objects or an unencrypted temp archive. Checkpointing:

1. Reads the current public header and checks its snapshot ID against the store's authenticated head.
2. Builds a fresh archive in memory with fresh snapshot/object revisions and parent lineage.
3. Writes only an encrypted staging member under `.folio/.rdm-write-<UUID>.tmp`, flushes it, then non-clobberingly links or atomically exchanges it into the `.rdm` path and flushes the parent.
4. Removes the sealed staging member only after installation; a stale external file causes `staleCheckpoint` rather than overwrite.
5. Reopening authenticates the complete envelope and validates every object before exposing the project.

A process interruption can leave ciphertext-only staging material. Recovery must re-read/verify the current file; it must never choose a staged archive by timestamp alone. Power-loss/APFS `F_FULLFSYNC` evidence remains a Mac gate.

## Parser and resource boundaries

- Maximum archive 96 MiB; maximum 2,052 members; maximum 8 MiB member; maximum 64 MiB total plaintext.
- Exactly one clear header, one encrypted manifest, at least roadmap/connections objects, and only allow-listed regular files.
- Reject duplicate names, symlinks/hardlinks, encrypted ZIP members, unknown members, non-ZIP filters, missing/extra manifest references, invalid lengths, duplicate revisions/identities, unsafe logical paths, unknown schema/fields, invalid UTF-8 Markdown and inconsistent graph/roadmap derivations.
- Canonical sorted JSON rejects unknown fields, duplicate/ambiguous JSON representations and lossy re-encoding before authentication/acceptance.
- No archive member is extracted to a filesystem path. Decompression is disabled for v1 transport to remove expansion-ratio ambiguity.
- Passphrase/KDF slots are bounded before Argon2 work. A single actor serializes password derivation in the KDF helper.

## Tests and not-yet-proven properties

The current crypto/archive tests cover independent AES-GCM/HKDF/Argon2 vectors, key erasure API, wrong credentials, tampered ciphertext/tags/AAD, fresh revisions, object transplant resistance, missing/extra members, malformed headers, unsafe logical paths, stale external checkpoint replacement, archive reopen and recovery credentials. The complete suite is **309 Debug tests**; primitive/archive/file-store focus is **32 tests**.

Still required before feature-complete handoff:

- Mac CryptoKit/System Security integration and CryptoKit vector parity.
- External independent cryptographic/protocol review, threat-model review and dependency/SBOM/license verification.
- Fuzzing ZIP/header/manifest/record parsers and KDF-resource/error paths; sanitizers/coverage for all C adapters.
- APFS/power-loss and disk-full/permission/kill-at-every-checkpoint-boundary tests.
- Real encrypted working store/index/WAL/temp/preview/diagnostic paths; persistent plaintext FTS is prohibited in encrypted mode.
- Keychain/device/recovery rotation, passphrase change UX, clipboard/export boundaries and lost-key messaging.
- Migration/rollback and archive lineage policy; older copied archives cannot be remotely revoked.
- Native encrypted workspace UI, open/lock/privacy state labels and accessibility.

This increment is a carefully bounded foundation, not a claim that Folio encryption is complete, audited or safe for sensitive projects.
