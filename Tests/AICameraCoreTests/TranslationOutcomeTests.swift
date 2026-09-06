import XCTest
@testable import AICameraCore

final class TranslationOutcomeTests: XCTestCase {
    func testSuccessfulMicrophoneTranslationPreservesCaptionTimingAndRequestMetadata() throws {
        let original = TranscriptEvent(text: "Hello", startSeconds: 1.5, endSeconds: 3)
        let result = try XCTUnwrap(TranslationOutcome.success(original, text: "Hola", source: .microphone,
                                                             sourceLanguage: "auto", targetLanguage: "system"))
        XCTAssertEqual(result.status, .translated)
        XCTAssertEqual(result.original, original)
        XCTAssertEqual(result.caption, .init(text: "Hola", startSeconds: 1.5, endSeconds: 3))
        XCTAssertEqual(result.translatedMicrophoneText, "Hola")
        XCTAssertEqual(result.requestedSourceLanguage, "auto")
        XCTAssertEqual(result.requestedTargetLanguage, "system")
    }

    func testAgentTranslationRemainsDisplayableWithoutBecomingMicrophoneSpeech() throws {
        let result = try XCTUnwrap(TranslationOutcome.success(.init(text: "The answer is three."),
            text: "La respuesta es tres.", source: .agent, sourceLanguage: "en", targetLanguage: "es"))
        XCTAssertEqual(result.status, .translated)
        XCTAssertEqual(result.caption.text, "La respuesta es tres.")
        XCTAssertNil(result.translatedMicrophoneText)
    }

    func testEveryFallbackPreservesOriginalWithoutSpeechText() {
        for source in [TranslationSource.microphone, .agent] {
            for reason in TranslationOutcome.FallbackReason.allCases {
                let original = TranscriptEvent(text: "Keep the original", startSeconds: 2, endSeconds: 4)
                let result = TranslationOutcome.fallback(original, source: source,
                    sourceLanguage: "en", targetLanguage: "es", reason: reason)
                XCTAssertEqual(result.status, .original(reason))
                XCTAssertEqual(result.caption, original)
                XCTAssertNil(result.translatedMicrophoneText)
            }
        }
    }

    func testUnfinalizedOrInvalidResultsCannotBecomeSuccessfulTranslations() {
        for text in ["", " \n\t", "Bad\0text", String(repeating: "a", count: 8_193),
                     String(repeating: "👩🏽‍💻", count: 3_000)] {
            XCTAssertNil(TranslationOutcome.success(.init(text: "Source"), text: text, source: .microphone,
                                                   sourceLanguage: "en", targetLanguage: "es"))
        }
        for original in [TranscriptEvent(text: "Partial", mode: .partial), .init(text: ""),
                         .init(text: String(repeating: "a", count: 8_193))] {
            XCTAssertNil(TranslationOutcome.success(original, text: "Valid", source: .microphone,
                                                   sourceLanguage: "en", targetLanguage: "es"))
        }
        XCTAssertNil(TranslationOutcome.success(.init(text: "Source"), text: "Valid", source: .microphone,
                                               sourceLanguage: "en", targetLanguage: ""))
        XCTAssertNotNil(TranslationOutcome.success(.init(text: "Source"), text: String(repeating: "猫", count: 8_192),
                                                  source: .microphone, sourceLanguage: "en", targetLanguage: "zh"))
    }
}
