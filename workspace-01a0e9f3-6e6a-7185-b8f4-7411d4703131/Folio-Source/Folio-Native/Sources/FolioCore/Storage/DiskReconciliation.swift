import Foundation

public enum DiskReconciliation: Equatable, Sendable {
    case unchanged
    case reloadCleanBuffer
    case bufferAlreadyMatchesDisk
    case preserveConflict

    /// Content decisions only; observing matching bytes is not a new durability
    /// acknowledgement. Actual save/recovery barriers belong to PlainVaultStore.
    public static func decide(base: Data, buffer: String, disk: Data, hasLocalEdits: Bool) -> Self {
        if !hasLocalEdits { return disk == base ? .unchanged : .reloadCleanBuffer }
        if Data(buffer.utf8) == disk { return .bufferAlreadyMatchesDisk }
        if disk == base { return .unchanged }
        return .preserveConflict
    }
}
