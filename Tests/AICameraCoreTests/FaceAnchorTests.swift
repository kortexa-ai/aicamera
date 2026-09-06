import CoreGraphics
import XCTest
@testable import AICameraCore

final class FaceAnchorTests: XCTestCase {
    private func anchor(source: CGSize = CGSize(width: 1280, height: 720), output: CGSize = CGSize(width: 1280, height: 720),
                        mirrored: Bool = false) throws -> FaceAnchor {
        try XCTUnwrap(FaceAnchorGeometry.project(visionBox: .init(x: 0.25, y: 0.25, width: 0.3, height: 0.4),
                    visionLeftEye: .init(x: 0.32, y: 0.52), visionRightEye: .init(x: 0.48, y: 0.54),
                    source: source, output: output, mirrored: mirrored))
    }
    func testCanvasCoordinatesMatchAspectFillAndMirror() throws {
        for source in [CGSize(width: 1280, height: 720), CGSize(width: 1536, height: 1024)] {
            for output in [CGSize(width: 1280, height: 720), CGSize(width: 640, height: 480)] {
                let value = try anchor(source: source, output: output)
                let mirror = try anchor(source: source, output: output, mirrored: true)
                XCTAssertEqual(value.center.x + mirror.center.x, 1, accuracy: 0.000_001)
                XCTAssertEqual(value.center.y, mirror.center.y, accuracy: 0.000_001)
                XCTAssertEqual(value.box.width, mirror.box.width, accuracy: 0.000_001)
                XCTAssertEqual(value.roll, -mirror.roll, accuracy: 0.000_001)
                XCTAssertTrue(FaceAnchorGeometry.isValid(value))
                // Reproduce both compositor crops independently, in pixels.
                let scale = max(output.width / source.width, output.height / source.height)
                let expectedX = 0.4 * source.width * scale - (source.width * scale - output.width) / 2
                let expectedY = output.height - (0.45 * source.height * scale - (source.height * scale - output.height) / 2)
                let overlayScale = max(output.width / 640, output.height / 360)
                let actualX = value.center.x * 640 * overlayScale - (640 * overlayScale - output.width) / 2
                let actualY = value.center.y * 360 * overlayScale - (360 * overlayScale - output.height) / 2
                XCTAssertEqual(actualX, expectedX, accuracy: 0.000_001)
                XCTAssertEqual(actualY, expectedY, accuracy: 0.000_001)
            }
        }
    }
    func testInvalidPartialAndTooSmallGeometryIsOmitted() {
        let size = CGSize(width: 1280, height: 720)
        for box in [NormalizedRect(x: .nan, y: 0, width: 0.2, height: 0.2),
                    .init(x: 0.9, y: 0.2, width: 0.2, height: 0.3),
                    .init(x: 0.1, y: 0.1, width: 0, height: 0.2),
                    .init(x: 0.2, y: 0.2, width: 0.01, height: 0.01)] {
            XCTAssertNil(FaceAnchorGeometry.project(visionBox: box, visionLeftEye: .init(x: 0.3, y: 0.4),
                         visionRightEye: .init(x: 0.4, y: 0.4), source: size, output: size, mirrored: false))
        }
        XCTAssertNil(FaceAnchorGeometry.project(visionBox: .init(x: 0.2, y: 0.8, width: 0.3, height: 0.15),
                      visionLeftEye: .init(x: 0.3, y: 0.85), visionRightEye: .init(x: 0.4, y: 0.85),
                      source: CGSize(width: 640, height: 480), output: size, mirrored: false))
    }
    func testEffectGenerationLossAndFreshnessRejectRetiredData() throws {
        let state = FaceAnchorState(), anchor = try anchor()
        XCTAssertNil(state.requestedGeneration)
        let generation = state.begin()
        XCTAssertNil(state.fresh(at: 100))
        XCTAssertTrue(state.apply(anchor, generation: generation, capturedAt: 100))
        let first = try XCTUnwrap(state.fresh(at: 100.1))
        XCTAssertNil(state.fresh(at: 99))
        XCTAssertNil(state.fresh(at: 100.36))
        XCTAssertFalse(state.apply(anchor, generation: generation, capturedAt: 99))
        XCTAssertTrue(state.apply(anchor, generation: generation, capturedAt: 100.2))
        XCTAssertEqual(state.fresh(at: 100.2)?.trackingID, first.trackingID)
        XCTAssertTrue(state.apply(nil, generation: generation, capturedAt: 100.3))
        XCTAssertNil(state.fresh(at: 100.3))
        XCTAssertFalse(state.apply(anchor, generation: generation, capturedAt: 100.25))
        XCTAssertTrue(state.apply(anchor, generation: generation, capturedAt: 100.4))
        XCTAssertNotEqual(state.fresh(at: 100.4)?.trackingID, first.trackingID)
        let replacement = state.begin()
        state.end(generation: generation)
        XCTAssertEqual(state.requestedGeneration, replacement, "Retired renderer must not end a new effect")
        XCTAssertFalse(state.apply(anchor, generation: generation, capturedAt: 101))
        XCTAssertTrue(state.apply(anchor, generation: replacement, capturedAt: 101))
        state.end(generation: replacement)
        XCTAssertNil(state.requestedGeneration)
        XCTAssertNil(state.fresh(at: 101))
    }
    func testTrackingGapCreatesNewIdentityAndPayloadIsBoundedAndLocalGeometryOnly() throws {
        let state = FaceAnchorState(), value = try anchor(), generation = state.begin()
        state.apply(value, generation: generation, capturedAt: 1)
        let first = try XCTUnwrap(state.fresh(at: 1))
        state.apply(value, generation: generation, capturedAt: 2)
        let second = try XCTUnwrap(state.fresh(at: 2))
        XCTAssertNotEqual(first.trackingID, second.trackingID)
        let json = try XCTUnwrap(second.json(at: 2.1))
        XCTAssertLessThan(json.utf8.count, 2_048)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["trackingID", "ageSeconds", "box", "center", "top", "leftEye", "rightEye", "roll"])
        XCTAssertNil(second.json(at: 2.36))
        XCTAssertNil(second.json(at: .nan))
        let invalid = FaceAnchor(box: value.box, center: .init(x: .nan, y: 0.5), top: value.top,
                                 leftEye: value.leftEye, rightEye: value.rightEye, roll: value.roll)
        XCTAssertFalse(state.apply(invalid, generation: generation, capturedAt: 2.2))
        XCTAssertNil(state.fresh(at: 2.2))
    }
    func testAnalysisPermitSurvivesRapidEffectAndCameraReplacement() throws {
        let state = FaceAnchorState()
        XCTAssertNil(state.beginAnalysis(generation: UUID()))
        let first = state.begin()
        let pending = try XCTUnwrap(state.beginAnalysis(generation: first))
        XCTAssertNil(state.beginAnalysis(generation: first))
        state.end(generation: first)
        let replacement = state.begin()
        XCTAssertNil(state.beginAnalysis(generation: replacement), "A retired native request still holds the single global slot")
        state.endAnalysis(UUID())
        XCTAssertNil(state.beginAnalysis(generation: replacement), "An unrelated callback cannot free the slot")
        state.endAnalysis(pending)
        let current = try XCTUnwrap(state.beginAnalysis(generation: replacement))
        state.endAnalysis(pending)
        XCTAssertNil(state.beginAnalysis(generation: replacement), "A duplicate retired completion cannot free new work")
        state.endAnalysis(current)
        XCTAssertNotNil(state.beginAnalysis(generation: replacement))
    }
    func testFaceEffectToolRequiresVisualCapabilityAndExistingScriptBounds() {
        let script = ScriptOverlayConfiguration(enabled: true)
        XCTAssertEqual(AgentToolCommand.parse(name: "render_face_effect", arguments: #"{"script":"AICamera.onFrame(() => {});","ttlSeconds":10}"#, script: script),
                       .faceEffect(script: "AICamera.onFrame(() => {});", ttlSeconds: 10))
        for bad in [#"{"script":false}"#, #"{"script":"x","ttlSeconds":301}"#, #"{"script":"x","includeTranscript":true}"#] {
            XCTAssertNil(AgentToolCommand.parse(name: "render_face_effect", arguments: bad, script: script))
        }
        let absent = AgentToolCatalog.definitions(capabilities: .init(visuals: true), script: script)
        XCTAssertFalse(absent.contains { $0["name"] as? String == "render_face_effect" })
        XCTAssertTrue(AgentToolCatalog.definitions(capabilities: .init(faceEffects: true), script: script).isEmpty)
        let available = AgentToolCatalog.definitions(capabilities: .init(visuals: true, faceEffects: true), script: script)
        XCTAssertTrue(available.contains { $0["name"] as? String == "render_face_effect" })
        XCTAssertTrue(JSONSerialization.isValidJSONObject(available))
        let profile = AICameraConfiguration.default
        let session = RealtimeSessionConfiguration.request(endpoint: .init(id: "test", adapter: .openAIRealtime,
                        baseURL: URL(string: "https://api.openai.com")!), conversation: profile.pipeline.conversation,
                        profile: profile, toolsAvailable: true, agentTools: .init(visuals: true, faceEffects: true))
        let instructions = session["instructions"] as? String ?? ""
        XCTAssertTrue(instructions.contains("A face effect waits for tracking"))
        XCTAssertFalse(instructions.contains("For a three.js visual request, call render_overlay"))
    }
}
