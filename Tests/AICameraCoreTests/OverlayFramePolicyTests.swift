import XCTest
@testable import AICameraCore

final class OverlayFramePolicyTests: XCTestCase {
    private var body: [String: Any] {
        ["generation": "current", "seq": 0, "w": 640, "h": 360,
         "b64": Data(repeating: 127, count: OverlayFramePolicy.pixelBytes).base64EncodedString()]
    }

    func testFixedFramePreservesPixelsAndRejectsStaleGenerationOrReplay() throws {
        let decoded = try XCTUnwrap(OverlayFramePolicy.decode(body, generation: "current", after: -1))
        XCTAssertEqual(decoded.pixels, Data(repeating: 127, count: OverlayFramePolicy.pixelBytes))
        XCTAssertNil(OverlayFramePolicy.decode(body, generation: "retired", after: -1))
        XCTAssertNil(OverlayFramePolicy.decode(body, generation: "current", after: decoded.sequence))
    }

    func testDimensionsAndEncodedPayloadAreBoundedBeforeAllocation() {
        for (key, value) in [("w", Int.max), ("h", -1), ("seq", Int.max)] {
            var input = body; input[key] = value
            XCTAssertNil(OverlayFramePolicy.decode(input, generation: "current", after: -1))
        }
        for encoded in ["", "%%%%", String(repeating: "A", count: OverlayFramePolicy.base64Bytes + 4)] {
            var input = body; input["b64"] = encoded
            XCTAssertNil(OverlayFramePolicy.decode(input, generation: "current", after: -1))
        }
    }

    func testBooleansFractionsAndNonfiniteSequencesAreNotIntegers() {
        for sequence: Any in [true, 0.5, Double.nan, Double.infinity, -1] {
            var input = body; input["seq"] = sequence
            XCTAssertNil(OverlayFramePolicy.decode(input, generation: "current", after: -1))
        }
    }
}
