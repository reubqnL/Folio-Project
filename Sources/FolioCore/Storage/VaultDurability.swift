import Foundation

/// N01 durability contract — explicit, honest acknowledgement states.
///
/// A write is only called durable after the acknowledged transaction has
/// crossed the storage barrier implemented by `VaultFileSystem.writeAtomic`
/// (staged-file flush, atomic install, parent-directory flush; see
/// `docs/architecture/STORAGE-CONTRACT.md`). A timer firing, a queued write
/// or a debounce deadline is never treated as a save acknowledgement.
///
/// The contract keeps three axes separate so the UI cannot blur them:
/// - `VaultDurability` — local note durability (this file).
/// - `VaultCheckpointState` — `.rdm` archive construction, separate again.
/// - `VaultRemoteState` — upload/sync, which does not exist in this build.
public enum VaultDurability: Equatable, Sendable {
    /// The title/location sheet has not created anything; nothing is on disk.
    case notCreated
    /// The note was read from disk and no local edit is waiting.
    case loadedFromDisk
    /// Edits exist in memory (or a coalescing window is open); no write has
    /// been acknowledged yet.
    case editsPending
    /// A write is in flight. Not acknowledged until the barrier is crossed.
    case writing
    /// The acknowledged transaction crossed the storage barrier.
    case durableOnDisk
    /// An external writer raced the note; base and both versions are kept.
    case externalConflict
    /// The write failed. Local text is preserved; the last known good file
    /// was not overwritten.
    case failed(String)

    /// Short status label for the UI. Wording never claims durability for
    /// work that has only been queued, timed or written without a confirmed
    /// acknowledgement.
    public var label: String {
        switch self {
        case .notCreated: "Not created"
        case .loadedFromDisk: "Loaded from disk"
        case .editsPending: "Edits pending write"
        case .writing: "Writing to disk…"
        case .durableOnDisk: "Durable on disk"
        case .externalConflict: "Conflict — local text preserved"
        case let .failed(reason): "Not saved: \(reason)"
        }
    }

    /// Longer explanation for help text: what the state claims and what it
    /// deliberately does not claim.
    public var explanation: String {
        switch self {
        case .notCreated:
            "Cancelling the title and location sheet creates no file and no hidden draft on disk."
        case .loadedFromDisk:
            "The editor shows the note as last read from disk. No local edits are waiting to be written."
        case .editsPending:
            "Edits are held in memory. A coalesced write starts at most \(Int(SaveCoalescing.boundedMaximumDelay * 1000)) ms after the first edit (\(Int(SaveCoalescing.editDebounce * 1000)) ms after the latest edit); Folio shows \"Durable on disk\" only after the write is acknowledged."
        case .writing:
            "A write is in progress. Folio acknowledges it only after the note bytes and the parent directory are flushed; a timer firing or a queued write is not treated as saved."
        case .durableOnDisk:
            "The acknowledged transaction crossed the storage barrier: contents flushed with fsync (F_FULLFSYNC requested on macOS) and the parent directory flushed. Volume power-loss behaviour is not verified in this build."
        case .externalConflict:
            "An external writer changed this note while you were editing. Your local text, the base version and the external version are all preserved for review."
        case .failed:
            "Your edited text is still open in the editor. Folio did not overwrite the last known good file."
        }
    }

    /// True only for states whose write crossed the storage barrier.
    public var acknowledgesDurability: Bool {
        if case .durableOnDisk = self { return true }
        return false
    }

    /// Maps editor flags onto the contract states. Precedence matches the
    /// failure model: an unresolved conflict or failure outranks in-flight
    /// work so an unacknowledged write can never mask an earlier error.
    public static func resolve(
        conflict: Bool = false,
        failure: String? = nil,
        isSaving: Bool = false,
        isDirty: Bool = false,
        lastWriteConfirmed: Bool = false
    ) -> VaultDurability {
        if conflict { return .externalConflict }
        if let failure { return .failed(failure) }
        if isSaving { return .writing }
        if isDirty { return .editsPending }
        return lastWriteConfirmed ? .durableOnDisk : .loadedFromDisk
    }
}

/// N01 state 4 — `.rdm` archive construction is separate from local
/// durability. A stale archive is never described as up to date, and a
/// durable local draft is never described as checked in.
public enum VaultCheckpointState: Equatable, Sendable {
    /// No encrypted archive exists for this project (plain vault, or none open).
    case noArchive
    /// Unsaved drafts exist in the encrypted local working copy; the archive
    /// checkpoint is behind the editor until the user approves it.
    case draftOutstanding
    /// The archive contains the latest approved changes.
    case current
    /// The last approved checkpoint write failed; drafts were kept.
    case failed(String)

    public var label: String {
        switch self {
        case .noArchive: "No .rdm checkpoint"
        case .draftOutstanding: "Checkpoint pending"
        case .current: "Checkpoint current"
        case let .failed(reason): "Checkpoint failed: \(reason)"
        }
    }

    public var explanation: String {
        switch self {
        case .noArchive:
            "Plain local projects have no encrypted archive checkpoint. Local durability is independent of any archive."
        case .draftOutstanding:
            "Unsaved drafts are durable in the encrypted local working copy only. The archive checkpoint is written when you approve it; the archive is not up to date until then."
        case .current:
            "The archive contains the latest approved changes. New local edits show as pending again until the next approved checkpoint."
        case .failed:
            "The last archive write failed. Unsaved drafts remain in the encrypted local working copy and were not discarded."
        }
    }
}

/// N01 state 5 — upload/sync is separate again. A server receipt would not
/// prove that offline collaborators received a change; this build has no
/// remote state at all and must never imply one.
public enum VaultRemoteState: Equatable, Sendable {
    case unavailable

    public var label: String {
        switch self {
        case .unavailable: "Local only — no sync"
        }
    }

    public var explanation: String {
        switch self {
        case .unavailable:
            "This build has no upload or synchronisation. Folio sends project data nowhere; other applications may still read or sync the project folder themselves."
        }
    }
}
