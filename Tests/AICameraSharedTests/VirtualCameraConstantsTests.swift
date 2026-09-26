import CoreMedia
import CoreVideo
import XCTest
@testable import AICameraShared

final class VirtualCameraConstantsTests: XCTestCase {
    func testSourceFormatIsCameraNativeYUVWhileFeederStaysBGRA() {
        XCTAssertEqual(AICameraVirtualCamera.sourcePixelFormat, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        XCTAssertEqual(AICameraVirtualCamera.pixelFormat, kCVPixelFormatType_32BGRA)
    }

    func testSourceFrameDurationIsContinuousBetweenOneAndSixtyFramesPerSecond() {
        XCTAssertEqual(AICameraVirtualCamera.sourceFrameDuration(clamping: CMTime(value: 1, timescale: 24)),
                       CMTime(value: 1, timescale: 24))
        XCTAssertEqual(AICameraVirtualCamera.sourceFrameDuration(clamping: CMTime(value: 1_000_000, timescale: 30_000_000)),
                       CMTime(value: 1_000_000, timescale: 30_000_000))
        XCTAssertEqual(AICameraVirtualCamera.sourceFrameDuration(clamping: CMTime(value: 1, timescale: 120)),
                       AICameraVirtualCamera.sourceMinFrameDuration)
        XCTAssertEqual(AICameraVirtualCamera.sourceFrameDuration(clamping: CMTime(value: 5, timescale: 1)),
                       AICameraVirtualCamera.sourceMaxFrameDuration)
    }

    func testUnusableSourceFrameDurationsAreRejected() {
        XCTAssertNil(AICameraVirtualCamera.sourceFrameDuration(clamping: .invalid))
        XCTAssertNil(AICameraVirtualCamera.sourceFrameDuration(clamping: .zero))
        XCTAssertNil(AICameraVirtualCamera.sourceFrameDuration(clamping: CMTime(value: -1, timescale: 30)))
        XCTAssertNil(AICameraVirtualCamera.sourceFrameDuration(clamping: .positiveInfinity))
    }

    func testFeederFrameRatesStayWithinTheSourceRange() {
        for rate in AICameraVirtualCamera.supportedFrameRates {
            let duration = CMTime.aicameraFrameDuration(rate: rate)
            XCTAssertEqual(AICameraVirtualCamera.sourceFrameDuration(clamping: duration), duration)
        }
    }
}
