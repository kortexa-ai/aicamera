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
        }
        try await notes.delete(id: saved.id)
        precondition(notes.notes.isEmpty)
        let reopened = try await AgentNoteStore(fileURL: notesURL).all()
        precondition(reopened.isEmpty)
        print("Passed local note UI state, native card pixels at two resolutions, all styles/positions, expiry, clearing, caption space, and clean baseline. Synthetic images: \(directory.path)")
    }

    static func bytes(_ buffer: CVPixelBuffer) -> Data {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        return Data(bytes: CVPixelBufferGetBaseAddress(buffer)!,
                    count: CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer))
    }
}
