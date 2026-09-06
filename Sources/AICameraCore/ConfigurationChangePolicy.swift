import Foundation

public enum ConfigurationChangePolicy: Equatable, Sendable {
    case unchanged, translationLanguages, restartMedia

    /// Only source/target language changes can reuse the existing media graph and model client.
    /// Compare every other field so a simultaneous device, privacy, or provider change still restarts.
    public static func classify(from previous: AICameraConfiguration, to next: AICameraConfiguration) -> Self {
        if previous == next { return .unchanged }
        var languageOnly = previous
        languageOnly.pipeline.translation.sourceLanguage = next.pipeline.translation.sourceLanguage
        languageOnly.pipeline.translation.targetLanguage = next.pipeline.translation.targetLanguage
        return languageOnly == next ? .translationLanguages : .restartMedia
    }
}
