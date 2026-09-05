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

    func testRejectsInvalidDimensionsBeforeMultiplicationOrAllocation() {
        for (queries, classes) in [(Int.max, Int.max), (-1, 91), (1_001, 91), (1, 257), (0, 91)] {
            XCTAssertTrue(RFDETRPostprocessor.detections(boxes: [], logits: [], queryCount: queries,
                                                       classCount: classes, confidence: 0.5).isEmpty)
        }
    }

    func testRejectsNonfiniteScoresCoordinatesAndThreshold() {
        var logits = Array(repeating: -20.0, count: 91)
        for invalid in [Double.nan, .infinity, -.infinity] {
            logits[1] = invalid
            XCTAssertTrue(RFDETRPostprocessor.detections(boxes: [0.5, 0.5, 0.2, 0.2], logits: logits,
                                                       queryCount: 1, classCount: 91, confidence: 0.5).isEmpty)
            logits[1] = 5
            XCTAssertTrue(RFDETRPostprocessor.detections(boxes: [invalid, 0.5, 0.2, 0.2], logits: logits,
                                                       queryCount: 1, classCount: 91, confidence: 0.5).isEmpty)
            XCTAssertTrue(RFDETRPostprocessor.detections(boxes: [0.5, 0.5, 0.2, 0.2], logits: logits,
                                                       queryCount: 1, classCount: 91, confidence: invalid).isEmpty)
        }
    }

    func testFilteringBeforeSortPreservesTopKAndTies() {
        var logits = Array(repeating: -20.0, count: 91)
        logits[0] = 9 // Background still consumes the model's top-K budget.
        logits[1] = 4
        logits[3] = 4
        let result = RFDETRPostprocessor.detections(boxes: [0.5, 0.5, 0.2, 0.2], logits: logits,
                                                  queryCount: 1, classCount: 91, confidence: 0.5,
                                                  selectionLimit: 2)
        XCTAssertEqual(result.map(\.classID), [1])
    }

    func testResultCountCannotExceedSceneLimit() {
        let queries = RFDETRPostprocessor.maximumQueries
        let boxes = Array(repeating: [0.5, 0.5, 0.2, 0.2], count: queries).flatMap { $0 }
        let result = RFDETRPostprocessor.detections(boxes: boxes,
            logits: Array(repeating: [-20.0, 5.0], count: queries).flatMap { $0 },
            queryCount: queries, classCount: 2, confidence: 0.5,
            selectionLimit: Int.max, resultLimit: Int.max)
        XCTAssertEqual(result.count, AICameraContentLimits.detections)
    }
}
