import Foundation

/// Host-assigned origin. Agent-response captions must never become interpreted microphone speech.
public enum TranslationSource: Equatable, Sendable { case microphone, agent }

/// Translation data, not permission to play audio. Consumers must still check freshness,
/// privacy, feature generations, utterance identity, and speech-output ownership.
public struct TranslationOutcome: Equatable, Sendable {
    public enum FallbackReason: CaseIterable, Equatable, Sendable {
        case disabled, partial, modelUnavailable, superseded, cancelled, failed, invalidOutput
    }
    public enum Status: Equatable, Sendable { case translated, original(FallbackReason) }

    public let original: TranscriptEvent
    public let caption: TranscriptEvent
    public let source: TranslationSource
    /// Requested configuration values; auto/system are not detected/resolved language claims.
    public let requestedSourceLanguage: String
    public let requestedTargetLanguage: String
    public let status: Status

    public var translatedMicrophoneText: String? {
        status == .translated && source == .microphone && original.mode == .final ? caption.text : nil
    }

    public static func fallback(_ original: TranscriptEvent, source: TranslationSource,
                                sourceLanguage: String, targetLanguage: String,
                                reason: FallbackReason) -> Self {
        Self(original: original, caption: original, source: source, requestedSourceLanguage: sourceLanguage,
             requestedTargetLanguage: targetLanguage, status: .original(reason))
    }

    public static func success(_ original: TranscriptEvent, text: String, source: TranslationSource,
                               sourceLanguage: String, targetLanguage: String) -> Self? {
        guard original.mode == .final, valid(original.text, maximumBytes: 32_768),
              original.text.count <= AICameraContentLimits.transcriptCharacters, valid(text, maximumBytes: 32_768),
              text.count <= AICameraContentLimits.transcriptCharacters,
              valid(sourceLanguage, maximumBytes: 128), valid(targetLanguage, maximumBytes: 128) else { return nil }
        let caption = TranscriptEvent(text: text, mode: original.mode,
                                      startSeconds: original.startSeconds, endSeconds: original.endSeconds)
        return Self(original: original, caption: caption, source: source,
                    requestedSourceLanguage: sourceLanguage, requestedTargetLanguage: targetLanguage,
                    status: .translated)
    }

    private static func valid(_ value: String, maximumBytes: Int) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.utf8.count <= maximumBytes
            && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\t" }
    }
}
