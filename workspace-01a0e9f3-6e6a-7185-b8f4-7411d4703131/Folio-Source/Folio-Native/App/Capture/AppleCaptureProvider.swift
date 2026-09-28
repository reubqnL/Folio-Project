import Foundation
import FolioCore
#if canImport(FoundationModels)
import FoundationModels
#endif

/// The production adapter selects Apple's on-device system model only.
/// No Tool is supplied; no cloud/MLX/HTTP fallback or cross-project conversation
/// is created. Mac SDK compilation and actual inference are still required gates.
actor AppleCaptureProvider: CaptureTextProvider {
    nonisolated let displayName = "Apple on-device model"

    func availability() async -> CaptureProviderAvailability {
        #if canImport(FoundationModels)
        switch SystemLanguageModel.default.availability {
        case .available: return .available
        case .unavailable(let reason):
            switch reason {
            case .appleIntelligenceNotEnabled: return .unavailable("Apple Intelligence is not enabled in system settings.")
            case .deviceNotEligible: return .unavailable("This device is not eligible for the system language model.")
            case .modelNotReady: return .unavailable("The system model is not ready. Text editing remains available.")
            @unknown default: return .unavailable("The system has not made the local model available.")
            }
        @unknown default: return .unavailable("Unknown system model availability.")
        }
        #else
        return .unavailable("Foundation Models is not present in this build environment.")
        #endif
    }
    func generate(_ request: CaptureModelInput) async throws -> String {
        #if canImport(FoundationModels)
        try Task.checkCancellation()
        guard case .available = await availability() else { throw CaptureError.unavailable("The local system model is not ready.") }
        // Fresh single-turn session: no prior note or project's transcript survives
        // into this request. The tool list is explicitly empty.
        let session = LanguageModelSession(model: SystemLanguageModel.default, tools: []) {
            request.instructions
        }
        let options = GenerationOptions(temperature: 0.15, maximumResponseTokens: request.maximumOutputTokens)
        do {
            let result = try await session.respond(to: request.payloadJSON, options: options)
            try Task.checkCancellation()
            return result.content
        } catch {
            if Task<Never, Never>.isCancelled { throw CancellationError() }
            // Provider diagnostics/transcripts are never copied into user-visible
            // errors or logs; input is kept for explicit narrowing/retry.
            throw CaptureError.providerFailed
        }
        #else
        throw CaptureError.unavailable("Foundation Models is not present in this build environment.")
        #endif
    }
}
