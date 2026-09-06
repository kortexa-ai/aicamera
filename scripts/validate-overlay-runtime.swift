import AICameraCore
import AppKit
import CoreVideo
import Foundation

// Uses only generated geometry. No camera, microphone, network request, or credential access.
@main
struct OverlayRuntimeValidation {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            do { try await run(); Darwin.exit(0) }
            catch { fputs("Overlay validation failed: \(error)\n", stderr); Darwin.exit(1) }
        }
        app.run()
    }

    struct Failure: Error, CustomStringConvertible { let description: String }
    @MainActor final class FaceFeed {
        var anchor: FaceAnchor?
        init(_ anchor: FaceAnchor?) { self.anchor = anchor }
    }
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(description: message) }
    }

    @MainActor static func run() async throws {
        guard CommandLine.arguments.count == 2 else { throw Failure(description: "Supply Resources/Overlay/overlay.html") }
        let page = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
        let config = ScriptOverlayConfiguration(enabled: true, maxScriptBytes: 4096, allowSceneData: true)
        let faceAnchors = FaceAnchorState()
        let renderer = OverlayScriptRenderer(scriptConfiguration: config, pageURL: page, faceAnchors: faceAnchors) { line in
            precondition(line.count <= 512, "Unbounded script log")
        }
        defer { renderer.stop() }
        renderer.start()
        try require(!renderer.load(script: String(repeating: "猫", count: 2000), ttlSeconds: 2), "UTF-8 byte bound")
        for ttl in [Double.nan, .infinity, 0, 61] {
            try require(!renderer.load(script: "1", ttlSeconds: ttl), "Invalid TTL accepted")
        }
        let red = scene(color: "0xff0000") + "window.retiredMarker = true; setInterval(() => { AICamera.scene.background = new THREE.Color(0xff0000); }, 10);"
        let started = Date()
        try require(renderer.load(script: red, ttlSeconds: 15), "First script rejected")
        try await waitForColor(renderer, channel: 2)
        print("First synthetic frame: \(Date().timeIntervalSince(started))s")
        var previous: CVPixelBuffer?
        var frames = 0
        let until = Date().addingTimeInterval(2)
        while Date() < until {
            if let frame = renderer.latestFreshOverlay(), frame !== previous { frames += 1; previous = frame }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try require(frames >= 20, "Frame acknowledgement stalled publication (\(frames) frames)")
        print("Two-second publication sample: \(frames) fresh frames")
        try require(renderer.load(script: "if (window.retiredMarker) throw Error('old document survived');" + scene(color: "0x0000ff"), ttlSeconds: 5), "Replacement rejected")
        try require(renderer.latestFreshOverlay() == nil, "Replacement retained old pixels")
        try await waitForColor(renderer, channel: 0)
        renderer.clear()
        try require(renderer.latestFreshOverlay() == nil, "Clear retained pixels")
        try await Task.sleep(nanoseconds: 500_000_000)
        try require(renderer.latestFreshOverlay() == nil, "Retired frame returned after Clear")
        try require(renderer.load(script: scene(color: "0x00ff00"), ttlSeconds: 1), "TTL script rejected")
        try await waitForColor(renderer, channel: 1)
        try await Task.sleep(nanoseconds: 1_300_000_000)
        try require(renderer.latestFreshOverlay() == nil, "Expired overlay remained visible")
        try require(renderer.load(script: "throw Error('synthetic failure');", ttlSeconds: 5), "Error scene admission")
        try await Task.sleep(nanoseconds: 500_000_000)
        try require(renderer.latestFreshOverlay() == nil, "Failed script published pixels")
        try require(renderer.load(script: scene(color: "0x0000ff"), ttlSeconds: 5), "Recovery rejected")
        try await waitForColor(renderer, channel: 0)
        for _ in 0..<100 { renderer.updateSceneData("{\"transcript\":\"synthetic text\"}") }
        renderer.updateSceneData(String(repeating: "x", count: 70_000))
        renderer.stop()
        try require(renderer.latestFreshOverlay() == nil, "Stop retained pixels")
        renderer.start()
        try require(renderer.load(script: scene(color: "0xff0000"), ttlSeconds: 5), "Restart rejected")
        try await waitForColor(renderer, channel: 2)
        print("Passed: UTF-8/TTL bounds, frame publication, document replacement, Clear, expiry, script-error recovery, bounded scene updates, stop/restart")
        try await validateFaceEffects(renderer, anchors: faceAnchors)
    }

    @MainActor static func validateFaceEffects(_ renderer: OverlayScriptRenderer, anchors: FaceAnchorState) async throws {
        func face(at x: Double) -> FaceAnchor {
            FaceAnchorGeometry.project(visionBox: .init(x: x - 0.15, y: 0.25, width: 0.3, height: 0.5),
                visionLeftEye: .init(x: x - 0.08, y: 0.58), visionRightEye: .init(x: x + 0.08, y: 0.58),
                source: CGSize(width: 640, height: 360), output: CGSize(width: 640, height: 360), mirrored: false)!
        }
        let current = FaceFeed(face(at: 0.3))
        let feed = Task { @MainActor in
            while !Task.isCancelled {
                if let generation = anchors.requestedGeneration {
                    anchors.apply(current.anchor, generation: generation, capturedAt: ProcessInfo.processInfo.systemUptime)
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        defer { feed.cancel() }
        let script = """
        const ball = new THREE.Mesh(new THREE.SphereGeometry(0.2, 24, 16), new THREE.MeshBasicMaterial({color:0xff0000}));
        AICamera.scene.add(ball);
        AICamera.onFrame(() => { const face = AICamera.faceAnchor; ball.visible = !!face;
          if (face) ball.position.copy(AICamera.facePosition(face.center)); });
        """
        try require(renderer.load(script: script, ttlSeconds: 15, followsFace: true), "Face script rejected")
        try require(renderer.latestFreshOverlay() == nil, "Face effect visible before tracking")
        try await waitForBlob(renderer, x: 192, y: 180)
        current.anchor = nil
        anchors.apply(nil, generation: anchors.requestedGeneration!, capturedAt: ProcessInfo.processInfo.systemUptime)
        try require(renderer.latestFreshOverlay() == nil, "Lost face retained graphic")
        try await Task.sleep(for: .milliseconds(100))
        current.anchor = face(at: 0.7)
        anchors.apply(current.anchor, generation: anchors.requestedGeneration!, capturedAt: ProcessInfo.processInfo.systemUptime)
        try require(renderer.latestFreshOverlay() == nil, "Old face pixels returned before new anchor reached WebKit")
        try await waitForBlob(renderer, x: 448, y: 180)
        feed.cancel()
        try await Task.sleep(for: .milliseconds(400))
        try require(renderer.latestFreshOverlay() == nil, "Stale face remained visible despite fresh script frames")
        try require(renderer.load(script: scene(color: "0x0000ff"), ttlSeconds: 5), "Normal overlay replacement rejected")
        try require(anchors.requestedGeneration == nil, "Normal overlay retained face tracking")
        try await waitForColor(renderer, channel: 0)
        try require(renderer.load(script: script, ttlSeconds: 1, followsFace: true), "Face expiry admission failed")
        try await Task.sleep(for: .milliseconds(1400))
        try require(anchors.requestedGeneration == nil && renderer.latestFreshOverlay() == nil, "Expired face effect retained tracking")
        try require(renderer.load(script: "throw Error('synthetic face failure');", ttlSeconds: 15, followsFace: true), "Face failure admission failed")
        let failureDeadline = ProcessInfo.processInfo.systemUptime + 3
        while anchors.requestedGeneration != nil && ProcessInfo.processInfo.systemUptime < failureDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try require(anchors.requestedGeneration == nil && !renderer.scriptIsRunning, "Failed face script retained tracking")
        try require(renderer.load(script: script, ttlSeconds: 5, followsFace: true), "Face stop admission failed")
        renderer.stop()
        try require(anchors.requestedGeneration == nil && renderer.latestFreshOverlay() == nil, "Stopped face effect retained tracking")
        print("Passed face effects: canvas/world pixel positions, no pre-track pixels, loss/reacquisition fencing, stale-anchor hiding, normal-overlay replacement, failed script cleanup, expiry, and Stop")
    }

    @MainActor static func waitForBlob(_ renderer: OverlayScriptRenderer, x: Double, y: Double) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        while ProcessInfo.processInfo.systemUptime < deadline {
            if let frame = renderer.latestFreshOverlay(), let center = redCenter(frame),
               abs(center.x - x) < 3, abs(center.y - y) < 3 { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw Failure(description: "Face graphic did not reach expected native pixel position (\(x), \(y))")
    }
    static func redCenter(_ frame: CVPixelBuffer) -> CGPoint? {
        CVPixelBufferLockBaseAddress(frame, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(frame, .readOnly) }
        guard let pixels = CVPixelBufferGetBaseAddress(frame)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let row = CVPixelBufferGetBytesPerRow(frame)
        var count = 0, xSum = 0, ySum = 0
        for y in 0..<CVPixelBufferGetHeight(frame) { for x in 0..<CVPixelBufferGetWidth(frame) {
            let i = y * row + x * 4
            if pixels[i + 2] > 180 && pixels[i + 1] < 70 && pixels[i] < 70 && pixels[i + 3] > 180 {
                count += 1; xSum += x; ySum += y
            }
        } }
        guard count > 50 else { return nil }
        return CGPoint(x: Double(xSum) / Double(count), y: Double(ySum) / Double(count))
    }

    static func scene(color: String) -> String {
        "const mesh = new THREE.Mesh(new THREE.BoxGeometry(1.5, 1.5, 1.5), new THREE.MeshBasicMaterial({color: \(color)})); AICamera.scene.add(mesh); AICamera.onFrame(dt => { mesh.rotation.y += dt; });"
    }

    @MainActor static func waitForColor(_ renderer: OverlayScriptRenderer, channel: Int) async throws {
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if let buffer = renderer.latestFreshOverlay(), centerMatches(buffer, channel: channel) { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw Failure(description: "No matching synthetic color on channel \(channel)")
    }

    static func centerMatches(_ buffer: CVPixelBuffer, channel: Int) -> Bool {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else { return false }
        let offset = (CVPixelBufferGetHeight(buffer) / 2) * CVPixelBufferGetBytesPerRow(buffer)
            + (CVPixelBufferGetWidth(buffer) / 2) * 4
        return base[offset + channel] > 180 && base[offset + 3] > 180
            && (0..<3).filter { $0 != channel }.allSatisfy { base[offset + $0] < 70 }
    }
}
