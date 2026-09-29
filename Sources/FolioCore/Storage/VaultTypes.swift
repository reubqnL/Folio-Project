import Foundation

public enum VaultError: Error, LocalizedError, Sendable {
    case needsInitialization, closed, busy, unsupportedFormat, malformedMetadata
    case invalidPath, invalidUTF8, tooLarge, wrongWorkspace, missingNote, readOnly
    case journalFull, recoveryRequired, invalidRecovery
    case io(code: Int32, operation: String, path: String)

    public var errorDescription: String? {
        switch self {
        case .needsInitialization: "This folder is not yet a Folio project. Confirm before creating its metadata."
        case .closed: "The project is closed."
        case .busy: "Another Folio process has this project open. Close it there first."
        case .unsupportedFormat: "This project uses an unsupported metadata version. No migration was attempted."
        case .malformedMetadata: "Project metadata could not be validated. It has not been replaced."
        case .invalidPath: "Use a relative Markdown path without hidden, empty or dot segments, backslashes or control characters."
        case .invalidUTF8: "This file is not valid UTF-8 Markdown. It has not been rewritten."
        case .tooLarge: "This file or project exceeds this development build's safety limit."
        case .wrongWorkspace: "This document belongs to a different project session."
        case .missingNote: "The note was removed or moved to an unknown location. Your local text is still available."
        case .readOnly: "The note is marked read-only. Choose a new location rather than overwriting it."
        case .journalFull: "Recovery storage is at its safety limit. Review pending recovery items before saving more changes."
        case .recoveryRequired: "Resolve the pending recovery state or reopen the project before writing more changes."
        case .invalidRecovery: "A recovery record failed validation. No note was modified from that record."
        case let .io(code, operation, path):
            "\(operation) failed for \(path): \(NSError(domain: NSPOSIXErrorDomain, code: Int(code)).localizedDescription)"
        }
    }
}

public struct VaultLimits: Sendable {
    public var maximumNoteBytes: Int = 8 * 1024 * 1024
    public var maximumEntries: Int = 100_000
    public var maximumDepth: Int = 32
    public var maximumMetadataBytes: Int = 16 * 1024 * 1024
    public var maximumJournalBytes: Int = 128 * 1024 * 1024
    public var retainedCommittedTransactions: Int = 12
    public init() {}
}

public struct VaultProject: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public var name: String
}

public struct VaultNote: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let relativePath: String
    public let modifiedAt: Date
    public let byteCount: UInt64
    public var title: String { (relativePath as NSString).lastPathComponent.replacingOccurrences(of: #"\.(md|markdown)$"#, with: "", options: [.regularExpression, .caseInsensitive]) }
    public var folder: String {
        let result = (relativePath as NSString).deletingLastPathComponent
        return result.isEmpty ? "Project root" : result
    }
}

public struct VaultSnapshot: Equatable, Sendable {
    public let projectID: UUID
    public let rootIdentity: String
    public let note: VaultNote
    public let bytes: Data
    public let revision: String
    public let permissions: UInt32
    public var markdown: String { String(decoding: bytes, as: UTF8.self) }
}

public struct VaultConflict: Sendable, Identifiable {
    public let id: UUID
    public let relativePath: String
    public let localMarkdown: String
    public let disk: VaultSnapshot?
    public let displacedMarkdown: String?
    public let explanation: String
    public init(id: UUID, relativePath: String, localMarkdown: String, disk: VaultSnapshot?, displacedMarkdown: String?, explanation: String) {
        self.id = id; self.relativePath = relativePath; self.localMarkdown = localMarkdown
        self.disk = disk; self.displacedMarkdown = displacedMarkdown; self.explanation = explanation
    }
}

public enum VaultSaveResult: Sendable {
    case written(VaultSnapshot)
    case conflict(VaultConflict)
}

public struct RecoveryItem: Sendable, Identifiable {
    public let id: UUID
    public let relativePath: String?
    public let explanation: String
    public let proposedMarkdown: String?
    public init(id: UUID, relativePath: String?, explanation: String, proposedMarkdown: String?) {
        self.id = id; self.relativePath = relativePath
        self.explanation = explanation; self.proposedMarkdown = proposedMarkdown
    }
}

public struct RecoveryReport: Sendable {
    public var replayed: [String] = []
    public var review: [RecoveryItem] = []
    public init() {}
}

public enum VaultWriteStage: String, CaseIterable, Sendable {
    case journalSealed, beforeInstall, installed, metadataUpdated, committed
}

/// Test-only fault boundaries and race scheduling. Production defaults to nil.
/// Throwing after installation deliberately leaves the sealed recovery record.
public struct VaultTestHooks: Sendable {
    public var onStage: (@Sendable (VaultWriteStage) throws -> Void)?
    public init(onStage: (@Sendable (VaultWriteStage) throws -> Void)? = nil) { self.onStage = onStage }
}

public enum VaultPaths {
    public static func validateNote(_ path: String) throws {
        try validateRelative(path)
        guard ["md", "markdown"].contains((path as NSString).pathExtension.lowercased()) else { throw VaultError.invalidPath }
    }
    public static func validateRelative(_ path: String) throws {
        guard !path.isEmpty, path.utf8.count <= 4096,
              path.rangeOfCharacter(from: .controlCharacters) == nil,
              !path.contains("\\"), !path.hasPrefix("/"), !path.hasSuffix("/") else { throw VaultError.invalidPath }
        for piece in path.split(separator: "/", omittingEmptySubsequences: false) {
            guard !piece.isEmpty, !piece.hasPrefix("."), piece.utf8.count <= 255 else { throw VaultError.invalidPath }
        }
    }
}

/// Monotonic-time calculation; continuous typing cannot reset the window forever.
///
/// The plan calls the debounce a coalescing target, not an acknowledgement
/// promise: these values only schedule the write attempt. Durability is
/// acknowledged separately, after the storage barrier is crossed
/// (`VaultDurability.durableOnDisk`).
public enum SaveCoalescing {
    /// Coalescing target after the latest edit (250 ms).
    public static let editDebounce: Double = 0.25
    /// Bounded maximum delay after the first dirty edit (500 ms). Continuous
    /// typing cannot push the first write attempt past this bound.
    public static let boundedMaximumDelay: Double = 0.5

    public static func deadline(firstDirty: Double, latestEdit: Double) -> Double {
        min(firstDirty + boundedMaximumDelay, latestEdit + editDebounce)
    }
}
