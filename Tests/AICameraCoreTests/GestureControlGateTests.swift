import XCTest
@testable import AICameraCore

final class GestureControlGateTests: XCTestCase {
    private func pose(_ kind: GestureKind, confidence: Double = 0.95) -> [GestureObservation] {
        [.init(kind: kind, confidence: confidence)]
    }

    private func hold(_ kind: GestureKind, from start: Double, gate: inout GestureControlGate) -> [GestureControlAction] {
        (0...10).compactMap { index in
            let time = start + Double(index) * 0.1
            return gate.observe(pose(kind), capturedAt: time, now: time)
        }
    }

    func testHeldPoseFiresOnceAndDifferentPoseCanMuteWithoutNeutral() {
        var gate = GestureControlGate()
        XCTAssertEqual(hold(.victory, from: 10, gate: &gate), [.startAgent])
        XCTAssertTrue(hold(.victory, from: 11.1, gate: &gate).isEmpty)
        XCTAssertEqual(hold(.closedFist, from: 12.2, gate: &gate), [.mute])
        XCTAssertTrue(hold(.closedFist, from: 13.3, gate: &gate).isEmpty)
    }

    func testNeutralRearmsSamePose() {
        var gate = GestureControlGate()
        XCTAssertEqual(hold(.closedFist, from: 1, gate: &gate), [.mute])
        for index in 0...4 {
            let time = 2.1 + Double(index) * 0.1
            XCTAssertNil(gate.observe([], capturedAt: time, now: time))
        }
        XCTAssertEqual(hold(.closedFist, from: 2.6, gate: &gate), [.mute])
    }

    func testBriefLowConfidenceAndConflictingHandsDoNotTrigger() {
        var gate = GestureControlGate()
        for index in 0...30 {
            let time = Double(index) * 0.1
            XCTAssertNil(gate.observe(pose(.closedFist, confidence: 0.79), capturedAt: time, now: time))
        }
        for index in 31...60 {
            let time = Double(index) * 0.1
            XCTAssertNil(gate.observe(pose(.closedFist) + pose(.victory), capturedAt: time, now: time))
        }
        XCTAssertNil(gate.observe(pose(.closedFist), capturedAt: 6.1, now: 6.1))
        XCTAssertNil(gate.observe([], capturedAt: 6.2, now: 6.2))
    }

    func testStaleOutOfOrderAndMissingFramesCannotAccumulateAHold() {
        var gate = GestureControlGate()
        XCTAssertNil(gate.observe(pose(.closedFist), capturedAt: 1, now: 1))
        XCTAssertNil(gate.observe(pose(.closedFist), capturedAt: 2, now: 3))
        XCTAssertNil(gate.observe(pose(.closedFist), capturedAt: 0.9, now: 1))
        XCTAssertNil(gate.observe(pose(.closedFist), capturedAt: .nan, now: 3))
        XCTAssertNil(gate.observe(pose(.closedFist), capturedAt: 3, now: 3))
        XCTAssertNil(gate.observe(pose(.closedFist), capturedAt: 4, now: 4))
        XCTAssertEqual(hold(.closedFist, from: 4.1, gate: &gate), [.mute])
    }
}
