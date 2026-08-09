import XCTest
@testable import AICameraCore

final class NominalFrameRateTests: XCTestCase {
    func testExactAndInteriorRatesUseRequestedDuration() throws {
        let fixed = try XCTUnwrap(NominalFrameRateMatcher.match(
            requestedFPS: 30,
            minimumFPS: 30,
            maximumFPS: 30
        ))
        XCTAssertEqual(fixed.actualFramesPerSecond, 30)
        XCTAssertEqual(fixed.durationSelection, .requested)

        let variable = try XCTUnwrap(NominalFrameRateMatcher.match(
            requestedFPS: 30,
            minimumFPS: 1,
            maximumFPS: 60
        ))
        XCTAssertEqual(variable.durationSelection, .requested)
    }

    func testNearbyHardwareRatesUseAdvertisedDurationBoundary() throws {
        let slightlyFast = try XCTUnwrap(NominalFrameRateMatcher.match(
            requestedFPS: 30,
            minimumFPS: 30.00003,
            maximumFPS: 30.00003
        ))
        XCTAssertEqual(slightlyFast.durationSelection, .maximumFrameDuration)

        let ntsc = 30_000.0 / 1_001.0
        let slightlySlow = try XCTUnwrap(NominalFrameRateMatcher.match(
            requestedFPS: 30,
            minimumFPS: ntsc,
            maximumFPS: ntsc
        ))
        XCTAssertEqual(slightlySlow.actualFramesPerSecond, ntsc)
        XCTAssertEqual(slightlySlow.durationSelection, .minimumFrameDuration)

        XCTAssertNotNil(NominalFrameRateMatcher.match(
            requestedFPS: 60,
            minimumFPS: 60_000.0 / 1_001.0,
            maximumFPS: 60_000.0 / 1_001.0
        ))
    }

    func testMateriallyDifferentAndInvalidRatesAreRejected() {
        XCTAssertNil(NominalFrameRateMatcher.match(requestedFPS: 30, minimumFPS: 29, maximumFPS: 29))
        XCTAssertNil(NominalFrameRateMatcher.match(requestedFPS: 30, minimumFPS: 25, maximumFPS: 25))
        XCTAssertNil(NominalFrameRateMatcher.match(requestedFPS: .nan, minimumFPS: 1, maximumFPS: 30))
        XCTAssertNil(NominalFrameRateMatcher.match(requestedFPS: 30, minimumFPS: 60, maximumFPS: 30))
    }
}
