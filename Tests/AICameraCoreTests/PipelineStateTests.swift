import XCTest
@testable import AICameraCore

final class PipelineStateTests: XCTestCase {
    func testSceneStateRejectsStaleInferenceResult() async {
        let state = SceneState()
        await state.beginFrame(.init(rawValue: 10))
        let accepted = await state.applyDetections([
            .init(label: "new", confidence: 1, boundingBox: .init(x: 0, y: 0, width: 1, height: 1))
        ], frameID: .init(rawValue: 10))
        let stale = await state.applyDetections([
            .init(label: "old", confidence: 1, boundingBox: .init(x: 0, y: 0, width: 1, height: 1))
        ], frameID: .init(rawValue: 9))
        XCTAssertTrue(accepted)
        XCTAssertFalse(stale)
        let snapshot = await state.current()
        XCTAssertEqual(snapshot.detections.first?.label, "new")
    }

    func testFastGestureDoesNotRejectIndependentDetection() async {
        let state = SceneState()
        _ = await state.applyGestures(
            [.init(kind: .openPalm, confidence: 1)],
            frameID: .init(rawValue: 20)
        )
        let accepted = await state.applyDetections(
            [.init(label: "person", confidence: 1, boundingBox: .init(x: 0, y: 0, width: 1, height: 1))],
            frameID: .init(rawValue: 10)
        )
        XCTAssertTrue(accepted)
        let snapshot = await state.current()
        XCTAssertEqual(snapshot.detections.first?.label, "person")
        XCTAssertEqual(snapshot.gestures.first?.kind, .openPalm)
    }

    func testResultsExpireIndependently() async {
        let state = SceneState()
        let old = Date(timeIntervalSince1970: 10)
        let recent = Date(timeIntervalSince1970: 20)
        _ = await state.applyDetections(
            [.init(label: "old", confidence: 1, boundingBox: .init(x: 0, y: 0, width: 1, height: 1))],
            frameID: .init(rawValue: 1),
            at: old
        )
        _ = await state.applyGestures(
            [.init(kind: .pinch, confidence: 1)],
            frameID: .init(rawValue: 2),
            at: recent
        )
        let changed = await state.expireResults(olderThan: Date(timeIntervalSince1970: 15))
        XCTAssertTrue(changed)
        let snapshot = await state.current()
        XCTAssertTrue(snapshot.detections.isEmpty)
        XCTAssertEqual(snapshot.gestures.first?.kind, .pinch)
    }

    func testSceneStateBoundsUntrustedResultCardinalityAndText() async {
        let state = SceneState()
        let detections = (0..<500).map { index in
            Detection(
                label: String(repeating: "x", count: 1_000) + "\(index)",
                confidence: 2,
                boundingBox: .init(x: 0, y: 0, width: 1, height: 1)
            )
        }
        _ = await state.applyDetections(detections, frameID: .init(rawValue: 1))
        await state.applyVisionSummary(String(repeating: "v", count: 20_000), frameID: .init(rawValue: 1))
        await state.applyTranscript(.init(text: String(repeating: "t", count: 20_000)))
        await state.applyAgentResponse(String(repeating: "a", count: 20_000))
        let snapshot = await state.current()
        XCTAssertEqual(snapshot.detections.count, AICameraContentLimits.detections)
        XCTAssertEqual(snapshot.detections.first?.label.count, AICameraContentLimits.labelCharacters)
        XCTAssertEqual(snapshot.detections.first?.confidence, 1)
        XCTAssertEqual(snapshot.visionSummary?.count, AICameraContentLimits.sceneTextCharacters)
        XCTAssertEqual(snapshot.transcript?.text.count, AICameraContentLimits.transcriptCharacters)
        XCTAssertEqual(snapshot.agentResponse?.count, AICameraContentLimits.agentCharacters)
    }

    func testLatestMailboxReplacesPendingValueAndFinishesWaiter() async {
        let mailbox = LatestValueMailbox<Int>()
        await mailbox.submit(1)
        await mailbox.submit(2)
        let latest = await mailbox.next()
        let replacedCount = await mailbox.replacedCount
        XCTAssertEqual(latest, 2)
        XCTAssertEqual(replacedCount, 1)

        let waiter = Task { await mailbox.next() }
        await Task.yield()
        await mailbox.finish()
        let finishedValue = await waiter.value
        XCTAssertNil(finishedValue)
    }
}
