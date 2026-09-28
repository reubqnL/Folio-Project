import XCTest
import Foundation
@testable import FolioCore

private actor ControlledCaptureProvider: CaptureTextProvider {
    nonisolated let displayName = "Generated test fixture — not a model"
    private let ready: CaptureProviderAvailability
    private let immediate: String?
    private var waiters: [CheckedContinuation<String, Error>] = []
    private var started: [CheckedContinuation<Void, Never>] = []
    private(set) var requests: [CaptureModelInput] = []
    init(ready: CaptureProviderAvailability = .available, immediate: String? = nil) { self.ready = ready; self.immediate = immediate }
    func availability() async -> CaptureProviderAvailability { ready }
    func generate(_ input: CaptureModelInput) async throws -> String {
        requests.append(input)
        for waiter in started { waiter.resume() }; started = []
        if let immediate { return immediate }
        // Intentionally ignores cancellation until the test releases it.
        return try await withCheckedThrowingContinuation { waiters.append($0) }
    }
    func waitForStart() async {
        if !requests.isEmpty { return }
        await withCheckedContinuation { started.append($0) }
    }
    func complete(_ output: String) { let old = waiters; waiters = []; for waiter in old { waiter.resume(returning: output) } }
    func fail() { let old = waiters; waiters = []; for waiter in old { waiter.resume(throwing: SensitiveFailure()) } }
    struct SensitiveFailure: Error, LocalizedError { var errorDescription: String? { "DO_NOT_EXPOSE_PROVIDER_PROMPT_OR_SECRET" } }
}

final class CaptureBrokerTests: XCTestCase, @unchecked Sendable {
    private func waitForIdle(_ broker: CaptureBroker) async throws {
        for _ in 0..<100 {
            if await broker.status == .idle { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("Provider slot did not return to idle")
    }
    func testUnavailableProviderIsNotInvokedAndNoFallbackOccurs() async throws {
        let provider = ControlledCaptureProvider(ready: .unavailable("disabled"), immediate: "should never generate")
        let broker = CaptureBroker(provider: provider)
        let request = try CaptureFixtures.request(CaptureFixtures.target())
        do { _ = try await broker.generate(request); XCTFail("Expected unavailable") }
        catch CaptureError.unavailable { }
        let calls = await provider.requests
        XCTAssertTrue(calls.isEmpty)
        let state = await broker.status; XCTAssertEqual(state, .idle)
    }
    func testGenerationReturnsUnappliedReviewNotAWrittenNote() async throws {
        let provider = ControlledCaptureProvider(immediate: "# Fixture\nA proposed paragraph")
        let broker = CaptureBroker(provider: provider)
        let target = try CaptureFixtures.target("Unchanged source")
        let result = try await broker.generate(CaptureFixtures.request(target))
        XCTAssertEqual(result.target.text, "Unchanged source")
        XCTAssertFalse(result.replacement.isEmpty)
        let state = await broker.status; XCTAssertEqual(state, .idle)
    }
    func testASecondGenerationCannotRaceTheSameProviderSlot() async throws {
        let provider = ControlledCaptureProvider()
        let broker = CaptureBroker(provider: provider)
        let request = try CaptureFixtures.request(CaptureFixtures.target())
        let first = Task { try await broker.generate(request) }
        await provider.waitForStart()
        do { _ = try await broker.generate(CaptureFixtures.request(CaptureFixtures.target())); XCTFail("Expected busy") }
        catch CaptureError.busy { }
        await provider.complete("First draft")
        _ = try await first.value
        let requests = await provider.requests; XCTAssertEqual(requests.count, 1)
    }
    func testExplicitCancelReturnsButKeepsUncooperativeProviderBusy() async throws {
        let provider = ControlledCaptureProvider()
        let broker = CaptureBroker(provider: provider)
        let request = try CaptureFixtures.request(CaptureFixtures.target())
        let first = Task { try await broker.generate(request) }
        await provider.waitForStart()
        await broker.cancel(requestID: request.id)
        do { _ = try await first.value; XCTFail("Expected cancellation") }
        catch CaptureError.cancelled { }
        let state = await broker.status; XCTAssertEqual(state, .cancelling(request.id))
        do { _ = try await broker.generate(CaptureFixtures.request(CaptureFixtures.target())); XCTFail("Cancelled compute still holds its slot") }
        catch CaptureError.busy { }
        await provider.complete("LATE_OUTPUT_MUST_NOT_APPLY")
        try await waitForIdle(broker)
    }
    func testTimeoutDiscardsLateOutputAndDoesNotSpawnParallelJobs() async throws {
        let provider = ControlledCaptureProvider()
        let broker = CaptureBroker(provider: provider, testingTimeoutMilliseconds: 30)
        let request = try CaptureFixtures.request(CaptureFixtures.target())
        let task = Task { try await broker.generate(request) }
        await provider.waitForStart()
        do { _ = try await task.value; XCTFail("Expected timeout") }
        catch CaptureError.timedOut { }
        let state = await broker.status; XCTAssertEqual(state, .cancelling(request.id))
        await provider.complete("Too late")
        try await waitForIdle(broker)
    }
    func testParentTaskCancellationInvalidatesTheResult() async throws {
        let provider = ControlledCaptureProvider()
        let broker = CaptureBroker(provider: provider)
        let request = try CaptureFixtures.request(CaptureFixtures.target())
        let task = Task { try await broker.generate(request) }
        await provider.waitForStart(); task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError || (error as? CaptureError) == .cancelled) }
        await provider.complete("Late")
        try await waitForIdle(broker)
    }
    func testForeignCancellationIDDoesNotCancelCurrentWork() async throws {
        let provider = ControlledCaptureProvider()
        let broker = CaptureBroker(provider: provider)
        let request = try CaptureFixtures.request(CaptureFixtures.target())
        let task = Task { try await broker.generate(request) }
        await provider.waitForStart(); await broker.cancel(requestID: UUID())
        let state = await broker.status; XCTAssertEqual(state, .generating(request.id))
        await provider.complete("Valid draft"); _ = try await task.value
    }
    func testProviderDebugErrorsAreNotExposed() async throws {
        let provider = ControlledCaptureProvider()
        let broker = CaptureBroker(provider: provider)
        let task = Task { try await broker.generate(CaptureFixtures.request(CaptureFixtures.target())) }
        await provider.waitForStart(); await provider.fail()
        do { _ = try await task.value; XCTFail("Expected failure") }
        catch {
            XCTAssertEqual(error as? CaptureError, .providerFailed)
            XCTAssertFalse(error.localizedDescription.contains("DO_NOT_EXPOSE"))
        }
    }
    func testMaliciousOrOversizedProviderOutputCannotBecomeAProposal() async throws {
        for text in ["bad\0output", String(repeating: "x", count: 40_000), "---\nid: rewrite\n---\ntext"] {
            let broker = CaptureBroker(provider: ControlledCaptureProvider(immediate: text))
            do { _ = try await broker.generate(CaptureFixtures.request(CaptureFixtures.target())); XCTFail("Expected output validation") }
            catch { XCTAssertTrue(error is CaptureError) }
        }
    }
    func testProviderOnlyReceivesTheExplicitSerializedContext() async throws {
        let provider = ControlledCaptureProvider(immediate: "# Review\nOrganised text")
        let broker = CaptureBroker(provider: provider)
        let target = try CaptureFixtures.target("SECRET_TARGET_NOT_SELECTED")
        let request = try CaptureFixtures.request(target, input: "approved material")
        _ = try await broker.generate(request)
        let calls = await provider.requests
        XCTAssertEqual(calls.count, 1)
        XCTAssertFalse(calls[0].payloadJSON.contains("SECRET_TARGET_NOT_SELECTED"))
        XCTAssertEqual(calls[0].maximumOutputTokens, CaptureBudget(profile: .balanced).maximumOutputTokens)
        XCTAssertEqual(calls[0].requestDigest, request.modelInput.requestDigest)
    }
    func testImmediateCallerCancellationCannotLeaveAnUnusableReservedSlot() async throws {
        let provider = ControlledCaptureProvider(immediate: "Immediate fixture")
        let broker = CaptureBroker(provider: provider)
        let request = try CaptureFixtures.request(CaptureFixtures.target())
        let task = Task { try await broker.generate(request) }
        task.cancel()
        _ = try? await task.value
        try await waitForIdle(broker)
        let fresh = try await broker.generate(CaptureFixtures.request(CaptureFixtures.target()))
        XCTAssertEqual(fresh.rawOutput, "Immediate fixture")
    }

}
