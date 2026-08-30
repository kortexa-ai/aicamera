import XCTest
@testable import AICameraCore

final class HandGestureClassifierTests: XCTestCase {
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
