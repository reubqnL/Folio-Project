# Encrypted `.rdm` foundation — Increment 07

**Estimated project completion: 41%.** This is a bounded cryptographic/container foundation, not a production security approval. Mac CryptoKit/APFS, native encrypted UI/keychain/recovery UX, persistent encrypted index design, independent review and release evidence remain outstanding.

## Current implementation

- A pinned upstream Argon2 reference source (20190702 commit) is included under `Sources/CArgon2`; its license/provenance are under `Notices/`.
- Linux CI uses OpenSSL EVP for AES-256-GCM/HKDF and libarchive for ZIP64 transport. The intended Mac adapter uses CryptoKit for AES-GCM/HKDF and the same portable Argon2 integration.
- `RDMSecret` owns a bounded dedicated allocation, attempts memory locking/dump exclusion, zeroes and unmaps on lock/deinit. This is best-effort and not protection from a compromised unlocked OS or every transient library copy.
- KDF headers are validated before Argon2 allocation. v1 accepts exactly Argon2id v1.3, 64 MiB, 3 iterations, 4 lanes, 128-bit salt and 256-bit output. This is the selected cross-platform compatibility profile, not a universally optimal password policy.
- Project master, passphrase slot, recovery slot, domain-separated HKDF object keys, fresh nonces and AES-GCM associated data are separated by protocol purpose/project/snapshot/object/revision/chunk.
- A recovery code is returned once by creation and is never placed in the archive. Changing a passphrase rewraps the current master; it does not claim to revoke old copied archives.
- `RDMArchive` builds/opens a bounded ZIP64 envelope with clear routing header, encrypted manifest and encrypted immutable objects. It does not extract members to disk.
- `RDMFileStore` uses the existing descriptor-relative vault lock and atomic encrypted-file checkpoint path. Creation refuses any pre-existing destination rather than replacing it; checkpoints refuse stale external replacement and write no plaintext staging archive. `RDMProjectSession` now binds that store to a memory-only index and prepares the replacement index before checkpoint installation.

## Header and member rules

Clear `header.json` has a strict version/suite/project/snapshot/manifest-revision/slot schema. It discloses project UUID, snapshot identity, KDF salts/parameters and lengths, not note names/bodies/roadmap text.

Allow-list:

```text
header.json
manifest.enc
objects/<64 lowercase hex characters>
```

ZIP64 is forced; entries are regular, store-mode, bounded and non-encrypted at the transport layer. Application AES-GCM authenticates actual content. Reject duplicate/unknown members, symlinks/hardlinks, encrypted transport entries, unexpected filters, missing/extra manifest references, oversized declared lengths and malformed canonical JSON.

Every immutable member record is:

```text
FRB1 | 32-byte revision | 12-byte nonce | uint64 big-endian ciphertext length | ciphertext | 16-byte tag
```

The manifest authenticates object member name, logical kind/ID/path, revision, plaintext/sealed lengths and digests, snapshot lineage and complete object set. AAD binds project UUID, snapshot ID, object kind, logical ID, revision, chunk index/count and header digest. A ciphertext/object transplant therefore fails authentication or manifest consistency.

## Plaintext and metadata boundaries

The `.rdm` archive does not expose note paths, titles, bodies, roadmap entities or connection text. Archive size/timing and clear routing metadata remain visible under the accepted initial metadata threat model. No persistent plaintext FTS/index or working object is implemented for encrypted mode yet.

Exports, clipboard, external open, diagnostics, previews, crash reports, swap and the unlocked process are separate data-boundary work. This foundation does not claim that a malicious unlocked OS cannot observe content.

## Checkpoint lifecycle

1. Open validates the bounded public header before credential KDF.
2. Credential unwrap authenticates a master key; complete manifest/object validation occurs before project exposure.
3. Checkpoint creates fresh snapshot/object/revision/nonce values and records parent lineage.
4. Sealed bytes are written to a private `.folio/.rdm-write-UUID.tmp`, flushed, linked/exchanged into the `.rdm` filename, and parent-flushed. Existing bytes remain if the operation fails.
5. Before replacing, the store reads the current header snapshot and refuses a stale external archive.
6. Reopen authenticates the current file; no timestamp-based staging choice is made.

The current checkpoint test suite covers wrong credentials, tampering, truncation, metadata/object transplant, stale external replacement, lock ownership and reopen. It does not simulate power loss or APFS `F_FULLFSYNC` in this Linux workspace.

## Evidence

- 10 primitive tests: AES-GCM known answers, HKDF RFC vector, Argon2id vector/profile, authentication failures, erasure, domain separation and bounds.
- 22 archive tests: round trip, no plaintext canaries, recovery/passphrase, fresh revisions, tampering, transplant, bounds, canonical fields, path/identity validation, hostile mutations and transport checks.
- 8 checkpoint tests: create/open/recovery, atomic checkpoint, locking, stale external file, no plaintext staging and malformed paths.
- 8 working-index tests: memory-only bounds, deletion/close erasure, no persistent cache path, atomic rebuild preservation and current-object search.
- 5 encrypted-session tests: recovery reopen, checkpoint/index ordering, failed checkpoint preservation, lock release and no plaintext cache artifacts.
- Full regression and Debug/Release counts are recorded in `Verification.json` after the current package run.

## Required before feature-complete handoff

- Mac CryptoKit parity and actual Swift SDK typecheck.
- Fuzz/coverage/sanitizer testing of CArgon2/archive/record/header parsers and malicious size/entry graphs.
- Independent cryptographic/protocol review, dependency/SBOM/license review and threat-model signoff.
- Encrypted working store/index/cache/WAL/temp/preview/diagnostic design; plaintext FTS prohibited in encrypted mode.
- Keychain/device slots, recovery rotation, lost-key UX, clipboard/export boundaries and password calibration on supported hardware. The current UI source offers explicit, non-synchronising passphrase convenience storage only; this is not device-slot or recovery-rotation completion.
- APFS/power-loss/disk-full/permission/kill-at-boundary checkpoint tests and migration/rollback lineage.
- Native encrypted workspace UI source now distinguishes Plain vault vs Encrypted project state, supports explicit reviewed checkpoints and prepares a non-destructive plain-to-encrypted copy with cancellation before archive creation; Mac SDK/runtime, migration, editing accessibility, Keychain and persistent-index validation remain.

No sensitive project should be entrusted to this foundation yet. It is a carefully tested implementation spike with explicit non-completion boundaries.
