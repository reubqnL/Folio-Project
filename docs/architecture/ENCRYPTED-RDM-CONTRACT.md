# Encrypted `.rdm` container — Increments 07–08

**Estimated project completion: 42%.** This is a bounded cryptographic/container foundation with persistent encrypted working storage, not a production security approval. Mac CryptoKit/APFS, native encrypted UI/keychain/recovery UX completion, independent review and release evidence remain outstanding.

## Current implementation

- A pinned upstream Argon2 reference source (20190702 commit) is included under `Sources/CArgon2`; its license/provenance are under `../notices/`.
- Linux CI uses OpenSSL EVP for AES-256-GCM/HKDF and libarchive for ZIP64 transport. The intended Mac adapter uses CryptoKit for AES-GCM/HKDF and the same portable Argon2 integration.
- `RDMSecret` owns a bounded dedicated allocation, attempts memory locking/dump exclusion, zeroes and unmaps on lock/deinit. This is best-effort and not protection from a compromised unlocked OS or every transient library copy.
- KDF headers are validated before Argon2 allocation. v1 accepts exactly Argon2id v1.3, 64 MiB, 3 iterations, 4 lanes, 128-bit salt and 256-bit output. This is the selected cross-platform compatibility profile, not a universally optimal password policy.
- Project master, passphrase slot, recovery slot, domain-separated HKDF object keys, fresh nonces and AES-GCM associated data are separated by protocol purpose/project/snapshot/object/revision/chunk.
- A recovery code is returned once by creation and is never placed in the archive. Changing a passphrase rewraps the current master; it does not claim to revoke old copied archives.
- `RDMArchive` builds/opens a bounded ZIP64 envelope with clear routing header, encrypted manifest and encrypted immutable objects. It does not extract members to disk.
- `RDMFileStore` uses the existing descriptor-relative vault lock and atomic encrypted-file checkpoint path. Creation refuses any pre-existing destination rather than replacing it; checkpoints refuse stale external replacement and write no plaintext staging archive. **The container is not one file on disk**: it also creates a `.folio` folder beside the archive for the lock, the staging area and the encrypted working drafts. Under the App Sandbox a panel-selected file grant covers that file alone and does not extend to its containing directory, so the UI asks the user for the **folder** for both creation and opening. Selecting a `.rdm` file on its own is not sufficient and cannot be made sufficient without the user granting the containing folder. `RDMProjectSession` binds that store to a memory-resident derived index with a persistent encrypted cache, prepares the replacement index before checkpoint installation, and persists unsaved drafts through the encrypted local working store described below.

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

The `.rdm` archive does not expose note paths, titles, bodies, roadmap entities or connection text. Archive size/timing and clear routing metadata remain visible under the accepted initial metadata threat model. Persistent working objects and the derived index cache are sealed AES-256-GCM records under the same domain-separated key discipline as the archive; no plaintext working object, FTS/index file, SQLite file, WAL, preview or diagnostic cache exists for encrypted mode.

Exports, clipboard, external open, diagnostics, previews, crash reports, swap and the unlocked process are separate data-boundary work. This foundation does not claim that a malicious unlocked OS cannot observe content.

## Encrypted local working store (v1)

Unsaved drafts for an open encrypted project persist in two alternating slot records, `.folio/<archive-name>.rdmworking.0` and `.rdmworking.1`, each one sealed record:

```text
FRW1 | format | slot | reserved | u64 generation | 16-byte fileID | 12-byte nonce | u64 ciphertext length | ciphertext | 16-byte tag
```

- The record plaintext is canonical JSON: project identity, base snapshot lineage, previous-generation number and digest, timestamp and the bounded draft list. AAD binds project UUID, fileID, slot and generation; slot parity (`slot == (generation − 1) mod 2`) is part of the format.
- Each generation chains to the exact bytes of the previous generation's record. Restore classifies strictly: intact chained pairs (or a lone epoch-origin record) restore as `.current`; torn, mixed-epoch, chain-broken or unauthenticated copies surface as `.stale` with the best available state and block further draft writes (`recoveryRequired`) until an explicit `resolve()` accepts a state, preserves the set-aside bytes as private `.folio/*.rdmworking.discarded-*` copies, and re-anchors a fresh epoch.
- Documented residual risk: restoring both slots consistently from one older backup is not locally detectable; the authenticated archive checkpoint with its stale-head refusal remains the durable trust anchor.
- `clear()` removes both slot copies when drafts are explicitly discarded or absorbed into a checkpoint; the writer validates before replacement and never destroys set-aside bytes without a preserved copy.

The derived search index cache is a single sealed `FRX1` record, `.folio/<archive-name>.rdmindex`, whose payload carries the note set and the archive snapshot it was built from. It is refreshed after each durable checkpoint; on open it is used only when it authenticates and matches the current head, and any absent, stale or invalid cache falls back to the in-memory rebuild. The cache is derived data: its failure modes cannot corrupt search or project content.

## Checkpoint lifecycle

1. Open validates the bounded public header before credential KDF.
2. Credential unwrap authenticates a master key; complete manifest/object validation occurs before project exposure.
3. Checkpoint creates fresh snapshot/object/revision/nonce values and records parent lineage.
4. Sealed bytes are written to a private `.folio/.rdm-write-UUID.tmp`, flushed, linked/exchanged into the `.rdm` filename, and parent-flushed. Existing bytes remain if the operation fails.
5. Before replacing, the store reads the current header snapshot and refuses a stale external archive.
6. Reopen authenticates the current file; no timestamp-based staging choice is made.

The current checkpoint test suite covers wrong credentials, tampering, truncation, metadata/object transplant, stale external replacement, lock ownership and reopen. It does not simulate power loss or APFS `F_FULLFSYNC` in this Linux workspace.

## Runtime evidence

The native workspace has now been exercised on the owner's Mac: an encrypted project was created in a scratch folder, the one-time recovery code was shown and acknowledged, the project was locked, and it was reopened with its passphrase. That is the first time any part of this area has run on real hardware, and it exercises create, the recovery-code handoff, lock and reopen through the app rather than through the test suite. It is a smoke test, not a verification: nothing was tampered with, no checkpoint was written with a hostile filesystem, no power loss was simulated, and which keychain implementation the convenience store reached was not observed.

## Evidence

- 10 primitive tests: AES-GCM known answers, HKDF RFC vector, Argon2id vector/profile, authentication failures, erasure, domain separation and bounds.
- 22 archive tests: round trip, no plaintext canaries, recovery/passphrase, fresh revisions, tampering, transplant, bounds, canonical fields, path/identity validation, hostile mutations and transport checks.
- 8 checkpoint tests: create/open/recovery, atomic checkpoint, locking, stale external file, no plaintext staging and malformed paths.
- 8 working-index tests: memory-only bounds, deletion/close erasure, no persistent cache path, atomic rebuild preservation and current-object search.
- 5 encrypted-session tests: recovery reopen, checkpoint/index ordering, failed checkpoint preservation, lock release and no plaintext cache artifacts.
- Increment 08 adds 18 working-store tests (chained round trip, stale-detection matrix, reviewed resolution with byte preservation, draft bounds/validation, plaintext canaries, index-cache round trip/corruption/snapshot binding) and 5 session working-state tests (draft survive-close/reopen, discard-to-clear, stale-block until resolution, cache refresh after checkpoint, corrupted-cache fallback).
- Full regression and Debug/Release counts are recorded in `Verification.json` after the current package run.

## Required before feature-complete handoff

- Mac CryptoKit parity and actual Swift SDK typecheck.
- Execution of the Increment 08 test additions in a Swift-capable environment (`bash scripts/test-core.sh`); the recorded full run remains Increment 07's 333 tests.
- Fuzz/coverage/sanitizer testing of CArgon2/archive/record/header parsers and malicious size/entry graphs.
- Independent cryptographic/protocol review, dependency/SBOM/license review and threat-model signoff.
- Remaining working-store surface: preview/diagnostic boundaries, WAL-style write-ahead design if future on-demand object caching needs it, and power-loss/kill-at-boundary matrices for the slot pairs; plaintext FTS remains prohibited in encrypted mode.
- Keychain/device slots, recovery rotation, lost-key UX, clipboard/export boundaries and password calibration on supported hardware. The current UI source offers explicit, non-synchronising passphrase convenience storage only; this is not device-slot or recovery-rotation completion. The convenience store now targets the data protection keychain — the only macOS keychain that honours `kSecAttrAccessible` — and falls back to the file-based keychain when the process is not signed with an identity that provides an access group, which is the case for the ad-hoc signed development builds. Whether the stronger store is reachable from those builds, and which protection class the item actually receives, cannot be established without a Mac and has not been tested.
- APFS/power-loss/disk-full/permission/kill-at-boundary checkpoint tests and migration/rollback lineage.
- Native encrypted workspace UI source now distinguishes Plain vault vs Encrypted project state, supports explicit reviewed checkpoints, persists unsaved drafts in the encrypted working copy and prepares a non-destructive plain-to-encrypted copy with cancellation before archive creation.
- Multi-draft review now has a UI: the encrypted workspace lists every draft the working copy holds, newest first, and offers Open and Discard per draft, so drafts beyond the most recent are reachable without deleting the ones above them. Opening is refused while the editor holds text not yet confirmed in the working copy, and Discard is disabled while inconsistent copies await review. **This is unverified source and has never been exercised against a real encrypted project.** Mac SDK/runtime, migration, editing accessibility and Keychain device-slot validation remain.

No sensitive project should be entrusted to this foundation yet. It is a carefully tested implementation spike with explicit non-completion boundaries.
