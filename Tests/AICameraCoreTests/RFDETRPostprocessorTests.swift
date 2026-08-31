import XCTest
@testable import AICameraCore

final class RFDETRPostprocessorTests: XCTestCase {
    func testDecodesSparseCOCOClassAndClampsBox() {
        var logits = Array(repeating: -20.0, count: 91)
        logits[18] = 4
        let result = RFDETRPostprocessor.detections(
            boxes: [0.1, 0.2, 0.4, 0.6],
            logits: logits,
            queryCount: 1,
            classCount: 91,
            confidence: 0.5
        )

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].label, "dog")
        XCTAssertEqual(result[0].classID, 18)
        XCTAssertEqual(result[0].boundingBox.x, 0, accuracy: 0.0001)
        XCTAssertEqual(result[0].boundingBox.y, 0, accuracy: 0.0001)
        XCTAssertEqual(result[0].boundingBox.width, 0.3, accuracy: 0.0001)
        XCTAssertEqual(result[0].boundingBox.height, 0.5, accuracy: 0.0001)
    }

    func testUsesIndependentClassScoresAndStableDescendingOrder() {
        var logits = Array(repeating: -20.0, count: 91)
        logits[1] = 3
        logits[3] = 4
        let result = RFDETRPostprocessor.detections(
            boxes: [0.5, 0.5, 0.2, 0.2],
            logits: logits,
            queryCount: 1,
            classCount: 91,
            confidence: 0.5
        )

        XCTAssertEqual(result.map(\.label), ["car", "person"])
    }

    func testDropsBackgroundGapAndScoresAtThreshold() {
        var logits = Array(repeating: -20.0, count: 91)
        logits[0] = 20
        logits[12] = 20
        logits[1] = 0
        let result = RFDETRPostprocessor.detections(
            boxes: [0.5, 0.5, 0.2, 0.2],
            logits: logits,
            queryCount: 1,
            classCount: 91,
            confidence: 0.5
        )

        XCTAssertTrue(result.isEmpty)
    }
}
