import AICameraCore
import AppKit
import CoreImage
import CoreVideo

// Only generated frames and explicitly synthetic notes. No capture, network, credentials, or app startup.
@main
struct AgentToolsValidation {
    @MainActor static func main() async throws {
        precondition(CommandLine.arguments.count == 2, "Supply an output directory for synthetic fixtures")
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let notesURL = directory.appendingPathComponent("SyntheticNotes/\(UUID().uuidString).json")
        let notes = AgentNotesController(fileURL: notesURL)
        let presentation = AgentPresentationState()
        let saved = try await notes.save(text: "SYNTHETIC: Send Maya the revised draft.")
        precondition(notes.notes == [saved] && notes.error == nil)
        precondition(presentation.cards().isEmpty, "Saving a note must not put it on the camera")
        let updated = try await notes.save(text: "SYNTHETIC: Send the draft on Tuesday.", id: saved.id)
        precondition(updated.id == saved.id && notes.notes == [updated])

        for (width, height) in [(1280, 720), (640, 480)] {
            var input: CVPixelBuffer?
            precondition(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                [kCVPixelBufferCGImageCompatibilityKey: true,
                 kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary, &input) == kCVReturnSuccess)
            let frame = input!
            CIContext().render(CIImage(color: CIColor(red: 0.22, green: 0.27, blue: 0.32))
                .cropped(to: CGRect(x: 0, y: 0, width: width, height: height)), to: frame)
            var capture = AICameraConfiguration.default.capture
            capture.width = width; capture.height = height; capture.mirrorVideo = false
            var overlays = AICameraConfiguration.default.overlays
            overlays.enabled = false
            let renderer = OverlayRenderer()
            let baseline = bytes(renderer.render(input: frame, capture: capture, overlay: overlays, snapshot: .init())!)
            for position in AgentCardPosition.allCases {
                for style in AgentCardStyle.allCases {
                    let request = AgentCardRequest(title: style == .sticky ? "Remember this" : "A little perspective",
                        body: style == .metric ? "42 ideas" : "Ask one question.\nKeep the conversation going.",
                        source: "Synthetic example · no live data", style: style, position: position, ttlSeconds: 5)
                    let card = presentation.show(request, at: 100)!
                    let output = renderer.render(input: frame, capture: capture, overlay: overlays,
                                                 snapshot: .init(), cards: presentation.cards(at: 101))!
                    let pixels = bytes(output)
                    precondition(pixels != baseline, "Card missing from outgoing pixels")
                    precondition(pixels == bytes(renderer.render(input: frame, capture: capture, overlay: overlays,
                        snapshot: .init(), cards: [card])!), "Cached card pixels changed")
                    let rowBytes = CVPixelBufferGetBytesPerRow(output)
                    precondition(pixels.prefix(rowBytes * 115) == baseline.prefix(rowBytes * 115), "Card covers status area")
                    precondition(pixels.suffix(rowBytes * 90) == baseline.suffix(rowBytes * 90), "Card covers captions")
                    let image = renderer.previewImage(from: output)!
                    let representation = NSBitmapImageRep(data: image.tiffRepresentation!)!
                    try representation.representation(using: .png, properties: [:])!
                        .write(to: directory.appendingPathComponent("\(width)-\(position.rawValue)-\(style.rawValue).png"))
                    precondition(bytes(renderer.render(input: frame, capture: capture, overlay: overlays,
                        snapshot: .init(), cards: presentation.cards(at: 105))!) == baseline, "Expired card retained pixels")
                }
            }
            // Long captions retain priority over a visual response in both supported fixture sizes.
            overlays.enabled = true; overlays.showStatus = true; overlays.showAgentResponse = true
            overlays.showTranscript = true; overlays.showDetectionBoxes = false; overlays.showGestureLabels = false
            var scene = SceneSnapshot(status: "AI Camera")
            scene.agentResponse = "Here are the main points, while you keep talking with your friend."
            scene.transcript = TranscriptEvent(text: "Synthetic translation caption")
            let withCaptions = bytes(renderer.render(input: frame, capture: capture, overlay: overlays, snapshot: scene)!)
            presentation.show(.init(title: "三个想法", body: "保持对话\n记下重点\n分享一个小小的想法", style: .sticky, position: .upperLeft), at: 100)
            let combined = renderer.render(input: frame, capture: capture, overlay: overlays,
                                          snapshot: scene, cards: presentation.cards(at: 101))!
            let rowBytes = CVPixelBufferGetBytesPerRow(combined)
            let pixels = bytes(combined)
            precondition(pixels.prefix(rowBytes * 225) == withCaptions.prefix(rowBytes * 225), "Card covers agent answer")
            precondition(pixels.suffix(rowBytes * 90) == withCaptions.suffix(rowBytes * 90), "Card covers translation")
            let representation = NSBitmapImageRep(data: renderer.previewImage(from: combined)!.tiffRepresentation!)!
            try representation.representation(using: .png, properties: [:])!
                .write(to: directory.appendingPathComponent("\(width)-captions-and-card.png"))
            presentation.clear()
            precondition(presentation.cards(at: 101).isEmpty)

            // Distinct camera quadrants reveal mirroring, cropping, and vertical-orientation mistakes.
            let bounds = CGRect(x: 0, y: 0, width: width, height: height)
            let cameraPattern = CIImage(color: CIColor(red: 0.85, green: 0.18, blue: 0.2)).cropped(to: bounds)
            let green = CIImage(color: CIColor(red: 0.15, green: 0.75, blue: 0.3))
                .cropped(to: CGRect(x: width / 2, y: 0, width: width / 2, height: height))
            let yellow = CIImage(color: CIColor(red: 0.95, green: 0.75, blue: 0.15))
                .cropped(to: CGRect(x: 0, y: height / 2, width: width / 2, height: height / 2))
            CIContext().render(yellow.composited(over: green).composited(over: cameraPattern), to: frame)
            var generated: CVPixelBuffer?
            precondition(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary,
                &generated) == kCVReturnSuccess)
            let generatedScene = generated!
            CIContext().render(CIImage(color: CIColor(red: 0.08, green: 0.12, blue: 0.35)).cropped(to: bounds), to: generatedScene)
            overlays.enabled = false
            for mirror in [false, true] {
                capture.mirrorVideo = mirror
                let clean = renderer.render(input: frame, capture: capture, overlay: overlays, snapshot: .init())!
                let cleanBytes = bytes(clean)
                for position in AgentCardPosition.allCases {
                    let request = AgentCameraInsetRequest(position: position, ttlSeconds: 5)!
                    presentation.showCameraInset(request, at: 100)
                    let inset = renderer.render(input: frame, capture: capture, overlay: overlays, snapshot: .init(),
                        scriptOverlay: generatedScene, cameraLayout: presentation.cameraLayout(at: 101))!
                    let rectangle = request.frame(in: bounds.size)!
                    for x in [0.25, 0.75] {
                        for y in [0.25, 0.75] {
                            let expected = pixel(clean, x: Int(Double(width) * x), y: Int(Double(height) * y))
                            let actual = pixel(inset, x: Int(rectangle.minX + rectangle.width * x),
                                               y: Int(rectangle.minY + rectangle.height * y))
                            precondition(zip(expected, actual).allSatisfy { abs(Int($0) - Int($1)) <= 2 },
                                         "Inset changed camera orientation or colors")
                        }
                    }
                    precondition(pixel(inset, x: width / 2, y: 50) == pixel(generatedScene, x: width / 2, y: 50),
                                 "Presentation did not fill the frame")
                    let card = presentation.show(.init(title: "Presentation", body: "A synthetic card stays clear of the camera.", position: position), at: 100)!
                    let withCard = renderer.render(input: frame, capture: capture, overlay: overlays, snapshot: .init(),
                        scriptOverlay: generatedScene, cards: [card], cameraLayout: presentation.cameraLayout(at: 101))!
                    precondition(changedPixels(withCard, inset, in: rectangle) == 0, "Information card obscured the camera inset")
                    if !mirror && position == .lowerRight {
                        let representation = NSBitmapImageRep(data: renderer.previewImage(from: withCard)!.tiffRepresentation!)!
                        try representation.representation(using: .png, properties: [:])!
                            .write(to: directory.appendingPathComponent("\(width)-presentation-and-card.png"))
                    }
                    var debugOverlays = overlays
                    debugOverlays.enabled = true; debugOverlays.showStatus = false
                    debugOverlays.showDetectionBoxes = true; debugOverlays.showGestureLabels = true
                    let debugScene = SceneSnapshot(detections: [.init(label: "Fixture", confidence: 0.9,
                        boundingBox: .init(x: 0.2, y: 0.2, width: 0.3, height: 0.3))],
                        gestures: [.init(kind: .victory, confidence: 0.9, location: .init(x: 0.5, y: 0.5))])
                    let annotated = renderer.render(input: frame, capture: capture, overlay: debugOverlays, snapshot: debugScene,
                        scriptOverlay: generatedScene, cameraLayout: presentation.cameraLayout(at: 101))!
                    let changedInside = changedPixels(annotated, inset, in: rectangle.integral)
                    precondition(changedInside > 10, "Camera annotations did not follow the inset")
                    precondition(changedInside == changedPixels(annotated, inset, in: bounds), "Camera annotations escaped the inset")
                    precondition(bytes(renderer.render(input: frame, capture: capture, overlay: overlays, snapshot: .init(),
                        cameraLayout: presentation.cameraLayout(at: 101))!) == cleanBytes, "Missing scene failed to restore full camera")
                    precondition(bytes(renderer.render(input: frame, capture: capture, overlay: overlays, snapshot: .init(),
                        scriptOverlay: generatedScene, cameraLayout: presentation.cameraLayout(at: 105))!) == cleanBytes,
                        "Expired inset retained its scene before timer cleanup")
                    if !mirror {
                        let representation = NSBitmapImageRep(data: renderer.previewImage(from: inset)!.tiffRepresentation!)!
                        try representation.representation(using: .png, properties: [:])!
                            .write(to: directory.appendingPathComponent("\(width)-inset-\(position.rawValue).png"))
                    }
                }
            }
            presentation.reset()
        }
        try await notes.delete(id: saved.id)
        precondition(notes.notes.isEmpty)
        let reopened = try await AgentNoteStore(fileURL: notesURL).all()
        precondition(reopened.isEmpty)
        print("Passed local note UI state, native cards, inset/mirrored camera pixels, missing/expired scene fallback, caption space, and clean baseline at two resolutions. Synthetic images: \(directory.path)")
    }

    static func bytes(_ buffer: CVPixelBuffer) -> Data {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        return Data(bytes: CVPixelBufferGetBaseAddress(buffer)!,
                    count: CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer))
    }

    static func pixel(_ buffer: CVPixelBuffer, x: Int, y: Int) -> [UInt8] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let offset = y * CVPixelBufferGetBytesPerRow(buffer) + x * 4
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        return Array(UnsafeBufferPointer(start: base + offset, count: 4))
    }

    static func changedPixels(_ a: CVPixelBuffer, _ b: CVPixelBuffer, in rect: CGRect) -> Int {
        CVPixelBufferLockBaseAddress(a, .readOnly); CVPixelBufferLockBaseAddress(b, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(a, .readOnly); CVPixelBufferUnlockBaseAddress(b, .readOnly) }
        let left = CVPixelBufferGetBaseAddress(a)!.assumingMemoryBound(to: UInt32.self)
        let right = CVPixelBufferGetBaseAddress(b)!.assumingMemoryBound(to: UInt32.self)
        let leftStride = CVPixelBufferGetBytesPerRow(a) / 4, rightStride = CVPixelBufferGetBytesPerRow(b) / 4
        var count = 0
        for y in Int(rect.minY)..<Int(rect.maxY) {
            for x in Int(rect.minX)..<Int(rect.maxX) {
                if left[y * leftStride + x] != right[y * rightStride + x] { count += 1 }
            }
        }
        return count
    }
}
