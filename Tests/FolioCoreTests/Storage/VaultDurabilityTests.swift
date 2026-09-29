import XCTest
@testable import FolioCore

/// N01 durability-contract tests: honest acknowledgement states, label
/// wording rules, and the measured coalescing bounds. These are pure state
/// and scheduling tests; the storage barriers themselves are exercised by
/// the vault store suites.
final class VaultDurabilityTests: XCTestCase {

    // MARK: State resolution

    func testResolveMapsEveryDocumentFlagCombinationOntoContractStates() {
        XCTAssertEqual(VaultDurability.resolve(), .loadedFromDisk)
        XCTAssertEqual(VaultDurability.resolve(isDirty: true), .editsPending)
        XCTAssertEqual(VaultDurability.resolve(isSaving: true), .writing)
        XCTAssertEqual(VaultDurability.resolve(lastWriteConfirmed: true), .durableOnDisk)
        XCTAssertEqual(VaultDurability.resolve(conflict: true), .externalConflict)
        XCTAssertEqual(VaultDurability.resolve(failure: "disk full"), .failed("disk full"))
    }

    func testResolvePrecedenceKeepsUnacknowledgedWorkFromMaskingErrors() {
        // A conflict or failure outranks in-flight and pending work so an
        // unacknowledged write can never paint over an earlier error.
        let messy = VaultDurability.resolve(
            conflict: true, failure: "disk full", isSaving: true, isDirty: true, lastWriteConfirmed: true
        )
        XCTAssertEqual(messy, .externalConflict)
        let failed = VaultDurability.resolve(
            failure: "permission lost", isSaving: true, isDirty: true, lastWriteConfirmed: true
        )
        XCTAssertEqual(failed, .failed("permission lost"))
        // Writing outranks a stale dirty flag; both must never claim durable.
        XCTAssertEqual(VaultDurability.resolve(isSaving: true, isDirty: true, lastWriteConfirmed: true), .writing)
        // A dirty edit after the last acknowledged write is not durable.
        XCTAssertEqual(VaultDurability.resolve(isDirty: true, lastWriteConfirmed: true), .editsPending)
    }

    // MARK: Label honesty

    func testOnlyAcknowledgedStatesClaimDurability() {
        let unacknowledged: [VaultDurability] = [
            .notCreated, .loadedFromDisk, .editsPending, .writing, .externalConflict, .failed("x"),
        ]
        for state in unacknowledged {
            XCTAssertFalse(state.acknowledgesDurability, "\(state.label) must not acknowledge durability")
            // Case-sensitive: "Not saved: …" honestly negates the save and is
            // allowed; no unacknowledged state may use "Durable"/"Saved".
            for word in ["Durable", "Saved"] {
                XCTAssertFalse(state.label.contains(word), "\(state.label) must not contain \(word)")
            }
        }
        let durable = VaultDurability.durableOnDisk
        XCTAssertTrue(durable.acknowledgesDurability)
        XCTAssertTrue(durable.label.contains("Durable"))
    }

    func testEveryStateCarriesANonEmptyScopedExplanation() {
        let all: [VaultDurability] = [
            .notCreated, .loadedFromDisk, .editsPending, .writing, .durableOnDisk,
            .externalConflict, .failed("disk full"),
        ]
        for state in all {
            XCTAssertFalse(state.label.isEmpty)
            XCTAssertFalse(state.explanation.isEmpty)
        }
        // The durable explanation must scope the claim to the storage
        // barrier and keep the unverified power-loss caveat visible.
        let durable = VaultDurability.durableOnDisk.explanation
        XCTAssertTrue(durable.contains("storage barrier"))
        XCTAssertTrue(durable.contains("not verified"))
        // Pending work must point at the bounded coalescing window, not at a
        // durability promise.
        XCTAssertTrue(VaultDurability.editsPending.explanation.contains("500"))
        XCTAssertTrue(VaultDurability.editsPending.explanation.contains("250"))
        // Failure keeps the last known good file.
        XCTAssertTrue(VaultDurability.failed("x").explanation.contains("did not overwrite"))
        // Not-created states leave nothing hidden on disk.
        XCTAssertTrue(VaultDurability.notCreated.explanation.contains("no hidden draft"))
    }

    func testFailureLabelCarriesTheReasonWithoutClaimingASave() {
        XCTAssertEqual(VaultDurability.failed("permission lost").label, "Not saved: permission lost")
    }

    // MARK: Checkpoint and remote axes stay separate

    func testCheckpointStateNeverConflatesArchiveAndLocalDurability() {
        XCTAssertEqual(VaultCheckpointState.noArchive.label, "No .rdm checkpoint")
        XCTAssertEqual(VaultCheckpointState.draftOutstanding.label, "Checkpoint pending")
        XCTAssertEqual(VaultCheckpointState.current.label, "Checkpoint current")
        XCTAssertEqual(VaultCheckpointState.failed("io").label, "Checkpoint failed: io")

        // A pending checkpoint must say the archive is not up to date, and a
        // durable draft must not be described as checked in.
        XCTAssertTrue(VaultCheckpointState.draftOutstanding.explanation.contains("not up to date"))
        XCTAssertTrue(VaultCheckpointState.draftOutstanding.explanation.contains("approve"))
        XCTAssertTrue(VaultCheckpointState.failed("io").explanation.contains("were not discarded"))
        for state in [VaultCheckpointState.noArchive, .draftOutstanding, .current, .failed("io")] {
            XCTAssertFalse(state.explanation.isEmpty)
        }
    }

    func testRemoteStateExplicitlyDeniesSynchronisation() {
        XCTAssertEqual(VaultRemoteState.unavailable.label, "Local only — no sync")
        XCTAssertTrue(VaultRemoteState.unavailable.explanation.contains("no upload or synchronisation"))
    }

    // MARK: Measured coalescing bounds

    func testCoalescingConstantsMatchTheDocumentedMeasurements() {
        XCTAssertEqual(SaveCoalescing.editDebounce, 0.25, accuracy: 0.000_001)
        XCTAssertEqual(SaveCoalescing.boundedMaximumDelay, 0.5, accuracy: 0.000_001)
    }

    func testDeadlineRespectsBothTheBoundedMaximumAndTheDebounceTarget() {
        // A quick edit coalesces at latestEdit + 250 ms.
        XCTAssertEqual(SaveCoalescing.deadline(firstDirty: 10, latestEdit: 10.01), 10.26, accuracy: 0.00001)
        // The first dirty time bounds the total wait at 500 ms.
        XCTAssertEqual(SaveCoalescing.deadline(firstDirty: 10, latestEdit: 10.4), 10.5)
        XCTAssertEqual(SaveCoalescing.deadline(firstDirty: 10, latestEdit: 11), 10.5)
    }

    func testContinuousTypingCannotExceedTheBoundedMaximumDelay() {
        // Simulate 40 edits, one every 20 ms: the deadline must never drift
        // past firstDirty + boundedMaximumDelay.
        let firstDirty = 100.0
        var latestEdit = firstDirty
        for _ in 0..<40 {
            latestEdit += 0.02
            let due = SaveCoalescing.deadline(firstDirty: firstDirty, latestEdit: latestEdit)
            let maximumDeadline = firstDirty + SaveCoalescing.boundedMaximumDelay
            let debounceDeadline = latestEdit + SaveCoalescing.editDebounce
            XCTAssertLessThanOrEqual(due, maximumDeadline + 0.000_001)
            // Once the maximum-delay cap wins, the debounce target is no
            // longer a lower bound; it is intentionally superseded by the
            // bounded deadline.
            if debounceDeadline <= maximumDeadline {
                XCTAssertGreaterThanOrEqual(due, debounceDeadline - 0.000_001)
            }
        }
    }
}
