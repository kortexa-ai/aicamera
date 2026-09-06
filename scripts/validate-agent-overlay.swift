import AICameraCore
import AppKit
import CoreImage
import CoreVideo

// Only generated solid-color frames are used or saved. No capture or credentials.
@main
struct AgentOverlayValidation {
    @MainActor static func main() throws {
        let directory = URL(fileURLWithPath: "/tmp/aicamera-agent-overlays", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var input: CVPixelBuffer?
        precondition(CVPixelBufferCreate(nil, 1280, 720, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferCGImageCompatibilityKey: true,
             kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary, &input) == kCVReturnSuccess)
        let frame = input!
        CIContext().render(CIImage(color: CIColor(red: 0.22, green: 0.27, blue: 0.32))
            .cropped(to: CGRect(x: 0, y: 0, width: 1280, height: 720)), to: frame)
        var capture = AICameraConfiguration.default.capture
        capture.width = 1280; capture.height = 720; capture.mirrorVideo = false
        var overlays = AICameraConfiguration.default.overlays
        overlays.enabled = true
        overlays.showStatus = false
        overlays.showDetectionBoxes = false
        overlays.showGestureLabels = false
        let renderer = OverlayRenderer()
        let baseline = renderer.render(input: frame, capture: capture, overlay: overlays, snapshot: .init())!
        let reference = bytes(baseline)
        overlays.showStatus = true
        for state in AgentOverlayStatus.allCases {
            var scene = SceneSnapshot(status: "AI Camera")
            scene.agentStatus = state
            let output = renderer.render(input: frame, capture: capture, overlay: overlays, snapshot: scene)!
            let data = bytes(output)
            precondition(different(data, reference, rect: CGRect(x: 0, y: 0, width: 1280, height: 60)) == 0,
                         "Overlay intruded into the title-bar margin")
            precondition(different(data, reference, rect: CGRect(x: 0, y: 64, width: 210, height: 90)) > 100,
                         "Title was not rendered in the inset left corner")
            precondition(different(data, reference, rect: CGRect(x: 1040, y: 64, width: 240, height: 90)) > 100,
                         "Agent state was not composited into the outgoing pixels")
            let image = renderer.previewImage(from: output)!
            let representation = NSBitmapImageRep(data: image.tiffRepresentation!)!
            try representation.representation(using: .png, properties: [:])!
                .write(to: directory.appendingPathComponent(state.rawValue + ".png"))
            overlays.showStatus = false
            let hidden = renderer.render(input: frame, capture: capture, overlay: overlays, snapshot: scene)!
            precondition(bytes(hidden) == reference, "Show Status failed to hide the title and avatar")
            overlays.showStatus = true
        }
        // The production orb is deterministic for a supplied time, and active states animate.
        func orb(at time: Double) -> Data {
            let context = CGContext(data: nil, width: 320, height: 180, bitsPerComponent: 8,
                bytesPerRow: 1280, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            AgentStatusRenderer().draw(status: .speaking, feedback: nil, width: 320, top: 56,
                                       context: context, now: time)
            return Data(bytes: context.data!, count: 1280 * 180)
        }
        precondition(orb(at: 10) == orb(at: 10), "Orb frame was not deterministic")
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            precondition(orb(at: 10) != orb(at: 11), "Speaking orb did not animate")
        }
        print("Passed seven outgoing agent states, title-bar margin, overlay toggle, and bounded animated orb. Synthetic PNGs: \(directory.path)")
    }

    static func bytes(_ buffer: CVPixelBuffer) -> Data {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        return Data(bytes: CVPixelBufferGetBaseAddress(buffer)!,
                    count: CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer))
    }
    static func different(_ a: Data, _ b: Data, rect: CGRect) -> Int {
        var count = 0
        for y in Int(rect.minY)..<Int(rect.maxY) {
            for x in Int(rect.minX)..<Int(rect.maxX) {
                let index = y * 1280 * 4 + x * 4
                if a[index..<index + 4] != b[index..<index + 4] { count += 1 }
            }
        }
        return count
    }
}
