import Foundation
import FolioFileIO
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

struct FileStamp: Sendable, Equatable {
    let identity: String
    let size: UInt64
    let modifiedNS: Int64
    let changedNS: Int64
    let permissions: UInt32
    let kind: Int
    init(_ value: FolioFileInfo) {
        identity = "\(value.device):\(value.inode)"
        size = value.size; modifiedNS = value.modified_ns; changedNS = value.changed_ns
        permissions = value.permissions; kind = Int(value.kind)
    }
    var date: Date { Date(timeIntervalSince1970: Double(modifiedNS) / 1_000_000_000) }
}

struct FileBytes: Sendable {
    let data: Data
    let stamp: FileStamp
}

/// The descriptor and advisory lock are owned exclusively by one VaultStore actor.
/// No caller receives the descriptor. @unchecked Sendable permits actor transfer,
/// not concurrent calls; the public actor serializes all access.
final class VaultFileSystem: @unchecked Sendable {
    private var root: Int32
    private var lock: Int32 = -1
    let rootIdentity: String

    init(url: URL) throws {
        guard url.isFileURL else { throw VaultError.invalidPath }
        root = url.path.withCString { folio_open_root($0) }
        guard root >= 0 else {
            throw VaultError.io(code: folio_last_errno(), operation: "Open project", path: url.lastPathComponent)
        }
        var info = FolioFileInfo()
        let status = folio_root_info(root, &info)
        if status != 0 { folio_close_fd(root); root = -1; throw VaultError.io(code: status, operation: "Inspect project", path: url.lastPathComponent) }
        rootIdentity = FileStamp(info).identity
    }
    deinit { close() }
    func close() {
        folio_close_fd(lock); lock = -1
        folio_close_fd(root); root = -1
    }
    private func check(_ result: Int32, _ operation: String, _ path: String) throws {
        guard root >= 0 else { throw VaultError.closed }
        if result != 0 { throw VaultError.io(code: result, operation: operation, path: path) }
    }
    func acquireLock() throws {
        let status = ".folio/session.lock".withCString { folio_acquire_lock(root, $0, &lock) }
        if status == EWOULDBLOCK || status == EAGAIN { throw VaultError.busy }
        try check(status, "Acquire project lock", ".folio/session.lock")
    }
    func directory(_ path: String) throws {
        try check(path.withCString { folio_make_directory(root, $0) }, "Create directory", path)
    }
    func stat(_ path: String) throws -> FileStamp? {
        var result = FolioFileInfo()
        let status = path.withCString { folio_stat_file(root, $0, &result) }
        if status == ENOENT { return nil }
        try check(status, "Inspect file", path)
        return FileStamp(result)
    }
    func read(_ path: String, limit: Int) throws -> FileBytes {
        guard limit >= 0 else { throw VaultError.tooLarge }
        var bytes: UnsafeMutablePointer<UInt8>?
        var count = 0
        var stamp = FolioFileInfo()
        let status = path.withCString { folio_read_file(root, $0, limit, &bytes, &count, &stamp) }
        defer { folio_free_bytes(bytes) }
        if status == EFBIG { throw VaultError.tooLarge }
        try check(status, "Read file", path)
        let data = count == 0 ? Data() : Data(bytes: bytes!, count: count)
        return FileBytes(data: data, stamp: FileStamp(stamp))
    }
    func readIfPresent(_ path: String, limit: Int) throws -> FileBytes? {
        do { return try read(path, limit: limit) }
        catch VaultError.io(let code, _, _) where code == ENOENT { return nil }
    }
    func writeNew(_ path: String, bytes: Data, permissions: UInt32 = 0o600) throws {
        let status = bytes.withUnsafeBytes { raw in
            path.withCString { folio_write_new(root, $0, raw.bindMemory(to: UInt8.self).baseAddress, bytes.count, permissions) }
        }
        try check(status, "Write staging file", path)
    }
    func entries(_ path: String, limit: Int) throws -> [(String, FileStamp)] {
        var entries: UnsafeMutablePointer<FolioDirectoryEntry>?
        var count = 0
        let status = path.withCString { folio_list_directory(root, $0, limit, &entries, &count) }
        defer { folio_free_entries(entries, count) }
        if status == EFBIG { throw VaultError.tooLarge }
        try check(status, "Enumerate directory", path)
        guard let entries else { return [] }
        return (0..<count).map { (String(cString: entries[$0].name), FileStamp(entries[$0].info)) }
    }
    func writeAtomic(_ path: String, bytes: Data, permissions: UInt32 = 0o600) throws {
        guard !path.isEmpty, !path.hasSuffix("/"), path.utf8.count <= 4096 else { throw VaultError.invalidPath }
        let temporary = ".folio/.rdm-write-" + UUID().uuidString + ".tmp"
        try writeNew(temporary, bytes: bytes, permissions: permissions)
        do {
            if try stat(path) == nil { try linkNew(temporary, to: path) }
            else { try copyMetadata(path, to: temporary); try exchange(temporary, with: path) }
            try syncParent(path)
            try remove(temporary)
        } catch {
            try? remove(temporary)
            throw error
        }
    }

    func linkNew(_ source: String, to destination: String) throws {
        let status = source.withCString { a in destination.withCString { folio_link_new(root, a, $0) } }
        try check(status, "Install new note without overwriting", destination)
    }
    func exchange(_ source: String, with destination: String) throws {
        let status = source.withCString { a in destination.withCString { folio_exchange(root, a, $0) } }
        try check(status, "Atomically exchange files", destination)
    }
    func copyMetadata(_ source: String, to destination: String) throws {
        let status = source.withCString { a in destination.withCString { folio_copy_metadata(root, a, $0) } }
        try check(status, "Preserve file metadata", source)
    }
    func syncParent(_ path: String) throws {
        try check(path.withCString { folio_sync_parent(root, $0) }, "Flush directory", path)
    }
    func remove(_ path: String, directory: Bool = false) throws {
        let status = path.withCString { directory ? folio_remove_directory(root, $0) : folio_remove_file(root, $0) }
        if status == ENOENT { return }
        try check(status, "Remove resolved staging item", path)
    }
}

public enum ContentDigest {
    /// SHA-256 uses platform libraries: CommonCrypto on Mac, OpenSSL for Linux CI.
    /// This is an integrity fingerprint for plaintext storage, NOT encryption.
    public static func sha256(_ data: Data) -> String {
        var digest = [UInt8](repeating: 0, count: 32)
        data.withUnsafeBytes { buffer in
            folio_sha256(buffer.bindMemory(to: UInt8.self).baseAddress, data.count, &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
