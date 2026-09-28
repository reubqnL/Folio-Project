import Foundation
import FolioRDMPrimitives
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

enum RDMZip {
    static let maximumArchiveBytes = 96 * 1024 * 1024
    static let maximumEntries = 2052
    static let maximumMemberBytes = 8 * 1024 * 1024 + 1024

    static func encode(_ entries: [String: Data]) throws -> Data {
        guard entries.count >= 2, entries.count <= maximumEntries,
              entries.values.allSatisfy({ $0.count <= maximumMemberBytes }) else { throw RDMError.resourceLimit }
        var members: [FolioZipMember] = []
        defer {
            for member in members { free(member.name); member.bytes?.deallocate() }
        }
        for name in entries.keys.sorted() {
            guard let bytes = entries[name], let cName = strdup(name) else { throw RDMError.cryptoUnavailable }
            let owned = UnsafeMutablePointer<UInt8>.allocate(capacity: max(1, bytes.count))
            bytes.copyBytes(to: owned, count: bytes.count)
            members.append(.init(name: cName, bytes: owned, length: bytes.count))
        }
        var output: UnsafeMutablePointer<UInt8>?, length = 0
        let ok = members.withUnsafeBufferPointer { folio_rdm_zip_write($0.baseAddress, $0.count, maximumArchiveBytes, &output, &length) }
        defer { folio_rdm_bytes_free(output) }
        guard ok == 1, let output, length <= maximumArchiveBytes else { throw RDMError.invalidFormat }
        return Data(bytes: output, count: length)
    }
    static func decode(_ data: Data) throws -> [String: Data] {
        guard data.count <= maximumArchiveBytes else { throw RDMError.resourceLimit }
        var members: UnsafeMutablePointer<FolioZipMember>?, count = 0
        let ok = data.withUnsafeBytes {
            folio_rdm_zip_read($0.bindMemory(to: UInt8.self).baseAddress, $0.count,
                maximumEntries, maximumMemberBytes, maximumArchiveBytes, &members, &count)
        }
        defer { folio_rdm_zip_free(members, count) }
        guard ok == 1, let members else { throw RDMError.invalidFormat }
        var result: [String: Data] = [:]
        for index in 0..<count {
            let member = members[index]
            guard let name = member.name, let bytes = member.bytes, member.length <= maximumMemberBytes else { throw RDMError.invalidFormat }
            let key = String(cString: name)
            guard result[key] == nil else { throw RDMError.duplicateIdentity }
            result[key] = Data(bytes: bytes, count: member.length)
        }
        return result
    }
}
