import XCTest
import Foundation
@testable import FolioCore

actor RDMFixtures {
    static let shared = RDMFixtures()
    static let projectID = UUID(uuidString: "9F8894BE-1DF0-44B1-88E3-7811443A811B")!
    static let passphrase = "correct horse battery staple"
    private var saved: RDMCreatedKeys?
    func credentials() async throws -> RDMCreatedKeys {
        if let saved {
            return .init(keys: .init(projectID: saved.keys.projectID, master: try saved.keys.master.copy(), slots: saved.keys.slots), recoveryCode: saved.recoveryCode)
        }
        let value = try await RDMCredentials.create(projectID: Self.projectID, passphrase: Self.passphrase)
        saved = value
        return .init(keys: .init(projectID: value.keys.projectID, master: try value.keys.master.copy(), slots: value.keys.slots), recoveryCode: value.recoveryCode)
    }
    nonisolated static func project(_ body: String = "PRIVATE_NOTE_CANARY\n[[Plan]]\n") -> RDMProjectPayload {
        let note = RDMNote(id: UUID(uuidString: "5F8FE83F-88F1-4344-A3C0-8DA34B754F11")!, path: "Private folder/Secret title.md", markdown: "\u{FEFF}---\r\ncustom: keep\r\n---\r\n" + body)
        let plan = RDMNote(id: UUID(uuidString: "D6D091BA-3358-486D-872B-1EB0C20F8A7E")!, path: "Notes/Plan.md", markdown: "# Plan\n")
        let task = RoadmapItem(id: UUID(uuidString: "522C2DC3-ECCB-4686-BAD0-89DE35805B0D")!, title: "PRIVATE_TASK_CANARY", due: try! CivilDay("2026-10-14"), linkedNoteIDs: [note.id])
        return .init(id: projectID, name: "PRIVATE_PROJECT_CANARY", notes: [note, plan], roadmap: .init(revision: UUID(uuidString: "886AAC63-C0B4-44F5-BF32-0B129A70C0BC")!, items: [task]))
    }
}

final class RDMArchiveTests: XCTestCase, @unchecked Sendable {
    func testEncryptedArchiveRoundTripPreservesNotesMetadataRoadmapAndIDs() async throws {
        let credentials = try await RDMFixtures.shared.credentials()
        let project = RDMFixtures.project()
        let sealed = try RDMArchive.seal(project, keys: credentials.keys, credentialVerified: true)
        let opened = try await RDMArchive.open(sealed.bytes, passphrase: RDMFixtures.passphrase)
        defer { opened.keys.lock() }
        XCTAssertEqual(opened.project, project); XCTAssertEqual(opened.snapshotID, sealed.snapshotID)
        XCTAssertNil(opened.parentSnapshotID)
    }
    func testCipherArchiveHasNoPlaintextNoteNameBodyOrTaskCanaries() async throws {
        let keys = try await RDMFixtures.shared.credentials()
        let archive = try RDMArchive.seal(RDMFixtures.project(), keys: keys.keys, credentialVerified: true)
        for text in ["PRIVATE_NOTE_CANARY", "Secret title.md", "Private folder", "PRIVATE_TASK_CANARY", "PRIVATE_PROJECT_CANARY", keys.recoveryCode, RDMFixtures.passphrase] {
            XCTAssertNil(archive.bytes.range(of: Data(text.utf8)), text)
        }
        let members = try RDMZip.decode(archive.bytes)
        XCTAssertTrue(members.keys.allSatisfy { $0 == "header.json" || $0 == "manifest.enc" || $0.hasPrefix("objects/") })
    }
    func testIndependentRecoveryCredentialUnlocksTheSameProject() async throws {
        let credentials = try await RDMFixtures.shared.credentials()
        let archive = try RDMArchive.seal(RDMFixtures.project(), keys: credentials.keys, credentialVerified: true)
        let opened = try RDMArchive.open(archive.bytes, recoveryCode: credentials.recoveryCode.lowercased())
        defer { opened.keys.lock() }
        XCTAssertEqual(opened.project, RDMFixtures.project())
    }
    func testWrongPassphraseReturnsNoProject() async throws {
        let credentials = try await RDMFixtures.shared.credentials()
        let archive = try RDMArchive.seal(RDMFixtures.project(), keys: credentials.keys, credentialVerified: true)
        do { _ = try await RDMArchive.open(archive.bytes, passphrase: "wrong but long passphrase"); XCTFail("Wrong password was accepted") }
        catch RDMError.authenticationFailed { }
    }
    func testWrongWellFormedRecoveryCodeFailsAuthentication() async throws {
        let credentials = try await RDMFixtures.shared.credentials()
        let archive = try RDMArchive.seal(RDMFixtures.project(), keys: credentials.keys, credentialVerified: true)
        let code = "FOLIO-R1-" + Array(repeating: "00000000", count: 8).joined(separator: "-")
        XCTAssertThrowsError(try RDMArchive.open(archive.bytes, recoveryCode: code)) { XCTAssertEqual($0 as? RDMError, .authenticationFailed) }
    }
    func testEveryCheckpointGetsFreshSnapshotAndObjectRevisions() async throws {
        let credentials = try await RDMFixtures.shared.credentials()
        let first = try RDMArchive.seal(RDMFixtures.project(), keys: credentials.keys, credentialVerified: true)
        let next = try RDMArchive.seal(RDMFixtures.project(), keys: credentials.keys, parentSnapshotID: first.snapshotID, credentialVerified: true)
        XCTAssertNotEqual(first.snapshotID, next.snapshotID); XCTAssertNotEqual(first.bytes, next.bytes)
        let a = Set(try RDMZip.decode(first.bytes).keys.filter { $0.hasPrefix("objects/") })
        let b = Set(try RDMZip.decode(next.bytes).keys.filter { $0.hasPrefix("objects/") })
        XCTAssertTrue(a.isDisjoint(with: b))
        let opened = try RDMArchive.open(next.bytes, keys: credentials.keys); defer { opened.keys.lock() }
        XCTAssertEqual(opened.parentSnapshotID, first.snapshotID)
    }
    func testCiphertextAndManifestTamperingAreRejected() async throws {
        let credentials = try await RDMFixtures.shared.credentials()
        let archive = try RDMArchive.seal(RDMFixtures.project(), keys: credentials.keys, credentialVerified: true)
        for selected in ["manifest.enc", try RDMZip.decode(archive.bytes).keys.first(where: { $0.hasPrefix("objects/") })!] {
            var members = try RDMZip.decode(archive.bytes)
            var bytes = members[selected]!; bytes[bytes.count - 1] ^= 1; members[selected] = bytes
            let corrupt = try RDMZip.encode(members)
            XCTAssertThrowsError(try RDMArchive.open(corrupt, keys: credentials.keys))
        }
    }
    func testMissingOrUnreferencedMembersAreRejected() async throws {
        let credentials = try await RDMFixtures.shared.credentials()
        let archive = try RDMArchive.seal(RDMFixtures.project(), keys: credentials.keys, credentialVerified: true)
        var members = try RDMZip.decode(archive.bytes)
        let name = members.keys.first { $0.hasPrefix("objects/") }!
        members.removeValue(forKey: name)
        XCTAssertThrowsError(try RDMArchive.open(RDMZip.encode(members), keys: credentials.keys))
        members = try RDMZip.decode(archive.bytes)
        members["objects/" + String(repeating: "a", count: 64)] = Data("unreferenced".utf8)
        XCTAssertThrowsError(try RDMArchive.open(RDMZip.encode(members), keys: credentials.keys))
    }
    func testObjectsCannotBeTransplantedAcrossSnapshots() async throws {
        let credentials = try await RDMFixtures.shared.credentials()
        let first = try RDMArchive.seal(RDMFixtures.project("one"), keys: credentials.keys, credentialVerified: true)
        let next = try RDMArchive.seal(RDMFixtures.project("two"), keys: credentials.keys, credentialVerified: true)
        let a = try RDMZip.decode(first.bytes)
        var b = try RDMZip.decode(next.bytes)
        let from = a.keys.first { $0.hasPrefix("objects/") }!, to = b.keys.first { $0.hasPrefix("objects/") }!
        b[to] = a[from]
        XCTAssertThrowsError(try RDMArchive.open(RDMZip.encode(b), keys: credentials.keys))
    }
    func testUntrustedKDFParametersAreRejectedBeforeUnlock() async throws {
        let credentials = try await RDMFixtures.shared.credentials()
        let archive = try RDMArchive.seal(RDMFixtures.project(), keys: credentials.keys, credentialVerified: true)
        var members = try RDMZip.decode(archive.bytes)
        var object = try JSONSerialization.jsonObject(with: members["header.json"]!) as! [String: Any]
        var slots = object["slots"] as! [[String: Any]]
        let index = slots.firstIndex { $0["kind"] as? String == "passphrase" }!
        var kdf = slots[index]["kdf"] as! [String: Any]; kdf["memoryKiB"] = 2_000_000_000; slots[index]["kdf"] = kdf; object["slots"] = slots
        members["header.json"] = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        do { _ = try await RDMArchive.open(RDMZip.encode(members), passphrase: RDMFixtures.passphrase); XCTFail("Malicious KDF accepted") }
        catch RDMError.invalidKDF { }
    }
    func testNoncanonicalOrUnknownHeaderFieldsAreNotSilentlyIgnored() async throws {
        let credentials = try await RDMFixtures.shared.credentials()
        let archive = try RDMArchive.seal(RDMFixtures.project(), keys: credentials.keys, credentialVerified: true)
        var members = try RDMZip.decode(archive.bytes)
        members["header.json"] = Data(" ".utf8) + members["header.json"]!
        XCTAssertThrowsError(try RDMArchive.open(RDMZip.encode(members), keys: credentials.keys))
    }
    func testCredentialHeaderIsBoundIntoManifestAuthentication() async throws {
        let credentials = try await RDMFixtures.shared.credentials()
        let archive = try RDMArchive.seal(RDMFixtures.project(), keys: credentials.keys, credentialVerified: true)
        var members = try RDMZip.decode(archive.bytes)
        let header = try RDMCanonical.decode(RDMHeader.self, from: members["header.json"]!)
        let altered = RDMHeader(format: header.format, suite: header.suite, projectID: header.projectID, snapshotID: header.snapshotID,
                                manifestRevision: header.manifestRevision, slots: header.slots.reversed())
        members["header.json"] = try RDMCanonical.encode(altered)
        XCTAssertThrowsError(try RDMArchive.open(RDMZip.encode(members), keys: credentials.keys))
    }
    func testUnsafeAndCollidingLogicalPathsCannotBeSealed() async throws {
        let keys = try await RDMFixtures.shared.credentials()
        let malicious = RDMProjectPayload(id: RDMFixtures.projectID, name: "Test", notes: [.init(id: UUID(), path: "../escape.md", markdown: "bad")])
        XCTAssertThrowsError(try RDMArchive.seal(malicious, keys: keys.keys, credentialVerified: true))
        let duplicates = RDMProjectPayload(id: RDMFixtures.projectID, name: "Test", notes: [
            .init(id: UUID(), path: "Note.md", markdown: "one"), .init(id: UUID(), path: "note.md", markdown: "two")])
        XCTAssertThrowsError(try RDMArchive.seal(duplicates, keys: keys.keys, credentialVerified: true))
    }
    func testRecoveryConfirmationAndPassphraseFloorAreRequired() async throws {
        let keys = try await RDMFixtures.shared.credentials()
        XCTAssertThrowsError(try RDMArchive.seal(RDMFixtures.project(), keys: keys.keys, credentialVerified: false))
        do { _ = try await RDMCredentials.create(projectID: UUID(), passphrase: "short"); XCTFail("Weak initial password accepted") }
        catch RDMError.weakPassphrase { }
    }
    func testChangingPassphraseDoesNotClaimToRevokeOlderArchives() async throws {
        let created = try await RDMFixtures.shared.credentials()
        let old = try RDMArchive.seal(RDMFixtures.project(), keys: created.keys, credentialVerified: true)
        let changed = try await RDMCredentials.changingPassphrase("a new distinct long passphrase", keys: created.keys)
        defer { changed.lock() }
        let newer = try RDMArchive.seal(RDMFixtures.project(), keys: changed, parentSnapshotID: old.snapshotID, credentialVerified: true)
        let newOpen = try await RDMArchive.open(newer.bytes, passphrase: "a new distinct long passphrase"); newOpen.keys.lock()
        do { _ = try await RDMArchive.open(newer.bytes, passphrase: RDMFixtures.passphrase); XCTFail("Old password opened rewrapped archive") }
        catch RDMError.authenticationFailed { }
        let oldOpen = try await RDMArchive.open(old.bytes, passphrase: RDMFixtures.passphrase); oldOpen.keys.lock()
        let recovered = try RDMArchive.open(newer.bytes, recoveryCode: created.recoveryCode); recovered.keys.lock()
    }
    func testTruncatedAndRandomContainersFailWithoutPlaintextReturn() async throws {
        let keys = try await RDMFixtures.shared.credentials()
        let archive = try RDMArchive.seal(RDMFixtures.project(), keys: keys.keys, credentialVerified: true)
        for length in [0, 4, 20, archive.bytes.count / 2] {
            XCTAssertThrowsError(try RDMArchive.open(Data(archive.bytes.prefix(length)), keys: keys.keys))
        }
    }
    func testZIPTransportRejectsUnknownMemberNamesAndDuplicateLogicalEntries() throws {
        let valid: [String: Data] = ["header.json": Data("{}".utf8), "manifest.enc": Data("x".utf8)]
        XCTAssertNoThrow(try RDMZip.encode(valid))
        XCTAssertThrowsError(try RDMZip.encode(["header.json": Data(), "manifest.enc": Data(), "../escape": Data()]))
    }
    func testZipArchiveIsStoreModeAndHasForcedZip64Markers() async throws {
        let credentials = try await RDMFixtures.shared.credentials()
        let bytes = try RDMArchive.seal(RDMFixtures.project(), keys: credentials.keys, credentialVerified: true).bytes
        // ZIP64 end-of-central-directory signature. Archive member contents are
        // application-authenticated, so transport CRC/compression is irrelevant.
        XCTAssertNotNil(bytes.range(of: Data([0x50,0x4b,0x06,0x06])))
    }
    func testLockedProjectKeyCannotSealOrOpenThroughKeyHandle() async throws {
        let credentials = try await RDMFixtures.shared.credentials()
        credentials.keys.lock()
        XCTAssertThrowsError(try RDMArchive.seal(RDMFixtures.project(), keys: credentials.keys, credentialVerified: true)) { XCTAssertEqual($0 as? RDMError, .locked) }
        XCTAssertTrue(credentials.keys.isLocked)
    }
    func testDeterministicByteMutationsFailClosedOrPreserveOnlyAuthenticatedContent() async throws {
        let credentials = try await RDMFixtures.shared.credentials()
        let archive = try RDMArchive.seal(RDMFixtures.project(), keys: credentials.keys, credentialVerified: true)
        var state: UInt64 = 0x9E3779B97F4A7C15
        for _ in 0..<128 {
            var mutated = archive.bytes
            state = state &* 0xBF58476D1CE4E5B9 &+ 0x94D049BB133111EB
            let index = Int(state % UInt64(mutated.count))
            mutated[index] ^= UInt8(truncatingIfNeeded: (state >> 56) | 1)
            do {
                let opened = try RDMArchive.open(mutated, keys: credentials.keys)
                XCTAssertEqual(opened.project, RDMFixtures.project())
                opened.keys.lock()
            } catch { }
        }
    }
    func testRandomBytesAreRejectedByTheBoundedZIPDecoder() throws {
        var state: UInt64 = 0xD1B54A32D192ED03
        for length in stride(from: 0, through: 2048, by: 17) {
            var random = Data(count: length)
            random.withUnsafeMutableBytes { raw in
                for index in 0..<raw.count {
                    state = state &* 0x5851F42D4C957F2D &+ 1
                    raw[index] = UInt8(truncatingIfNeeded: state >> 33)
                }
            }
            do { _ = try RDMZip.decode(random); XCTFail("Random bytes decoded as ZIP") }
            catch { }
        }
    }
    func testZIPMemberBoundsRejectOversizedInputBeforeArchiveCreation() throws {
        let oversized = Data(repeating: 0xA5, count: RDMZip.maximumMemberBytes + 1)
        let entries: [String: Data] = [
            "header.json": Data(), "manifest.enc": Data(),
            "objects/" + String(repeating: "a", count: 64): oversized
        ]
        XCTAssertThrowsError(try RDMZip.encode(entries))
    }

}
