import XCTest
@testable import FolioCore

final class DiskReconciliationTests: XCTestCase {
    private let base = Data("base".utf8)
    func testCleanChangedFileReloads() {
        XCTAssertEqual(DiskReconciliation.decide(base: base, buffer: "base", disk: Data("external".utf8), hasLocalEdits: false), .reloadCleanBuffer)
    }
    func testDirtyBufferAndUnchangedDiskStayIndependent() {
        XCTAssertEqual(DiskReconciliation.decide(base: base, buffer: "local", disk: base, hasLocalEdits: true), .unchanged)
    }
    func testDivergedLocalAndExternalChangesRequireConflictReview() {
        XCTAssertEqual(DiskReconciliation.decide(base: base, buffer: "local", disk: Data("external".utf8), hasLocalEdits: true), .preserveConflict)
    }
    func testRecoveredProposalAlreadyOnDiskIsNotAnotherConflict() {
        XCTAssertEqual(DiskReconciliation.decide(base: base, buffer: "local", disk: Data("local".utf8), hasLocalEdits: true), .bufferAlreadyMatchesDisk)
    }
    func testCleanUnchangedDocumentIsNoOp() {
        XCTAssertEqual(DiskReconciliation.decide(base: base, buffer: "base", disk: base, hasLocalEdits: false), .unchanged)
    }
}
