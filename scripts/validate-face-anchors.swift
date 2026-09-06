import AICameraCore
import AppKit
import CoreImage
import CoreVideo

/// Automatic mode uses a blank synthetic frame. Optional portrait mode requires an explicitly
/// supplied fictional/generated image; it never opens a camera or microphone.
@main
struct FaceAnchorValidation {
    struct Failure: Error, CustomStringConvertible { let description: String }
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            do { try await run(); Darwin.exit(0) }
            catch { fputs("Face fixture failed: \(error)\n", stderr); Darwin.exit(1) }
        }
        app.run()
    }
    @MainActor static func run() async throws {
        guard [2, 4].contains(CommandLine.arguments.count) else {
            throw Failure(description: "Supply overlay.html, optionally synthetic-portrait.png and output directory")
        }
        let detector = FaceAnchorDetector()
        let blank = try buffer(CIImage(color: CIColor.black).cropped(to: CGRect(x: 0, y: 0, width: 640, height: 480)))
        guard detector.detect(in: blank, output: CGSize(width: 640, height: 480), mirrored: false) == nil else {
            throw Failure(description: "Blank synthetic frame produced a face anchor")
        }
        print("Native Vision blank-frame rejection passed; no media capture.")
        guard CommandLine.arguments.count == 4 else { return }
        let portraitURL = URL(fileURLWithPath: CommandLine.arguments[2])
        let output = URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true)
        guard let portrait = CIImage(contentsOf: portraitURL), portrait.extent.width <= 4096,
              portrait.extent.height <= 4096 else { throw Failure(description: "Invalid or oversized synthetic portrait") }
        let input = try buffer(portrait)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for (width, height) in [(1280, 720), (640, 480)] {
            var previous: FaceAnchor?
            for mirrored in [false, true] {
                let size = CGSize(width: width, height: height)
                guard let anchor = detector.detect(in: input, output: size, mirrored: mirrored), FaceAnchorGeometry.isValid(anchor) else {
                    throw Failure(description: "Synthetic portrait did not produce one valid face at \(width)x\(height)")
                }
                if let previous {
                    guard abs(previous.center.x + anchor.center.x - 1) < 0.0001,
                          abs(previous.center.y - anchor.center.y) < 0.0001,
                          abs(previous.roll + anchor.roll) < 0.0001 else {
                        throw Failure(description: "Native mirrored face coordinates disagreed")
                    }
                }
                previous = anchor
                let anchors = FaceAnchorState()
                let renderer = OverlayScriptRenderer(scriptConfiguration: .init(enabled: true),
                        pageURL: URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL, faceAnchors: anchors) { _ in }
                renderer.start()
                defer { renderer.stop() }
                guard renderer.load(script: sun, ttlSeconds: 15, followsFace: true) else { throw Failure(description: "Synthetic face scene rejected") }
                let feed = Task { @MainActor in
                    while !Task.isCancelled {
                        if let generation = anchors.requestedGeneration {
                            anchors.apply(anchor, generation: generation, capturedAt: ProcessInfo.processInfo.systemUptime)
                        }
                        try? await Task.sleep(for: .milliseconds(50))
                    }
                }
                defer { feed.cancel() }
                let deadline = ProcessInfo.processInfo.systemUptime + 8
                var pixels: CVPixelBuffer?
                while ProcessInfo.processInfo.systemUptime < deadline {
                    if let value = renderer.latestFreshOverlay(), hasVisiblePixels(value) { pixels = value; break }
                    try await Task.sleep(for: .milliseconds(20))
                }
                guard let pixels else { throw Failure(description: "Face illustration did not reach native pixels") }
                var capture = CaptureConfiguration(width: width, height: height)
                capture.mirrorVideo = mirrored
                let compositor = OverlayRenderer()
                guard let composed = compositor.render(input: input, capture: capture, overlay: .init(enabled: false), snapshot: .init(), scriptOverlay: pixels),
                      let image = CIContext().createCGImage(CIImage(cvPixelBuffer: composed), from: CGRect(origin: .zero, size: size)),
                      let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                    throw Failure(description: "Synthetic portrait composition failed")
                }
                try png.write(to: output.appendingPathComponent("synthetic-face-sun-\(width)\(mirrored ? "-mirrored" : "").png"))
                renderer.stop()
                guard anchors.requestedGeneration == nil else { throw Failure(description: "Stopped portrait fixture retained tracking") }
            }
        }
        print("Generated portrait → native Vision landmarks → three.js sun → native camera composition passed at two sizes, mirrored and unmirrored. No captured media or model request.")
    }

    static func buffer(_ image: CIImage) throws -> CVPixelBuffer {
        var value: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, Int(image.extent.width), Int(image.extent.height), kCVPixelFormatType_32BGRA,
                [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary, &value) == kCVReturnSuccess,
              let value else { throw Failure(description: "Synthetic pixel-buffer allocation failed") }
        CIContext().render(image, to: value)
        return value
    }
    static func hasVisiblePixels(_ buffer: CVPixelBuffer) -> Bool {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let bytes = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else { return false }
        var count = 0
        for y in 0..<CVPixelBufferGetHeight(buffer) { for x in 0..<CVPixelBufferGetWidth(buffer) {
            if bytes[y * CVPixelBufferGetBytesPerRow(buffer) + x * 4 + 3] > 100 { count += 1 }
        } }
        return count > 100
    }
    static let sun = """
    const group = new THREE.Group(); AICamera.scene.add(group);
    const gold = new THREE.MeshStandardMaterial({color:0xffbb38, emissive:0xff8800, emissiveIntensity:0.35, roughness:0.65});
    group.add(new THREE.Mesh(new THREE.SphereGeometry(0.35,32,24), gold));
    const rays = new THREE.Group(); group.add(rays);
    for (let i=0;i<10;i++) { const a=i*Math.PI/5;
      const ray=new THREE.Mesh(new THREE.ConeGeometry(0.065,0.2,12),gold);
      ray.position.set(Math.cos(a)*0.52,Math.sin(a)*0.52,0); ray.rotation.z=a-Math.PI/2; rays.add(ray); }
    const ink=new THREE.MeshBasicMaterial({color:0x3c2430});
    for (const x of [-0.11,0.11]) { const eye=new THREE.Mesh(new THREE.SphereGeometry(0.025,12,8),ink); eye.position.set(x,0.055,0.335); group.add(eye); }
    const smile=new THREE.Mesh(new THREE.TorusGeometry(0.1,0.014,8,24,Math.PI),ink);
    smile.rotation.z=Math.PI; smile.position.set(0,-0.03,0.35); group.add(smile);
    let t=0;
    AICamera.onFrame(dt => { t+=dt; const f=AICamera.faceAnchor; group.visible=!!f; if(!f)return;
      const p=AICamera.facePosition(f.top), l=AICamera.facePosition({x:f.box.x,y:f.center.y}), r=AICamera.facePosition({x:f.box.x+f.box.width,y:f.center.y});
      if(!p||!l||!r){group.visible=false;return;} const scale=Math.abs(r.x-l.x)*0.6;
      group.scale.setScalar(scale); group.position.copy(p); group.position.y+=scale*1.15;
      group.rotation.z=f.roll; rays.rotation.z=t*0.15; });
    """
}
