import CoreGraphics
import XCTest
@testable import AICameraCore

final class OverlayPresentationTests: XCTestCase {
    func testWideLayoutUsesTheWholeFrame() {
        XCTAssertEqual(OverlayLayout.wide.region(in: CGSize(width: 1280, height: 720)),
                       CGRect(x: 0, y: 0, width: 1280, height: 720))
    }

    func testCenteredFourByThreeRegionIsCenteredInsideWideFrames() {
        XCTAssertEqual(OverlayLayout.centered4x3.region(in: CGSize(width: 1280, height: 720)),
                       CGRect(x: 160, y: 0, width: 960, height: 720))
        XCTAssertEqual(OverlayLayout.centered4x3.region(in: CGSize(width: 1920, height: 1080)),
                       CGRect(x: 240, y: 0, width: 1440, height: 1080))
    }

    func testCenteredFourByThreeRegionFillsFourByThreeAndTallFrames() {
        XCTAssertEqual(OverlayLayout.centered4x3.region(in: CGSize(width: 640, height: 480)),
                       CGRect(x: 0, y: 0, width: 640, height: 480))
        XCTAssertEqual(OverlayLayout.centered4x3.region(in: CGSize(width: 720, height: 1280)),
                       CGRect(x: 0, y: 370, width: 720, height: 540))
    }

    func testUnusableSizesProduceAnEmptyRegion() {
        XCTAssertEqual(OverlayLayout.centered4x3.region(in: .zero), .zero)
        XCTAssertEqual(OverlayLayout.wide.region(in: CGSize(width: CGFloat.nan, height: 720)), .zero)
    }

    func testPresentationChangesDoNotRetireCaptionsOrGestures() {
        let controls = RuntimeFeatureState()
        let origin = controls.set(transcription: true, translation: false, gestures: true, now: 1)
        let next = controls.setPresentation(OverlayPresentation(layout: .centered4x3, mirrorGenerated: true))
        XCTAssertEqual(next.presentation.layout, .centered4x3)
        XCTAssertTrue(next.presentation.mirrorGenerated)
        XCTAssertEqual(next.captionGeneration, origin.captionGeneration)
        XCTAssertEqual(next.gestureGeneration, origin.gestureGeneration)
        XCTAssertTrue(controls.permitsCaptions(from: origin))
        XCTAssertNotEqual(next, origin)
        // Feature changes keep the presentation.
        let later = controls.set(transcription: false, translation: false, gestures: true, now: 2)
        XCTAssertEqual(later.presentation, next.presentation)
    }
}
