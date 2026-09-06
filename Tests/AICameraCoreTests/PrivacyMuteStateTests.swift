import XCTest
@testable import AICameraCore

final class PrivacyMuteStateTests: XCTestCase {
    func testBothEdgesRetireOldSpeechAndRepeatedMuteDoesNotRearm() {
        let gate = PrivacyMuteState()
        let original = gate.snapshot
        XCTAssertTrue(gate.permitsSpeech(original))
        let muted = gate.setMuted(true)
        XCTAssertFalse(gate.permitsSpeech(original))
        XCTAssertFalse(gate.permitsSpeech(muted))
        XCTAssertEqual(gate.setMuted(true), muted)
        let unmuted = gate.setMuted(false)
        XCTAssertFalse(gate.permitsSpeech(original))
        XCTAssertFalse(gate.permitsSpeech(muted))
        XCTAssertTrue(gate.permitsSpeech(unmuted))
    }

    func testRetiredSceneLosesSpeechButKeepsCameraObservations() {
        let gate = PrivacyMuteState()
        let original = gate.snapshot
        var scene = SceneSnapshot()
        scene.transcript = TranscriptEvent(text: "private speech")
        scene.agentResponse = "private response"
        scene.gestures = [GestureObservation(kind: .closedFist, confidence: 0.9)]
        scene.status = "AI Camera"
        gate.setMuted(true)
        gate.setMuted(false)
        let filtered = gate.filtered(scene, from: original)
        XCTAssertNil(filtered.transcript)
        XCTAssertNil(filtered.agentResponse)
        XCTAssertEqual(filtered.gestures, scene.gestures)
        XCTAssertEqual(filtered.status, "AI Camera")
    }

    func testLateActorWriteCannotBecomeANewGenerationCaption() async {
        let scene = SceneState()
        await scene.applyTranscript(.init(text: "old"), privacyGeneration: 0)
        await scene.applyAgentResponse("old", privacyGeneration: 0)
        await scene.clearSpeech()
        // A cancelled model can still complete after the clear and after unmute.
        await scene.applyTranscript(.init(text: "late"), privacyGeneration: 0)
        await scene.applyAgentResponse("late", privacyGeneration: 0)
        let retired = await scene.current(privacyGeneration: 2)
        XCTAssertNil(retired.transcript)
        XCTAssertNil(retired.agentResponse)
        await scene.applyTranscript(.init(text: "fresh"), privacyGeneration: 2)
        let fresh = await scene.current(privacyGeneration: 2)
        XCTAssertEqual(fresh.transcript?.text, "fresh")
        XCTAssertNil(fresh.agentResponse)
    }

    func testRestoredMuteStartsClosed() {
        let gate = PrivacyMuteState(isMuted: true)
        XCTAssertFalse(gate.permitsSpeech(gate.snapshot))
    }
}
