import Foundation

public struct SpeechAssetConsent: Sendable {
    public let id: UUID
    public let locale: String
    private init(locale: String) { id = UUID(); self.locale = locale }
    /// The selected resolved locale is shown before consent. A capability check
    /// never authorises a download or opens a microphone by itself.
    public static func approve(capability: SpeechCapability, displayedLocale: String, userConfirmedDownload: Bool) throws -> Self {
        guard userConfirmedDownload else { throw VoiceError.consentRequired }
        guard case .needsAssets(let locale) = capability else { throw VoiceError.invalidState }
        guard displayedLocale == locale else { throw VoiceError.unsupportedLocale }
        return .init(locale: locale)
    }
}
