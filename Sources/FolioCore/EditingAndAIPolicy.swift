/// Confirmed personal answers 05–08. These are domain policies, not claims
/// that preview rendering, speech or a model provider have been implemented.
public struct EditorNavigationPolicy: Equatable, Sendable {
    public let preserveSourceCursor = true
    public let previewFollowsOnlyOnExplicitAction = true
    public let automaticallySynchroniseScroll = false
    public init() {}
}

public enum AIReviewMode: String, CaseIterable, Sendable {
    case wholeDraft
    case sections
    case detailedComparison
}

public struct AIInteractionPolicy: Equatable, Sendable {
    public let transcriptConfirmationRequired = true
    public let availableReviewModes = AIReviewMode.allCases
    // Q07: let the user choose; do not silently select a fixed review mode.
    public let initialReviewMode: AIReviewMode? = nil
    public let contextListAlwaysVisible = true
    public let contextCanBeExplicitlyAddedOrRemoved = true
    public let silentlyExpandContext = false
    public init() {}

    public func mayRestructureTranscript(userConfirmedTranscript: Bool) -> Bool {
        userConfirmedTranscript
    }
}
