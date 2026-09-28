import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public struct RoadmapSnapshot: Sendable {
    public let projectID: UUID
    public let rootIdentity: String
    public let document: RoadmapDocument
    let bytes: Data?
}
public enum RoadmapSaveResult: Sendable {
    case written(RoadmapSnapshot)
    case conflict(current: RoadmapSnapshot, preservedProposal: UUID)
}
struct RoadmapRecoveryResult {
    var replayed = 0
    var review: [RecoveryItem] = []
    var uncertainIO = false
}
private struct RoadmapIntent: Codable {
    let version: Int
    let kind: String
    let id: UUID
    let projectID: UUID
    let beforeDigest: String?
    let afterDigest: String
    let createdAt: Double
}
private struct RoadmapReceipt: Codable {
    let id: UUID
    let afterDigest: String
    let displacedDigest: String
}

/// Used only while isolated to the owning PlainVaultStore actor. One constant
/// owned sidecar path; no caller-supplied metadata paths or executable payloads.
final class RoadmapPersistence: @unchecked Sendable {
    private let files: VaultFileSystem
    private let target = ".folio/roadmap.json"
    private let journal = ".folio/roadmap-journal"
    init(files: VaultFileSystem) { self.files = files }

    func load(projectID: UUID, rootIdentity: String) throws -> RoadmapSnapshot {
        let raw = try files.readIfPresent(target, limit: RoadmapCodec.byteLimit)?.data
        return .init(projectID: projectID, rootIdentity: rootIdentity,
                     document: try raw.map(RoadmapCodec.decode) ?? .empty, bytes: raw)
    }
    func save(base: RoadmapSnapshot, document: RoadmapDocument, projectID: UUID, rootIdentity: String,
              hooks: VaultTestHooks) throws -> RoadmapSaveResult {
        guard base.projectID == projectID, base.rootIdentity == rootIdentity else { throw PlanningError.wrongWorkspace }
        try RoadmapEngine.validateStructure(document)
        let issues = RoadmapEngine.issues(in: document)
        guard issues.isEmpty else { throw PlanningError.invalidChange(issues) }
        guard document.revision != base.document.revision else { throw PlanningError.staleRevision }
        let after = try RoadmapCodec.encode(document)
        try files.directory(journal)
        try prune(reserving: after.count * 2 + (base.bytes?.count ?? 0) + RoadmapCodec.byteLimit + 8192)
        let id = UUID()
        let dir = directory(id)
        let intent = RoadmapIntent(version: 1, kind: "roadmap", id: id, projectID: projectID,
            beforeDigest: base.bytes.map(ContentDigest.sha256), afterDigest: ContentDigest.sha256(after), createdAt: Date().timeIntervalSince1970)
        try files.directory(dir)
        if let before = base.bytes { try files.writeNew(dir + "/before.json", bytes: before) }
        try files.writeNew(dir + "/proposed.json", bytes: after)
        try files.writeNew(dir + "/install.json", bytes: after)
        try files.writeNew(dir + "/intent.json", bytes: encode(intent))
        try hooks.onStage?(.journalSealed)
        let current = try files.readIfPresent(target, limit: RoadmapCodec.byteLimit)?.data
        guard current == base.bytes else {
            try review(intent, reason: "The roadmap changed outside this editor.", external: current)
            return .conflict(current: try load(projectID: projectID, rootIdentity: rootIdentity), preservedProposal: id)
        }
        try hooks.onStage?(.beforeInstall)
        try install(intent)
        try hooks.onStage?(.installed)
        let displaced = try files.read(dir + "/install.json", limit: RoadmapCodec.byteLimit).data
        let head = try files.read(target, limit: RoadmapCodec.byteLimit).data
        guard displaced == (base.bytes ?? after), head == after else {
            try review(intent, reason: "A roadmap write raced installation. Versions were retained for review.", external: displaced)
            return .conflict(current: try load(projectID: projectID, rootIdentity: rootIdentity), preservedProposal: id)
        }
        try hooks.onStage?(.metadataUpdated)
        try commit(intent, displaced: displaced)
        try hooks.onStage?(.committed)
        return .written(.init(projectID: projectID, rootIdentity: rootIdentity, document: document, bytes: after))
    }

    func recover(projectID: UUID, replay: Bool) throws -> RoadmapRecoveryResult {
        guard try files.stat(journal) != nil else { return .init() }
        var result = RoadmapRecoveryResult()
        for (name, stamp) in try files.entries(journal, limit: 1024).sorted(by: { $0.0 < $1.0 }) {
            guard stamp.kind == 2, let id = UUID(uuidString: name), id.uuidString == name else { continue }
            let dir = directory(id)
            do {
                let intent = try readIntent(id)
                let after = try payload(dir + "/proposed.json", digest: intent.afterDigest)
                let proposed = try RoadmapCodec.decode(after)
                guard RoadmapEngine.issues(in: proposed).isEmpty else { throw PlanningError.invalidDocument }
                let before = try intent.beforeDigest.map { try payload(dir + "/before.json", digest: $0) }
                if let receipt = try receipt(intent) {
                    let displaced = try files.read(dir + "/install.json", limit: RoadmapCodec.byteLimit).data
                    if ContentDigest.sha256(displaced) != receipt.displacedDigest {
                        try review(intent, reason: "A preserved roadmap version was changed after commit.", external: nil)
                        result.review.append(item(id, "Preserved roadmap bytes changed after commit; no rollback was performed."))
                    }
                    continue
                }
                let alreadyNeedsReview = try files.stat(dir + "/REVIEW") != nil
                if !replay || intent.projectID != projectID || alreadyNeedsReview {
                    try review(intent, reason: "Explicit roadmap review is required.", external: nil)
                    result.review.append(item(id, "A preserved roadmap proposal was not applied automatically.")); continue
                }
                let current = try files.readIfPresent(target, limit: RoadmapCodec.byteLimit)?.data
                if current != after {
                    guard current == before else {
                        try review(intent, reason: "Roadmap recovery found a changed head.", external: current)
                        result.review.append(item(id, "The current roadmap no longer matches the recorded base.")); continue
                    }
                    guard try files.read(dir + "/install.json", limit: RoadmapCodec.byteLimit).data == after else { throw PlanningError.invalidDocument }
                    try install(intent)
                }
                let displaced = try files.read(dir + "/install.json", limit: RoadmapCodec.byteLimit).data
                let head = try files.read(target, limit: RoadmapCodec.byteLimit).data
                guard displaced == (before ?? after), head == after else {
                    try review(intent, reason: "Roadmap recovery preserved an unexpected version.", external: displaced)
                    result.review.append(item(id, "A displaced roadmap version requires manual review.")); continue
                }
                try commit(intent, displaced: displaced); result.replayed += 1
            } catch {
                result.review.append(item(id, "Unsealed, inaccessible or invalid roadmap transaction: " + error.localizedDescription))
                if case VaultError.io(let code, _, _) = error,
                   [EIO, ENOSPC, EACCES, EPERM, EROFS, EBADF].contains(code) { result.uncertainIO = true }
            }
        }
        return result
    }
    private func install(_ intent: RoadmapIntent) throws {
        let staged = directory(intent.id) + "/install.json"
        if intent.beforeDigest == nil { try files.linkNew(staged, to: target) }
        else { try files.copyMetadata(target, to: staged); try files.exchange(staged, with: target) }
        try files.syncParent(target)
    }
    private func review(_ intent: RoadmapIntent, reason: String, external: Data?) throws {
        let dir = directory(intent.id)
        if let external, try files.stat(dir + "/external.json") == nil { try files.writeNew(dir + "/external.json", bytes: external) }
        if try files.stat(dir + "/REVIEW") == nil { try files.writeNew(dir + "/REVIEW", bytes: Data(reason.utf8)) }
    }
    private func commit(_ intent: RoadmapIntent, displaced: Data) throws {
        let path = directory(intent.id) + "/committed.json"
        if try files.stat(path) == nil {
            try files.writeNew(path, bytes: encode(RoadmapReceipt(id: intent.id, afterDigest: intent.afterDigest, displacedDigest: ContentDigest.sha256(displaced))))
        }
    }
    private func readIntent(_ id: UUID) throws -> RoadmapIntent {
        let raw = try files.read(directory(id) + "/intent.json", limit: 8192).data
        let intent = try JSONDecoder().decode(RoadmapIntent.self, from: raw)
        guard intent.version == 1, intent.kind == "roadmap", intent.id == id else { throw PlanningError.invalidDocument }
        return intent
    }
    private func receipt(_ intent: RoadmapIntent) throws -> RoadmapReceipt? {
        guard let raw = try files.readIfPresent(directory(intent.id) + "/committed.json", limit: 8192)?.data else { return nil }
        let value = try JSONDecoder().decode(RoadmapReceipt.self, from: raw)
        guard value.id == intent.id, value.afterDigest == intent.afterDigest else { throw PlanningError.invalidDocument }
        return value
    }
    private func payload(_ path: String, digest: String) throws -> Data {
        let bytes = try files.read(path, limit: RoadmapCodec.byteLimit).data
        guard ContentDigest.sha256(bytes) == digest else { throw PlanningError.invalidDocument }
        return bytes
    }
    private func prune(reserving: Int) throws {
        var size = 0, removable: [(UUID, Double, Int)] = []
        for (name, stamp) in try files.entries(journal, limit: 1024) {
            guard stamp.kind == 2, let id = UUID(uuidString: name), id.uuidString == name else { continue }
            var count = 0
            for (_, file) in try files.entries(directory(id), limit: 16) {
                guard file.size <= 128 * 1024 * 1024 else { throw PlanningError.tooLarge }
                count += Int(file.size)
            }
            size += count
            if try files.stat(directory(id) + "/REVIEW") != nil { continue }
            guard let intent = try? readIntent(id), let receipt = try? receipt(intent),
                  let displaced = try? files.read(directory(id) + "/install.json", limit: RoadmapCodec.byteLimit),
                  ContentDigest.sha256(displaced.data) == receipt.displacedDigest else { continue }
            removable.append((id, intent.createdAt, count))
        }
        removable.sort { $0.1 < $1.1 }
        var retained = removable.count
        for (id, _, count) in removable {
            if retained <= 8 && size + reserving <= 128 * 1024 * 1024 { break }
            for file in ["before.json", "proposed.json", "install.json", "committed.json", "intent.json"] { try files.remove(directory(id) + "/" + file) }
            try files.remove(directory(id), directory: true); size -= count; retained -= 1
        }
        guard size + reserving <= 128 * 1024 * 1024 else { throw PlanningError.tooLarge }
    }
    private func directory(_ id: UUID) -> String { journal + "/" + id.uuidString }
    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try encoder.encode(value)
    }
    private func item(_ id: UUID, _ reason: String) -> RecoveryItem {
        .init(id: id, relativePath: ".folio/roadmap.json", explanation: reason + " Preserved files are in .folio/roadmap-journal/" + id.uuidString,
              proposedMarkdown: nil)
    }
}
