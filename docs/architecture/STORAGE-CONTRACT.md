# Plain-vault storage contract — Increment 02

**Implemented and tested on Linux; Mac-specific behaviour and the Mac app are not yet validated. This is not release-ready storage. Use disposable copies.**

## Authority and privacy

The selected project folder contains ordinary UTF-8 `.md` / `.markdown` files. Their bytes are authoritative; opening and indexing do not rewrite front matter, a UTF-8 BOM, or line endings. Names/identities are recorded separately. A single selected folder is the first project-space unit; richer project grouping is still to come.

The project, its search-independent identity map and **all recovery copies are plaintext**. There is no `.rdm`, encryption, E2EE, cloud account or model provider in this increment. Another program may read or sync the chosen folder. A local-only Folio feature set is not a promise that other sync software is absent.

## On-disk format

```text
Selected project/
  Notes/An example.md
  .folio/
    project.json              # Strict version-1 project and note identity map
    session.lock              # Advisory single-Folio-writer lock
    journal/<transaction-UUID>/
      REVIEW                  # If present: never auto-replay this proposal
      base.md                 # Present for an existing-note update
      proposal.md             # Intended new UTF-8 contents
      install.md              # Staged replacement; after exchange, displaced file
      external.md             # Optional extra external snapshot during conflict
      intent.json             # Seal, written after staging payloads
      committed.json          # Receipt after install, metadata and barriers
```

`project.json` has `version`, `project: {id, name}` and `notes: {relativePath: {id, fileIdentity}}`. Unknown owned-schema fields/versions are refused rather than silently dropped or migrated. Note IDs survive reopen and unambiguous same-filesystem renames. A name/path match alone cannot prove that an external rename, replacement or copy has the user's intended identity in every case.

SHA-256 fingerprints use CommonCrypto on Mac and system OpenSSL in Linux CI. Fingerprinting detects payload corruption; **it is not encryption or authentication against an attacker who can rewrite the entire plain vault**.

## Write protocol

1. Validate the project/session, path, file type, byte limits and read-only state.
2. Prune only eligible, verified committed history to reserve space. Unresolved review records are not automatically removed.
3. Create a unique private transaction directory; write/flush the base, proposal and install slot. Write/flush the intent last.
4. Compare the current target's bytes against the exact expected base. A mismatch keeps a review copy and does not replace the target.
5. For a new file, install with a non-clobbering hard link; an existing name cannot be replaced by creation.
6. For an existing file, copy supported ownership/mode/ACL/xattr metadata, then atomically exchange the staged file with the destination. The displaced inode remains in the journal. No truncated or partially written proposal is exposed as a note.
7. Verify the displaced version and installed head. If an external writer raced the exchange, preserve the versions and return a conflict—not a successful acknowledgement. The working pathname may already contain Folio's proposed text in this specific race; the UI explains that instead of pretending nothing changed.
8. Persist the identity map and commit receipt only after the required file/directory barriers. A write/sync failure does not become a successful save.

Linux uses `fsync` and `renameat2(RENAME_EXCHANGE)`. The Mac branch requests `fsync`, `F_FULLFSYNC` for regular-file writes and `renameatx_np(RENAME_SWAP)`. Unsupported barriers/exchange operations fail; they do not silently downgrade. The actual APFS, external-volume and macOS sandbox semantics still need verification.

## External editing and recovery

- An advisory lock serialises Folio processes; it cannot force arbitrary editors or Git to cooperate.
- Clean open buffers reload externally changed files. Locally changed buffers retain both versions and enter review.
- The Mac source observes the active file and its parent directory, rebinds after replacement, and rescans on activation/manual Refresh. **This is not a complete recursive FSEvents indexer.** Changes elsewhere may require Refresh or app reactivation.
- A sealed interrupted write can replay only when the file still matches the recorded base. Already-installed proposals can be completed idempotently.
- A changed head, corrupt payload, invalid path, copied-workspace review policy or REVIEW marker blocks automatic replay.
- A committed journal never rolls a later external edit backwards.
- Choosing Use Disk Version first preserves any newer typing added after the conflict appeared. Choosing Keep My Text rechecks the disk revision; an intervening change asks for another review rather than overwriting an unseen version.
- A new independent workspace identity keeps pending proposals as review copies; it does not auto-replay the old workspace's unfinished writes.
- Late writes through an old displaced inode are checked when recovering/pruning. This is not a global serialisability guarantee for arbitrary non-cooperating writers that retain descriptors indefinitely. macOS coordination and adversarial race testing remain release work.

## Containment and resource bounds

I/O walks relative path components from a pinned root descriptor, with `O_NOFOLLOW` for ancestors and file opens. Note operations reject absolute paths, dot/hidden segments, NUL/control characters, unsupported suffixes and oversized components. Metadata paths are owned by the store. Symlinks are not indexed or followed; FIFO/device/special-file reads are refused.

Current defaults are safety caps, **not performance achievements**:

- 8 MiB per note;
- 100,000 enumerated entries and 32 directory levels;
- 16 MiB metadata;
- 128 MiB journal quota;
- roughly 12 retained committed transactions plus the current write;
- unresolved/conflicting records retained rather than silently discarded;
- owned metadata parameters and configured bounds validated before use.

The full metadata map is currently JSON, and scans are bounded but not a production large-vault index. SQLite/FTS, scalable reconciliation, cancellation/progress and the performance profiles remain later work. The journal is not a full version-history product. The current recovery UI can create a new note from preserved text; a complete resolution/retention-management interface is not implemented. Quota exhaustion blocks writes and requires careful review; do not experiment on irreplaceable data.

## Metadata limitations

The replacement path attempts to preserve Unix ownership/mode and supported ACL/xattrs, failing if those operations fail. Linux mode/ownership/a user xattr were exercised in the process suite. The macOS `fcopyfile` path, Finder metadata, ACL inheritance, creation dates, filesystem flags and provider semantics are **not validated**. Local normal folders are the supported development target; network/file-provider/cloud-managed folders are not approved for use.

## Verification limits

The supplied evidence covers Linux unit tests, real SIGKILL process interruption at five transaction boundaries for creates and updates, corrupted/changed recovery state, path containment and a metadata-preservation case. It does **not** simulate power loss, prove every filesystem's write barriers, validate AppKit, establish large-vault performance or replace independent security review. All such release gates remain blocked.
