import Foundation

public enum CaptureProviderAvailability: Equatable, Sendable {
    case available
    case unavailable(String)
}

/// Deliberately text-only. Providers receive no vault, filesystem, command,
/// network, tool registry or permission-broker capability from Folio.
public protocol CaptureTextProvider: Sendable {
    var displayName: String { get }
    func availability() async -> CaptureProviderAvailability
    func generate(_ request: CaptureModelInput) async throws -> String
}
public enum CaptureEngineStatus: Equatable, Sendable {
    case idle
    case generating(UUID)
    case cancelling(UUID)
}

/// One provider operation at a time. A timeout/cancel returns promptly to the
/// UI, rejects all late output and retains the busy slot until the provider
/// actually ends. Cancellation is a request, not a promise to kill model compute.
public actor CaptureBroker {
    private struct Job {
        let id: UUID
        var continuation: CheckedContinuation<CaptureProposal, Error>?
        var worker: Task<Void, Never>?
        var timer: Task<Void, Never>?
        var cancelling = false
    }
    private let provider: any CaptureTextProvider
    private let testingTimeoutMilliseconds: Int?
    private var active: Job?

    public init(provider: any CaptureTextProvider, testingTimeoutMilliseconds: Int? = nil) {
        self.provider = provider
        self.testingTimeoutMilliseconds = testingTimeoutMilliseconds.map { min(60_000, max(1, $0)) }
    }
    public var status: CaptureEngineStatus {
        guard let active else { return .idle }
        return active.cancelling ? .cancelling(active.id) : .generating(active.id)
    }
    public var providerName: String { provider.displayName }
    public func availability() async -> CaptureProviderAvailability { await provider.availability() }

    public func generate(_ request: PreparedCapture) async throws -> CaptureProposal {
        try Task.checkCancellation()
        guard active == nil else { throw CaptureError.busy }
        let requestID = request.id
        // Reserve before the first suspension; a second caller cannot race two
        // continuations into the same provider slot.
        active = Job(id: requestID, continuation: nil)
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                guard active?.id == requestID, active?.cancelling == false, !Task<Never, Never>.isCancelled else {
                    if active?.id == requestID { active = nil }
                    continuation.resume(throwing: CaptureError.cancelled); return
                }
                active?.continuation = continuation
                let worker = Task { await self.perform(request) }
                let wait = testingTimeoutMilliseconds ?? request.budget.timeoutMilliseconds
                let timer = Task {
                    do { try await Task.sleep(for: .milliseconds(wait)) } catch { return }
                    self.stop(requestID, error: .timedOut)
                }
                active?.worker = worker; active?.timer = timer
            }
        }, onCancel: {
            Task { await self.cancel(requestID: requestID) }
        })
    }
    public func cancel(requestID: UUID) { stop(requestID, error: .cancelled) }

    private func perform(_ request: PreparedCapture) async {
        do {
            try Task.checkCancellation()
            let available = await provider.availability()
            guard active?.id == request.id, active?.cancelling == false else { finish(request.id, result: .failure(CaptureError.cancelled)); return }
            guard case .available = available else {
                if case .unavailable(let reason) = available { throw CaptureError.unavailable(reason) }
                throw CaptureError.providerFailed
            }
            let output = try await provider.generate(request.modelInput)
            try Task.checkCancellation()
            guard active?.id == request.id, active?.cancelling == false else { finish(request.id, result: .failure(CaptureError.cancelled)); return }
            let proposal = try CaptureProposal.make(request: request, output: output)
            finish(request.id, result: .success(proposal))
        } catch {
            let safe: CaptureError
            if error is CancellationError { safe = .cancelled }
            else if let known = error as? CaptureError { safe = known }
            else { safe = .providerFailed } // Never surface provider/debug prompt contents.
            finish(request.id, result: .failure(safe))
        }
    }
    private func stop(_ id: UUID, error: CaptureError) {
        guard var job = active, job.id == id else { return }
        if job.cancelling { return }
        job.cancelling = true
        let waiter = job.continuation; job.continuation = nil
        active = job
        job.timer?.cancel(); job.worker?.cancel()
        waiter?.resume(throwing: error)
        // Intentionally NOT active = nil: an uncooperative provider may still run.
    }
    private func finish(_ id: UUID, result: Result<CaptureProposal, Error>) {
        guard let job = active, job.id == id else { return }
        job.timer?.cancel()
        active = nil
        if !job.cancelling { job.continuation?.resume(with: result) }
    }
}
