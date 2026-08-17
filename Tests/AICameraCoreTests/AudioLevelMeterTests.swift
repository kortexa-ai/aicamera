import XCTest
@testable import AICameraCore

final class AudioLevelMeterTests: XCTestCase {
    func testSilenceAndInvalidValuesMapToZero() {
        XCTAssertEqual(AudioLevelMeter.normalizedPeak(0), 0)
        XCTAssertEqual(AudioLevelMeter.normalizedPeak(-1), 0)
        XCTAssertEqual(AudioLevelMeter.normalizedPeak(.nan), 0)
        XCTAssertEqual(AudioLevelMeter.normalizedPeak(.infinity), 0)
    }

    func testFullScaleAndOversMapToOne() {
        XCTAssertEqual(AudioLevelMeter.normalizedPeak(1), 1, accuracy: 0.0001)
        XCTAssertEqual(AudioLevelMeter.normalizedPeak(2), 1, accuracy: 0.0001)
    }

    func testDecibelFloorAndMidpoint() {
        XCTAssertEqual(AudioLevelMeter.normalizedPeak(0.001), 0, accuracy: 0.0001)
        XCTAssertEqual(AudioLevelMeter.normalizedPeak(0.03162278), 0.5, accuracy: 0.001)
    }

    func testInvalidFloorFailsClosed() {
        XCTAssertEqual(AudioLevelMeter.normalizedPeak(0.5, floorDecibels: 0), 0)
        XCTAssertEqual(AudioLevelMeter.normalizedPeak(0.5, floorDecibels: .nan), 0)
    }
}
