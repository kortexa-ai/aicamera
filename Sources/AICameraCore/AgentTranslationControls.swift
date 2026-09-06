import Foundation

public struct TranslationLanguageChoice: Equatable, Sendable {
    public let code: String
    public let name: String
    public init(code: String, name: String) { self.code = code; self.name = name }
}

/// The same supported language choices drive Settings and the agent tool schema.
public enum TranslationLanguageCatalog {
    public static let languages = [
        TranslationLanguageChoice(code: "en", name: "English"), TranslationLanguageChoice(code: "zh", name: "Chinese"),
        TranslationLanguageChoice(code: "zh-Hant", name: "Traditional Chinese"), TranslationLanguageChoice(code: "es", name: "Spanish"),
        TranslationLanguageChoice(code: "fr", name: "French"), TranslationLanguageChoice(code: "de", name: "German"),
        TranslationLanguageChoice(code: "it", name: "Italian"), TranslationLanguageChoice(code: "pt", name: "Portuguese"),
        TranslationLanguageChoice(code: "ja", name: "Japanese"), TranslationLanguageChoice(code: "ko", name: "Korean"),
        TranslationLanguageChoice(code: "ar", name: "Arabic"), TranslationLanguageChoice(code: "ru", name: "Russian"),
        TranslationLanguageChoice(code: "uk", name: "Ukrainian"), TranslationLanguageChoice(code: "tr", name: "Turkish"),
        TranslationLanguageChoice(code: "hi", name: "Hindi"), TranslationLanguageChoice(code: "vi", name: "Vietnamese"),
        TranslationLanguageChoice(code: "th", name: "Thai"), TranslationLanguageChoice(code: "id", name: "Indonesian"),
        TranslationLanguageChoice(code: "ms", name: "Malay"), TranslationLanguageChoice(code: "tl", name: "Filipino"),
        TranslationLanguageChoice(code: "pl", name: "Polish"), TranslationLanguageChoice(code: "cs", name: "Czech"),
        TranslationLanguageChoice(code: "nl", name: "Dutch"), TranslationLanguageChoice(code: "he", name: "Hebrew"),
        TranslationLanguageChoice(code: "fa", name: "Persian"), TranslationLanguageChoice(code: "ur", name: "Urdu"),
        TranslationLanguageChoice(code: "bn", name: "Bengali"), TranslationLanguageChoice(code: "ta", name: "Tamil"),
        TranslationLanguageChoice(code: "te", name: "Telugu"), TranslationLanguageChoice(code: "mr", name: "Marathi"),
        TranslationLanguageChoice(code: "gu", name: "Gujarati"), TranslationLanguageChoice(code: "km", name: "Khmer"),
        TranslationLanguageChoice(code: "my", name: "Burmese"), TranslationLanguageChoice(code: "bo", name: "Tibetan"),
        TranslationLanguageChoice(code: "kk", name: "Kazakh"), TranslationLanguageChoice(code: "mn", name: "Mongolian"),
        TranslationLanguageChoice(code: "ug", name: "Uyghur"), TranslationLanguageChoice(code: "yue", name: "Cantonese"),
    ]
    public static let targetCodes = ["system"] + languages.map(\.code)
    public static func name(for code: String) -> String {
        if code == "system" { return "System Language" }
        if code == "auto" { return "Auto-detect" }
        return languages.first { $0.code == code }?.name ?? code
    }
}

public struct AgentTranslationRequest: Equatable, Sendable {
    public let enabled: Bool?
    public let targetLanguage: String?

    public init?(enabled: Bool? = nil, targetLanguage: String? = nil) {
        guard enabled != nil || targetLanguage != nil,
              targetLanguage.map({ TranslationLanguageCatalog.targetCodes.contains($0) }) ?? true else { return nil }
        self.enabled = enabled; self.targetLanguage = targetLanguage
    }
}
