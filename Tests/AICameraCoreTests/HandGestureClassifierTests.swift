import XCTest
@testable import AICameraCore

final class HandGestureClassifierTests: XCTestCase {
    func testCompactFistWinsOverThumbIndexContactAcrossHandOrientations() {
        for offset in [0.0, 0.04, 0.08] {
            var fist = hand(extended: [false, false, false, false])
            let index = fist[.indexTip]!
            fist[.thumbTip] = .init(x: index.x + offset, y: index.y)
            for angle in [0.0, Double.pi / 2, .pi, .pi * 1.5] {
                for scale in [0.65, 1.0, 1.3] {
                    for mirror in [-1.0, 1.0] {
                        let transformed = fist.mapValues { point in
                            let x = (point.x - 0.5) * scale * mirror
                            let y = (point.y - 0.25) * scale
                            return NormalizedPoint(x: 0.5 + x * cos(angle) - y * sin(angle),
                                                   y: 0.5 + x * sin(angle) + y * cos(angle))
                        }
                        XCTAssertEqual(HandGestureClassifier.classify(transformed), .closedFist)
                    }
                }
            }
        }
    }

    func testTuckedThumbFistMutesAnActivatedAgentOnce() {
        let victory = hand(extended: [true, true, false, false])
        var fist = hand(extended: [false, false, false, false])
        fist[.thumbTip] = fist[.indexTip]
        var gate = GestureControlGate()
        let actions = (0...28).compactMap { index -> GestureControlAction? in
            let pose = index < 12 ? victory : fist
            let kind = HandGestureClassifier.classify(pose)!
            let time = 10 + Double(index) * 0.125
            return gate.observe([.init(kind: kind, confidence: 0.95)], capturedAt: time, now: time)
        }
        XCTAssertEqual(actions, [.startAgent, .mute])
    }

    func testCurledIndexPinchWithOtherFingersExtendedIsPreserved() {
        var pinch = hand(extended: [false, true, true, true])
        pinch[.thumbTip] = pinch[.indexTip]
        XCTAssertEqual(HandGestureClassifier.classify(pinch), .pinch)
    }

    func testThumbIndexContactOutsideCompactPalmRemainsPinch() {
        var pinch = hand(extended: [false, false, false, false])
        pinch[.indexTip] = .init(x: 0.4, y: 0.8)
        pinch[.indexPIP] = .init(x: 0.4, y: 0.85)
        pinch[.thumbTip] = pinch[.indexTip]
        XCTAssertEqual(HandGestureClassifier.classify(pinch), .pinch)
    }

    func testPartlyOccludedFoldedJointDoesNotBlockAnOtherwiseClearHeldVictory() {
        let confidences = Array(repeating: 0.95, count: 12) + [0.4, 0.45]
        let confidence = HandGestureClassifier.observationConfidence(confidences)
        XCTAssertGreaterThan(confidence, 0.8)
        let kind = HandGestureClassifier.classify(hand(extended: [true, true, false, false]))!
        var gate = GestureControlGate()
        let actions = (0...10).compactMap { index in
            let time = 10 + Double(index) * 0.125
            return gate.observe([.init(kind: kind, confidence: confidence)], capturedAt: time, now: time)
        }
        XCTAssertEqual(actions, [.startAgent])
    }

    func testUncertainMissingAndInvalidJointsStillDenyActivationConfidence() {
        XCTAssertLessThan(HandGestureClassifier.observationConfidence(Array(repeating: 0.6, count: 14)), 0.8)
        XCTAssertEqual(HandGestureClassifier.observationConfidence(Array(repeating: 0.95, count: 13)), 0)
        for value in [0.24, Double.nan, .infinity, 1.01] {
            XCTAssertEqual(HandGestureClassifier.observationConfidence(Array(repeating: 0.95, count: 13) + [value]), 0)
        }
    }

    func testClassifiesExtendedFingerPatterns() {
        XCTAssertEqual(HandGestureClassifier.classify(hand(extended: [true, true, true, true])), .openPalm)
        XCTAssertEqual(HandGestureClassifier.classify(hand(extended: [true, true, false, false])), .victory)
        XCTAssertEqual(HandGestureClassifier.classify(hand(extended: [true, false, false, false])), .pointing)
        XCTAssertEqual(HandGestureClassifier.classify(hand(extended: [false, false, false, false])), .closedFist)
    }

    func testClassificationIsRotationIndependent() {
        let upright = hand(extended: [true, true, false, false])
        let sideways = upright.mapValues { point in
            NormalizedPoint(x: 0.5 - (point.y - 0.5), y: 0.5 + (point.x - 0.5))
        }
        XCTAssertEqual(HandGestureClassifier.classify(sideways), .victory)
    }

    func testPinchUsesPalmRelativeDistance() {
        var landmarks = hand(extended: [true, false, false, false])
        landmarks[.thumbTip] = .init(x: 0.405, y: 0.875)
        XCTAssertEqual(HandGestureClassifier.classify(landmarks), .pinch)
    }

    func testMissingOrDegeneratePalmReturnsNil() {
        XCTAssertNil(HandGestureClassifier.classify([:]))
        var landmarks = hand(extended: [true, true, true, true])
        landmarks[.middleMCP] = landmarks[.wrist]
        XCTAssertNil(HandGestureClassifier.classify(landmarks))
    }

    private func hand(extended: [Bool]) -> [HandJoint: NormalizedPoint] {
        let wrist = NormalizedPoint(x: 0.5, y: 0.25)
        var result: [HandJoint: NormalizedPoint] = [
            .wrist: wrist,
            .thumbTip: .init(x: 0.25, y: 0.55),
        ]
        let joints: [(HandJoint, HandJoint, HandJoint, Double)] = [
            (.indexTip, .indexPIP, .indexMCP, 0.40),
            (.middleTip, .middlePIP, .middleMCP, 0.48),
            (.ringTip, .ringPIP, .ringMCP, 0.56),
            (.littleTip, .littlePIP, .littleMCP, 0.64),
        ]
        for (offset, joint) in joints.enumerated() {
            let mcp = NormalizedPoint(x: joint.3, y: 0.48)
            result[joint.2] = mcp
            if extended[offset] {
                result[joint.1] = .init(x: joint.3, y: 0.66)
                result[joint.0] = .init(x: joint.3, y: 0.88)
            } else {
                result[joint.1] = .init(x: joint.3, y: 0.60)
                result[joint.0] = .init(x: joint.3 + 0.02, y: 0.42)
            }
        }
        return result
    }
}
