import XCTest
import CoreGraphics
@testable import AICameraCore

final class AgentCameraLayoutTests: XCTestCase {
    func testAllCornersPreserveAspectAndCaptionMarginsAtSupportedSizes() throws {
        for size in [CGSize(width: 640, height: 480), CGSize(width: 1280, height: 720), CGSize(width: 1920, height: 1080)] {
            for position in AgentCardPosition.allCases {
                for fraction in [0.15, 0.2, 0.5] {
                    let request = try XCTUnwrap(AgentCameraInsetRequest(position: position, widthFraction: fraction))
                    let frame = try XCTUnwrap(request.frame(in: size))
                    XCTAssertEqual(frame.width / frame.height, size.width / size.height, accuracy: 0.0001)
                    XCTAssertGreaterThanOrEqual(frame.minX, 14)
                    XCTAssertLessThanOrEqual(frame.maxX, size.width - 14)
                    XCTAssertGreaterThanOrEqual(frame.minY, max(56, size.height * 0.1) + 182)
                    XCTAssertLessThanOrEqual(frame.maxY, size.height - 108)
                }
            }
        }
    }

    func testInvalidOrUnusableLayoutsFailBeforeACompositorChange() throws {
        XCTAssertNil(AgentCameraInsetRequest(widthFraction: .nan))
        XCTAssertNil(AgentCameraInsetRequest(widthFraction: 0.01))
        XCTAssertNil(AgentCameraInsetRequest(ttlSeconds: 301))
        let request = try XCTUnwrap(AgentCameraInsetRequest())
        XCTAssertNil(request.frame(in: CGSize(width: 640, height: 360)))
        XCTAssertNil(request.frame(in: CGSize(width: CGFloat.infinity, height: 720)))
        let script = AICameraConfiguration.default.overlays.script
        XCTAssertEqual(AgentToolCommand.parse(name: "set_camera_layout", arguments: #"{"mode":"camera"}"#, script: script), .resetView)
        XCTAssertEqual(AgentToolCommand.parse(name: "set_camera_layout", arguments: #"{"mode":"inset"}"#, script: script), .cameraInset(request))
        for invalid in [#"{"mode":"inset","widthFraction":true}"#, #"{"mode":"inset","ttlSeconds":"30"}"#,
                        #"{"mode":"inset","position":"face"}"#, #"{"mode":"camera","widthFraction":0.2}"#] {
            XCTAssertNil(AgentToolCommand.parse(name: "set_camera_layout", arguments: invalid, script: script))
        }
    }

    func testExpiredPresentationSuppressesItsSceneUntilCleanupAndResetRetainsNoLayout() throws {
        let state = AgentPresentationState()
        let request = try XCTUnwrap(AgentCameraInsetRequest(ttlSeconds: 5))
        XCTAssertEqual(state.cameraLayout(at: 100), .camera)
        state.showCameraInset(request, at: 100)
        XCTAssertEqual(state.cameraLayout(at: 104), .inset(request))
        XCTAssertEqual(state.cameraLayout(at: 105), .expired)
        XCTAssertNil(state.cameraInset(at: 105))
        state.clearCameraInset()
        XCTAssertEqual(state.cameraLayout(at: 105), .camera)
        state.showCameraInset(request, at: 106)
        state.show(.init(title: "Card", body: "Visible"), at: 106)
        state.clear()
        XCTAssertEqual(state.cameraLayout(at: 107), .inset(request), "Clearing a card must not change camera layout")
        state.reset()
        XCTAssertEqual(state.cameraLayout(at: 107), .camera)
        XCTAssertTrue(state.cards(at: 107).isEmpty)
    }
}
