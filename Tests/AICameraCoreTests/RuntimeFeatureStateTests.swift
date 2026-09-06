import XCTest
@testable import AICameraCore

final class RuntimeFeatureStateTests: XCTestCase {
    func testLanguageChangesRetireOldCaptionsWithoutResettingGestures() {
        let controls = RuntimeFeatureState()
        let old = controls.set(transcription: true, translation: true, gestures: true,
                               translationSourceLanguage: "en", translationTargetLanguage: "zh", now: 1)
        let next = controls.set(transcription: true, translation: true, gestures: true,
                                translationSourceLanguage: "en", translationTargetLanguage: "es", now: 2)
        XCTAssertFalse(controls.permitsCaptions(from: old))
        XCTAssertEqual(next.captionGeneration, old.captionGeneration + 1)
        XCTAssertEqual(next.gestureGeneration, old.gestureGeneration)
        XCTAssertEqual(next.translationTargetLanguage, "es")
        XCTAssertEqual(controls.set(transcription: true, translation: true, gestures: true,
                                     translationSourceLanguage: "en", translationTargetLanguage: "es", now: 3), next)
    }

    func testTranslationKeepsItsTranscriptionDependencyRunning() {
        let controls = RuntimeFeatureState(transcription: false, translation: true, gestures: false)
        XCTAssertTrue(controls.snapshot.needsTranscription)
        controls.set(transcription: false, translation: false, gestures: false)
        XCTAssertFalse(controls.snapshot.needsTranscription)
    }

    func testRapidOffOnRejectsOldCaptionsWithoutDroppingDetections() {
        let controls = RuntimeFeatureState()
        let old = controls.snapshot
        var scene = SceneSnapshot()
        scene.transcript = .init(text: "old")
        scene.agentResponse = "old reply"
        scene.visionSummary = "unchanged scene"
        controls.set(transcription: false, translation: false, gestures: true, now: 1)
        controls.set(transcription: true, translation: true, gestures: true, now: 2)
        let visible = controls.filtered(scene, from: old)
        XCTAssertNil(visible.transcript)
        XCTAssertNil(visible.agentResponse)
        XCTAssertEqual(visible.visionSummary, "unchanged scene")
        XCTAssertFalse(controls.permitsCaptions(from: old))
    }

    func testGestureSwitchDoesNotRetireCaptions() {
        let controls = RuntimeFeatureState()
        let old = controls.snapshot
        controls.set(transcription: true, translation: true, gestures: false, now: 10)
        XCTAssertTrue(controls.permitsCaptions(from: old))
        XCTAssertFalse(controls.permitsGesture(capturedAt: 11))
        controls.set(transcription: true, translation: true, gestures: true, now: 12)
        XCTAssertFalse(controls.permitsGesture(capturedAt: 11))
        XCTAssertTrue(controls.permitsGesture(capturedAt: 12))
        XCTAssertFalse(controls.permitsGesture(capturedAt: .nan))
    }

    func testIdempotentStateDoesNotDiscardWork() {
        let controls = RuntimeFeatureState()
        let old = controls.snapshot
        XCTAssertEqual(controls.set(transcription: true, translation: true, gestures: true), old)
    }

    func testCaptionPauseDoesNotHideAgentReply() {
        let controls = RuntimeFeatureState(transcription: false, translation: false)
        var scene = SceneSnapshot()
        scene.transcript = .init(text: "hidden")
        scene.agentResponse = "agent still speaking"
        let visible = controls.filtered(scene, from: controls.snapshot)
        XCTAssertNil(visible.transcript)
        XCTAssertEqual(visible.agentResponse, "agent still speaking")
    }

    func testSceneKeepsCaptionGenerationsAcrossActorHops() async {
        let scene = SceneState()
        await scene.applyTranscript(.init(text: "fresh"), featureGeneration: 2)
        await scene.applyAgentResponse("fresh reply", featureGeneration: 2)
        await scene.applyTranscript(.init(text: "late old"), featureGeneration: 0)
        await scene.applyAgentResponse("late old reply", featureGeneration: 0)
        let fresh = await scene.current(privacyGeneration: 0, captionGeneration: 2)
        XCTAssertEqual(fresh.transcript?.text, "fresh")
        XCTAssertEqual(fresh.agentResponse, "fresh reply")
        let afterToggle = await scene.current(privacyGeneration: 0, captionGeneration: 3)
        XCTAssertNil(afterToggle.transcript)
        XCTAssertNil(afterToggle.agentResponse)
    }

    func testReadinessUsesRequestedDotColors() {
        XCTAssertEqual(CameraReadiness.resolve(needsAttention: true, isInUse: false), .needsAttention)
        XCTAssertEqual(CameraReadiness.resolve(needsAttention: false, isInUse: false), .ready)
        XCTAssertEqual(CameraReadiness.resolve(needsAttention: false, isInUse: true), .inUse)
        XCTAssertEqual(CameraReadiness.resolve(needsAttention: true, isInUse: true), .inUse)
    }
}
