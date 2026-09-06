import XCTest
@testable import AICameraCore

final class SpokenTranslationTests: XCTestCase {
    func testExplicitEnableFreshCaptureAndAllGenerationEdges() {
        let state = SpokenTranslationState()
        XCTAssertFalse(state.snapshot.enabled)
        let on = state.set(enabled: true, targetLanguage: "es", agentBusy: false, now: 10)
        XCTAssertFalse(state.permits(on, capturedAt: 9, now: 11))
        XCTAssertTrue(state.permits(on, capturedAt: 10, now: 11))
        XCTAssertFalse(state.permits(on, capturedAt: 10, now: 31))
        XCTAssertFalse(state.permits(on, capturedAt: .nan, now: 11))
        XCTAssertFalse(state.permits(on, capturedAt: 12, now: 11))
        state.set(enabled: false, targetLanguage: "es", agentBusy: false, now: 12)
        let again = state.set(enabled: true, targetLanguage: "es", agentBusy: false, now: 13)
        XCTAssertFalse(state.permits(on, capturedAt: 10, now: 14))
        XCTAssertTrue(state.permits(again, capturedAt: 13, now: 14))
        state.set(enabled: true, targetLanguage: "fr", agentBusy: false, now: 15)
        XCTAssertFalse(state.permits(again, capturedAt: 13, now: 16))
        let french = state.snapshot
        state.set(enabled: true, targetLanguage: "fr", agentBusy: false, sourceLanguage: "en", now: 17)
        XCTAssertFalse(state.permits(french, capturedAt: 15, now: 18))
    }

    func testAgentAnswerDiscardsOldWorkAndResumesOnlyFreshSpeech() {
        let state = SpokenTranslationState()
        let before = state.set(enabled: true, targetLanguage: "es", agentBusy: false, now: 0)
        let busy = state.set(enabled: true, targetLanguage: "es", agentBusy: true, now: 1)
        XCTAssertFalse(state.permits(before, capturedAt: 0, now: 2))
        XCTAssertFalse(state.permits(busy, capturedAt: 1, now: 2))
        let resumed = state.set(enabled: true, targetLanguage: "es", agentBusy: false, now: 3)
        XCTAssertFalse(state.permits(before, capturedAt: 0, now: 4))
        XCTAssertFalse(state.permits(resumed, capturedAt: 2, now: 4))
        XCTAssertTrue(state.permits(resumed, capturedAt: 3, now: 4))
    }

    func testOnlySuccessfulFinalMicrophoneTranslationCanBecomeSpeech() throws {
        let state = SpokenTranslationState()
        let voice = state.set(enabled: true, targetLanguage: "es", agentBusy: false, sourceLanguage: "en", now: 0)
        let privacy = PrivacyMuteState().snapshot
        func packet(_ outcome: TranslationOutcome) -> SpokenTranslationSegment? {
            .init(id: UUID(), outcome: outcome, capturedAt: 1, voice: voice, privacy: privacy)
        }
        let original = TranscriptEvent(text: "Hello")
        let success = try XCTUnwrap(TranslationOutcome.success(original, text: "Hola", source: .microphone,
                                                              sourceLanguage: "en", targetLanguage: "es"))
        XCTAssertEqual(packet(success)?.text, "Hola")
        for reason in TranslationOutcome.FallbackReason.allCases {
            XCTAssertNil(packet(.fallback(original, source: .microphone, sourceLanguage: "en", targetLanguage: "es", reason: reason)))
        }
        for (source, target, text) in [(TranslationSource.agent, "es", "Hola"), (.microphone, "fr", "Bonjour"),
                                     (.microphone, "es", String(repeating: "a", count: 801))] {
            XCTAssertNil(packet(try XCTUnwrap(.success(original, text: text, source: source, sourceLanguage: "en", targetLanguage: target))))
        }
    }
}
