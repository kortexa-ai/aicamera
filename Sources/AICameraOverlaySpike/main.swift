import AppKit
import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import Network
import WebKit

// Phase 0 spike for the model-rendered overlay script layer.
//
// Proves the full pixel path without a camera:
//   hidden WKWebView (three.js, WebGL2) -> gl.readPixels(RGBA) -> channel
//   -> CVPixelBuffer (32RGBA) -> CoreImage alpha composite over a synthetic
//   "camera" frame -> sample PNGs + per-stage latency stats.
//
// Two pixel channels are measured (WKScriptMessage does not deliver ArrayBuffer
// bodies on this WebKit, so both channels use JSON-safe or raw-HTTP payloads):
//   --channel base64 : file:// page, chunked btoa string via WKScriptMessage
//   --channel http   : page served from a loopback HTTP server, raw RGBA POST
//
// Not shipped. Run:
//   swift run AICameraOverlaySpike --channel base64 --width 640 --height 360
//   swift run AICameraOverlaySpike --channel http --width 1280 --height 720

struct SpikeConfig {
    var duration: TimeInterval = 6
    var width: Int = 1280
    var height: Int = 720
    var outDir: String = "/tmp/aicamera-overlay-spike"
    var mode: String = "offscreen"
    var channel: String = "base64"
    var saveEvery: Int = 10
}

func parseConfig(_ arguments: [String]) -> SpikeConfig {
    var config = SpikeConfig()
    var i = 0
    while i < arguments.count {
        let arg = arguments[i]
        func next() -> String? { i += 1; return i < arguments.count ? arguments[i] : nil }
        switch arg {
        case "--duration": if let v = next(), let d = Double(v) { config.duration = d }
        case "--width": if let v = next(), let w = Int(v) { config.width = w }
        case "--height": if let v = next(), let h = Int(v) { config.height = h }
        case "--out": if let v = next() { config.outDir = v }
        case "--mode": if let v = next() { config.mode = v }
        case "--channel": if let v = next() { config.channel = v }
        case "--save-every": if let v = next(), let n = Int(v) { config.saveEvery = max(1, n) }
        default: FileHandle.standardError.write("Unknown argument: \(arg)\n".data(using: .utf8)!)
        }
        i += 1
    }
    return config
}

func percentile(_ sorted: [Double], _ p: Double) -> Double {
    guard !sorted.isEmpty else { return 0 }
    let index = min(sorted.count - 1, max(0, Int((Double(sorted.count) - 1) * p)))
    return sorted[index]
}

final class FrameStats {
    private let lock = NSLock()
    private var renderMs: [Double] = []
    private var readMs: [Double] = []
    private var transferMs: [Double] = []
    private var compositeMs: [Double] = []
    private var intervalsMs: [Double] = []
    private var firstReceive: Date?
    private var lastReceive: Date?
    private(set) var count = 0

    func record(renderMs: Double, readMs: Double, transferMs: Double, compositeMs: Double, at date: Date) {
        lock.lock(); defer { lock.unlock() }
        self.renderMs.append(renderMs)
        self.readMs.append(readMs)
        self.transferMs.append(transferMs)
        self.compositeMs.append(compositeMs)
        if let last = lastReceive {
            intervalsMs.append(date.timeIntervalSince(last) * 1000)
        }
        if firstReceive == nil { firstReceive = date }
        lastReceive = date
        count += 1
    }

    func summary() -> String {
        lock.lock(); defer { lock.unlock() }
        func line(_ name: String, _ values: [Double]) -> String {
            let sorted = values.sorted()
            guard !sorted.isEmpty else { return "  \(name): no samples" }
            let mean = sorted.reduce(0, +) / Double(sorted.count)
            return String(
                format: "  %@: mean %.2f ms  p50 %.2f ms  p95 %.2f ms  max %.2f ms",
                name, mean, percentile(sorted, 0.5), percentile(sorted, 0.95), sorted.last!
            )
        }
        let fps: Double
        if count > 1, let first = firstReceive, let last = lastReceive, last.timeIntervalSince(first) > 0 {
            fps = Double(count - 1) / last.timeIntervalSince(first)
        } else {
            fps = 0
        }
        return """
        Frames received: \(count)  (\(String(format: "%.1f", fps)) fps)
        \(line("js render      ", renderMs))
        \(line("gl readPixels  ", readMs))
        \(line("channel xfer   ", transferMs))
        \(line("ci composite   ", compositeMs))
        \(line("frame interval ", intervalsMs))
        """
    }
}

/// Minimal loopback HTTP/1.1 server (Connection: close) for the http channel.
/// Serves the overlay page + three.min.js and accepts raw RGBA POST /frame.
// Mutable listener state is confined to `queue`; callbacks only enqueue work
// back onto that same queue.
final class LoopbackServer: @unchecked Sendable {
    struct FrameArrival {
        let data: Data
        let renderMs: Double
        let readMs: Double
        let wallMs: Double
    }

    private final class ConnectionState {
        var connection: NWConnection?
        var headersParsed = false
        var headerBuffer = Data()
        var contentLength = 0
        var body = Data()
        var method = ""
        var path = ""
        var query: [String: String] = [:]
        var responded = false
    }

    private let queue = DispatchQueue(label: "ai.kortexa.aicamera.spike.http")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: ConnectionState] = [:]
    private let resourcesDir: URL
    private let onFrame: (FrameArrival) -> Void
    private var portContinuation: CheckedContinuation<UInt16, Error>?
    private(set) var port: UInt16 = 0

    init(resourcesDir: URL, onFrame: @escaping (FrameArrival) -> Void) {
        self.resourcesDir = resourcesDir
        self.onFrame = onFrame
    }

    func start() async throws -> UInt16 {
        // Pick an ephemeral port to avoid clashing with anything on the machine.
        let candidate = UInt16(49_152 + Int.random(in: 0..<16_000))
        let params = NWParameters.tcp
        guard let portEndpoint = NWEndpoint.Port(rawValue: candidate) else {
            throw NSError(domain: "AICameraOverlaySpike", code: 1, userInfo: [NSLocalizedDescriptionKey: "invalid port"])
        }
        let listener = try NWListener(using: params, on: portEndpoint)
        self.listener = listener
        return try await withCheckedThrowingContinuation { continuation in
            self.portContinuation = continuation
            listener.newConnectionHandler = { [weak self] connection in
                self?.queue.async { self?.handle(connection) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .waiting:
                    guard let portValue = self.listener?.port?.rawValue else { return }
                    self.port = portValue
                    self.portContinuation?.resume(returning: portValue)
                    self.portContinuation = nil
                case let .failed(error):
                    self.portContinuation?.resume(throwing: error)
                    self.portContinuation = nil
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            for state in self.connections.values {
                state.connection?.cancel()
            }
            self.connections.removeAll()
            self.listener?.cancel()
        }
    }

    private func handle(_ connection: NWConnection) {
        let state = ConnectionState()
        state.connection = connection
        connections[ObjectIdentifier(connection)] = state
        connection.start(queue: queue)
        receiveMore(state: state)
    }

    private func receiveMore(state: ConnectionState) {
        guard let connection = state.connection else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            self.queue.async {
                if let data, !data.isEmpty {
                    if !state.headersParsed {
                        state.headerBuffer.append(data)
                        if state.headerBuffer.contains([0x0d, 0x0a, 0x0d, 0x0a]) {
                            state.headersParsed = true
                            self.parseHeaders(state: state)
                            if state.method == "GET" {
                                self.serveFile(state: state)
                                return
                            }
                            if state.body.count >= state.contentLength {
                                self.handleFrame(state: state)
                                return
                            }
                        }
                    } else {
                        state.body.append(data)
                        if state.method == "POST" && state.body.count >= state.contentLength {
                            self.handleFrame(state: state)
                            return
                        }
                    }
                }
                if error != nil || isComplete || state.responded {
                    self.connections[ObjectIdentifier(connection)] = nil
                    connection.cancel()
                    return
                }
                self.receiveMore(state: state)
            }
        }
    }

    private func parseHeaders(state: ConnectionState) {
        let marker: [UInt8] = [0x0d, 0x0a, 0x0d, 0x0a]
        guard let headerEnd = state.headerBuffer.firstRange(of: Data(marker)) else { return }
        let headerData = state.headerBuffer.subdata(in: state.headerBuffer.startIndex..<headerEnd.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else { return }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return }
        state.method = String(parts[0])
        let rawPath = String(parts[1])
        if let question = rawPath.firstIndex(of: "?") {
            state.path = String(rawPath[rawPath.startIndex..<question])
            for pair in rawPath[rawPath.index(after: question)...].components(separatedBy: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                if kv.count == 2 {
                    state.query[String(kv[0])] = String(kv[1]).removingPercentEncoding
                }
            }
        } else {
            state.path = rawPath
        }
        for line in lines.dropFirst() {
            if let colon = line.firstIndex(of: ":") {
                let name = line[line.startIndex..<colon].lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if name == "content-length", let length = Int(value) {
                    state.contentLength = length
                }
            }
        }
        // Body bytes that arrived together with the headers.
        state.body = state.headerBuffer.subdata(in: headerEnd.upperBound..<state.headerBuffer.endIndex)
        state.headerBuffer = Data()
    }

    private func serveFile(state: ConnectionState) {
        let name = state.path == "/" ? "overlay.html" : String(state.path.dropFirst())
        let url = resourcesDir.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else {
            respond(state: state, status: "404 Not Found", contentType: "text/plain", body: Data("not found".utf8))
            return
        }
        let contentType = name.hasSuffix(".js") ? "application/javascript" : "text/html"
        respond(state: state, status: "200 OK", contentType: contentType, body: data)
    }

    private func handleFrame(state: ConnectionState) {
        let body = state.body.prefix(state.contentLength)
        state.body = Data()
        let renderMs = Double(state.query["r"] ?? "0") ?? 0
        let readMs = Double(state.query["d"] ?? "0") ?? 0
        let wallMs = Double(state.query["t"] ?? "0") ?? 0
        onFrame(FrameArrival(data: Data(body), renderMs: renderMs, readMs: readMs, wallMs: wallMs))
        respond(state: state, status: "200 OK", contentType: "text/plain", body: Data())
    }

    private func respond(state: ConnectionState, status: String, contentType: String, body: Data) {
        state.responded = true
        let head = "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n"
        var payload = Data(head.utf8)
        payload.append(body)
        state.connection?.send(content: payload, contentContext: .defaultMessage, isComplete: true, completion: .contentProcessed { _ in
            state.connection?.cancel()
        })
    }
}

final class Compositor {
    let width: Int
    let height: Int
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private var background: CVPixelBuffer?
    private var outputPool: CVPixelBufferPool?

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    func makeBackground() {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
        ]
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer) == kCVReturnSuccess,
              let buffer else { return }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return }

        // Synthetic "camera" frame: dark gradient, grid, label.
        let colors = [
            CGColor(red: 0.16, green: 0.19, blue: 0.24, alpha: 1),
            CGColor(red: 0.05, green: 0.06, blue: 0.09, alpha: 1),
        ]
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1]) {
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: 0, y: 0),
                end: CGPoint(x: 0, y: CGFloat(height)),
                options: []
            )
        }
        context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.08))
        context.setLineWidth(1)
        var x: CGFloat = 0
        while x <= CGFloat(width) {
            context.move(to: CGPoint(x: x, y: 0))
            context.addLine(to: CGPoint(x: x, y: CGFloat(height)))
            x += 80
        }
        var y: CGFloat = 0
        while y <= CGFloat(height) {
            context.move(to: CGPoint(x: 0, y: y))
            context.addLine(to: CGPoint(x: CGFloat(width), y: y))
            y += 80
        }
        context.strokePath()

        let label = "SYNTHETIC CAMERA \(width)x\(height) - overlay spike"
        let labelAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 20, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.85),
        ]
        (label as NSString).draw(at: CGPoint(x: 16, y: 16), withAttributes: labelAttributes)
        background = buffer
    }

    /// Composites the overlay (with alpha) over the synthetic camera frame,
    /// scaling the overlay to the output size when it was rendered smaller.
    func composite(overlay: CVPixelBuffer) -> (CVPixelBuffer, Double)? {
        guard let background else { return nil }
        let start = Date()
        var overlayImage = CIImage(cvPixelBuffer: overlay)
        if overlayImage.extent.width != CGFloat(width) || overlayImage.extent.height != CGFloat(height) {
            let scale = max(CGFloat(width) / overlayImage.extent.width,
                            CGFloat(height) / overlayImage.extent.height)
            overlayImage = overlayImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let cropX = (overlayImage.extent.width - CGFloat(width)) / 2
            let cropY = (overlayImage.extent.height - CGFloat(height)) / 2
            overlayImage = overlayImage
                .transformed(by: CGAffineTransform(translationX: -cropX, y: -cropY))
                .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        }
        let composed = overlayImage.composited(over: CIImage(cvPixelBuffer: background))
        var output: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
        ]
        if outputPool == nil {
            var pool: CVPixelBufferPool?
            if CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool) == kCVReturnSuccess {
                outputPool = pool
            }
        }
        guard let pool = outputPool,
              CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &output) == kCVReturnSuccess,
              let output else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        ciContext.render(composed, to: output, bounds: bounds, colorSpace: CGColorSpaceCreateDeviceRGB())
        return (output, Date().timeIntervalSince(start) * 1000)
    }

    func savePNG(_ buffer: CVPixelBuffer, to url: URL) -> Bool {
        let image = CIImage(cvPixelBuffer: buffer)
        guard let data = ciContext.pngRepresentation(
            of: image,
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB(),
            options: [:]
        ) else { return false }
        do {
            try data.write(to: url)
            return true
        } catch {
            return false
        }
    }
}

final class SpikeMessageHandler: NSObject, WKScriptMessageHandler {
    let onFrame: ([String: Any]) -> Void
    let onLog: (String) -> Void

    init(onFrame: @escaping ([String: Any]) -> Void, onLog: @escaping (String) -> Void) {
        self.onFrame = onFrame
        self.onLog = onLog
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        switch message.name {
        case "frame":
            if let body = message.body as? [String: Any] {
                onFrame(body)
            } else {
                onLog("frame message with unexpected body type: \(type(of: message.body))")
            }
        case "log":
            onLog("\(message.body)")
        default:
            break
        }
    }
}

final class SpikeNavigationHandler: NSObject, WKNavigationDelegate {
    let onLog: (String) -> Void

    init(onLog: @escaping (String) -> Void) {
        self.onLog = onLog
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.evaluateJavaScript(
            "[typeof window.THREE, window.THREE && window.THREE.REVISION, typeof window.WebGL2RenderingContext].join('|')"
        ) { [onLog] value, error in
            if let error {
                onLog("page ready; JavaScript probe failed: \(error.localizedDescription)")
            } else {
                onLog("page ready; JavaScript probe: \(value ?? "<missing>")")
            }
        }
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        onLog("page navigation failed: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        onLog("page load failed: \(error.localizedDescription)")
    }
}

final class OverlaySpike {
    private let config: SpikeConfig
    private let compositor: Compositor
    private let stats = FrameStats()
    private let workQueue = DispatchQueue(label: "ai.kortexa.aicamera.spike.work")
    private var window: NSWindow?
    private var webView: WKWebView?
    private var handler: SpikeMessageHandler?
    private var navigationHandler: SpikeNavigationHandler?
    private var server: LoopbackServer?
    private let outDir: URL
    private let startedAt = Date()
    private var frameCount = 0

    init(config: SpikeConfig) {
        self.config = config
        self.compositor = Compositor(width: config.width, height: config.height)
        self.outDir = URL(fileURLWithPath: config.outDir, isDirectory: true)
    }

    @MainActor
    func start() async {
        compositor.makeBackground()
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        // With .copy("Resources") the directory sits at the bundle root.
        let resourcesDir = Bundle.module.bundleURL.appendingPathComponent("Resources")
        guard FileManager.default.fileExists(atPath: resourcesDir.appendingPathComponent("overlay.html").path) else {
            log("FATAL: overlay.html not found in \(resourcesDir.path)")
            return
        }

        let frameHandler = SpikeMessageHandler(
            onFrame: { [weak self] body in self?.handleBase64Frame(body) },
            onLog: { [weak self] line in self?.log(line) }
        )
        handler = frameHandler

        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(frameHandler, name: "frame")
        configuration.userContentController.add(frameHandler, name: "log")

        let frame = NSRect(x: 0, y: 0, width: config.width, height: config.height)
        let webView = WKWebView(frame: frame, configuration: configuration)
        let navigationHandler = SpikeNavigationHandler(
            onLog: { [weak self] line in self?.log(line) }
        )
        webView.navigationDelegate = navigationHandler
        self.navigationHandler = navigationHandler
        self.webView = webView

        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = webView
        window.ignoresMouseEvents = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.alphaValue = 0.02
        if config.mode == "visible" {
            window.setFrameOrigin(NSPoint(x: 0, y: 0))
        } else if config.mode == "hidden" {
            // On-screen (so WebKit keeps rendering) but behind the desktop wallpaper.
            window.setFrameOrigin(NSPoint(x: 0, y: 0))
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
            window.alphaValue = 1.0
        } else {
            window.setFrameOrigin(NSPoint(x: -30_000, y: 0))
        }
        window.orderFrontRegardless()
        self.window = window

        if config.channel == "http" {
            do {
                let server = LoopbackServer(resourcesDir: resourcesDir) { [weak self] arrival in
                    self?.handleHTTPFrame(arrival)
                }
                let port = try await server.start()
                self.server = server
                log("loopback server listening on 127.0.0.1:\(port)")
                let pageURL = URL(string: "http://127.0.0.1:\(port)/overlay.html")!
                webView.load(URLRequest(url: pageURL))
            } catch {
                log("FATAL: loopback server failed: \(error)")
                return
            }
        } else {
            let pageURL = resourcesDir.appendingPathComponent("overlay.html")
            webView.loadFileURL(pageURL, allowingReadAccessTo: resourcesDir)
        }
        log("spike started: \(config.width)x\(config.height), channel=\(config.channel), mode=\(config.mode), duration=\(config.duration)s")
    }

    private func log(_ line: String) {
        let timestamp = Date().timeIntervalSince(startedAt)
        print(String(format: "[%.2fs] %@", timestamp, line))
    }

    private func handleBase64Frame(_ body: [String: Any]) {
        let receiveDate = Date()
        guard let b64 = body["b64"] as? String,
              let data = Data(base64Encoded: b64, options: []),
              let width = body["w"] as? Int,
              let height = body["h"] as? Int,
              data.count == width * height * 4 else {
            log("base64 frame invalid; keys=\(Array(body.keys).sorted())")
            return
        }
        let renderMs = (body["renderMs"] as? Double) ?? 0
        let readMs = (body["readMs"] as? Double) ?? 0
        let encMs = (body["encMs"] as? Double) ?? 0
        let wallMs = (body["wallMs"] as? Double) ?? 0
        let transferMs = encMs + max(0, receiveDate.timeIntervalSince1970 * 1000 - wallMs)
        workQueue.async { [weak self] in
            self?.processFrame(data: data, width: width, height: height,
                               renderMs: renderMs, readMs: readMs, transferMs: transferMs, at: receiveDate)
        }
    }

    private func handleHTTPFrame(_ arrival: LoopbackServer.FrameArrival) {
        let receiveDate = Date()
        let width = config.width
        let height = config.height
        guard arrival.data.count == width * height * 4 else {
            log("http frame size mismatch: got \(arrival.data.count), want \(width * height * 4)")
            return
        }
        let transferMs = arrival.wallMs > 0 ? max(0, receiveDate.timeIntervalSince1970 * 1000 - arrival.wallMs) : 0
        workQueue.async { [weak self] in
            self?.processFrame(data: arrival.data, width: width, height: height,
                               renderMs: arrival.renderMs, readMs: arrival.readMs,
                               transferMs: transferMs, at: receiveDate)
        }
    }

    private func processFrame(
        data: Data,
        width: Int,
        height: Int,
        renderMs: Double,
        readMs: Double,
        transferMs: Double,
        at receiveDate: Date
    ) {
        guard let overlay = makeOverlayPixelBuffer(data: data, width: width, height: height) else {
            log("failed to build overlay CVPixelBuffer")
            return
        }
        var compositeMs = 0.0
        if let (composed, elapsed) = compositor.composite(overlay: overlay) {
            compositeMs = elapsed
            frameCount += 1
            if frameCount % config.saveEvery == 0 {
                let url = outDir.appendingPathComponent(String(format: "frame-%04d.png", frameCount))
                if compositor.savePNG(composed, to: url) {
                    log("saved \(url.lastPathComponent) (overlay \(width)x\(height))")
                }
            }
        }
        stats.record(renderMs: renderMs, readMs: readMs, transferMs: transferMs, compositeMs: compositeMs, at: receiveDate)
        if stats.count == 1 {
            log("first frame received via \(config.channel) channel")
        }
    }

    /// Wraps readPixels RGBA bytes (bottom row first, straight alpha) into a 32BGRA
    /// CVPixelBuffer (top row first, premultiplied alpha) — the format CoreImage
    /// expects for 32BGRA buffers.
    private func makeOverlayPixelBuffer(data: Data, width: Int, height: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
        ]
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer) == kCVReturnSuccess,
              let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let rowSize = width * 4
        data.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
            guard let sourceBase = source.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for y in 0..<height {
                let sourceRow = sourceBase + (height - 1 - y) * rowSize
                let destinationRow = base + y * rowBytes
                for x in 0..<width {
                    let s = sourceRow + x * 4
                    let d = destinationRow + x * 4
                    let a = s[3]
                    d[0] = UInt8((Int(s[2]) * Int(a)) / 255)
                    d[1] = UInt8((Int(s[1]) * Int(a)) / 255)
                    d[2] = UInt8((Int(s[0]) * Int(a)) / 255)
                    d[3] = a
                }
            }
        }
        return buffer
    }

    func finish() {
        print("=== AICameraOverlaySpike summary (\(config.channel), \(config.width)x\(config.height)) ===")
        print(stats.summary())
        if stats.count == 0 {
            print("WARNING: no frames received. The hidden web view may not be rendering.")
            print("Try: swift run AICameraOverlaySpike --mode visible")
        }
        server?.stop()
        window?.orderOut(nil)
    }
}

let config = parseConfig(Array(CommandLine.arguments.dropFirst()))
let spike = OverlaySpike(config: config)
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

Task { @MainActor in
    await spike.start()
}
DispatchQueue.main.asyncAfter(deadline: .now() + config.duration) {
    spike.finish()
    NSApp.terminate(nil)
}
app.run()
