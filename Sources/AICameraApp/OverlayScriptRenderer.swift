import AICameraCore
import AppKit
import CoreVideo
import Foundation
import os.log
import WebKit

/// Renders overlay scripts (three.js, WebGL2) in a hidden WKWebView and
/// publishes the latest transparent frame to a lock-based slot that the
/// capture path reads synchronously.
///
/// Safety model: the script is untrusted (model-generated). It runs in the
/// WebKit web-content process (crash isolation), has no network (all remote
/// requests blocked, opaque origin, non-persistent storage), and can only
/// reach the host through the explicit `window.AICamera` bridge and the
/// frame/log message handlers. A hung or crashed web view degrades to "no
/// overlay": the slot simply goes stale and the compositor skips it.
///
/// Lifecycle methods (`start`, `stop`, `load`, `clear`, `updateSceneData`)
/// are main-thread. `latestFreshOverlay()` is safe from any thread.
final class OverlayScriptRenderer: NSObject {
    struct Frame {
        let pixelBuffer: CVPixelBuffer
        let date: Date
    }

    /// An overlay frame older than this is ignored by the compositor.
    static let overlayFreshnessSeconds: TimeInterval = 0.15

    /// The canvas renders at half the typical output resolution: the base64
    /// channel stays cheap (~5 ms/frame) and the compositor upscales.
    private let canvasWidth = 640
    private let canvasHeight = 360

    private let scriptConfiguration: ScriptOverlayConfiguration
    private let onLog: @Sendable (String) -> Void
    private let slot = LatestValueSlot<Frame>()
    private static let logger = Logger(subsystem: "ai.kortexa.aicamera", category: "overlay-script")

    /// Routes a diagnostic line to the UI log slot, the unified log, and a
    /// file (the file is the reliable diagnostic during development).
    private func logLine(_ line: String) {
        Self.logger.info("\(line, privacy: .public)")
        Self.diag(line)
        onLog(line)
    }

    private static func diag(_ line: String) {
        let entry = "[\(ISO8601DateFormatter().string(from: Date()))] \(line)\n"
        guard let data = entry.data(using: .utf8) else { return }
        let url = URL(fileURLWithPath: "/tmp/aicamera-overlay-diag.log")
        if FileManager.default.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }

    private var window: NSWindow?
    private var webView: WKWebView?
    private var messageHandler: FrameMessageHandler?
    private var pageReady = false
    private var pendingScript: String?
    private var scriptExpiry: Date?
    private var expiryTask: Task<Void, Never>?
    private var generation: UInt64 = 0

    init(
        scriptConfiguration: ScriptOverlayConfiguration,
        onLog: @escaping @Sendable (String) -> Void
    ) {
        self.scriptConfiguration = scriptConfiguration
        self.onLog = onLog
    }

    // MARK: - Lifecycle (main thread)

    func start() {
        guard window == nil else { return }
        Self.diag("start() entered")
        let handler = FrameMessageHandler(
            onFrame: { [weak self] body in self?.handleFrame(body) },
            onLog: { [weak self] line in self?.logLine(line) }
        )
        messageHandler = handler

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.userContentController.add(handler, name: "frame")
        configuration.userContentController.add(handler, name: "log")
        // Block every remote http(s) request; the page is fully local.
        let ruleList = "[{\"trigger\":{\"url-filter\":\"^https?://\",\"if-resource-type\":[\"main-frame\",\"sub-frame\",\"image\",\"style-sheet\",\"script\",\"xhr\",\"websocket\",\"subresource\",\"media-source\",\"font\",\"other\"]},\"action\":\"block\"}]"
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "ai.kortexa.aicamera.overlay",
            encodedContentRuleList: ruleList
        ) { list, _ in
            if let list {
                configuration.userContentController.add(list)
            }
        }

        let frame = NSRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight)
        let webView = WKWebView(frame: frame, configuration: configuration)
        // The web content must be transparent so the (hidden) window never
        // paints a white rectangle; only the composited camera frame shows.
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = self
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
        // The window must stay on-screen for WebKit to keep rendering, but it
        // must be invisible to the user. A near-zero alpha composites it away
        // while readPixels still reads the full-quality WebGL drawing buffer.
        // (The below-desktop level alone does not hide it on this OS.)
        window.alphaValue = 0.01
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
        window.collectionBehavior = [.stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.orderFrontRegardless()
        self.window = window

        guard let pageURL = Bundle.main.url(forResource: "overlay", withExtension: "html") else {
            logLine("Overlay page is missing from the app bundle.")
            return
        }
        Self.diag("loading page: \(pageURL.path)")
        webView.loadFileURL(pageURL, allowingReadAccessTo: pageURL.deletingLastPathComponent())
    }

    func stop() {
        generation &+= 1
        scriptExpiry = nil
        pendingScript = nil
        expiryTask?.cancel()
        expiryTask = nil
        slot.clear()
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        window?.orderOut(nil)
        webView = nil
        window = nil
        messageHandler = nil
        pageReady = false
    }

    // MARK: - Scripts (main thread)

    /// Loads and runs a new overlay script, replacing any active one.
    /// Returns false when the script is rejected (empty or oversized).
    @discardableResult
    func load(script: String, ttlSeconds: Double) -> Bool {
        Self.diag("load() scriptBytes=\(script.count) pageReady=\(pageReady)")
        guard scriptConfiguration.enabled,
              !script.isEmpty,
              script.count <= scriptConfiguration.maxScriptBytes else {
            return false
        }
        let ttl = min(max(ttlSeconds, 1), scriptConfiguration.maximumTTLSeconds)
        generation &+= 1
        scriptExpiry = Date().addingTimeInterval(ttl)
        if pageReady {
            inject(script: script)
        } else {
            pendingScript = script
        }
        scheduleExpiry()
        return true
    }

    /// Deactivates the current script and clears pending overlay frames.
    func clear() {
        generation &+= 1
        scriptExpiry = nil
        pendingScript = nil
        expiryTask?.cancel()
        expiryTask = nil
        slot.clear()
        if pageReady {
            webView?.evaluateJavaScript("window.AICamera._deactivate()")
        }
    }

    /// Pushes the current scene snapshot (JSON) to the page. Only called
    /// when `allowSceneData` is enabled.
    func updateSceneData(_ json: String) {
        guard scriptConfiguration.allowSceneData, pageReady else { return }
        webView?.evaluateJavaScript("window.AICamera._setSceneData(\(json))")
    }

    // MARK: - Real-time read path (any thread)

    /// Returns the latest overlay frame when it is still fresh, else nil.
    func latestFreshOverlay() -> CVPixelBuffer? {
        slot.fresh(maxAge: Self.overlayFreshnessSeconds)?.pixelBuffer
    }

    // MARK: - Frame intake (main thread)

    private var loggedFirstFrame = false
    private func handleFrame(_ body: [String: Any]) {
        if !loggedFirstFrame {
            loggedFirstFrame = true
            Self.diag("first overlay frame received")
        }
        guard let b64 = body["b64"] as? String,
              let data = Data(base64Encoded: b64, options: []),
              let width = body["w"] as? Int,
              let height = body["h"] as? Int,
              width == canvasWidth,
              height == canvasHeight,
              data.count == width * height * 4,
              let pixelBuffer = Self.makeOverlayPixelBuffer(data: data, width: width, height: height) else {
            return
        }
        slot.store(Frame(pixelBuffer: pixelBuffer, date: Date()))
    }

    /// Wraps readPixels RGBA bytes (bottom row first, straight alpha) into a
    /// 32BGRA CVPixelBuffer (top row first, premultiplied alpha) — the layout
    /// CoreImage expects for 32BGRA buffers.
    private static func makeOverlayPixelBuffer(data: Data, width: Int, height: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
        ]
        guard CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
            attributes as CFDictionary, &buffer
        ) == kCVReturnSuccess, let buffer else { return nil }
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

    // MARK: - Script injection and expiry (main thread)

    private func inject(script: String) {
        Self.diag("inject() bytes=\(script.count)")
        let fps = scriptConfiguration.maximumFps
        // The script is passed as a JSON string and run through indirect eval
        // inside the try/catch, so a syntax error in the script is thrown at
        // eval time and reported here instead of failing the whole injection.
        guard let scriptData = try? JSONEncoder().encode(script),
              let scriptJSON = String(data: scriptData, encoding: .utf8) else {
            logLine("Failed to encode overlay script.")
            return
        }
        let js = """
        (function () {
          var diag = 'AICamera=' + (typeof window.AICamera) + ' THREE=' + (typeof window.THREE);
          if (typeof window.AICamera === 'undefined') {
            window.webkit.messageHandlers.log.postMessage('INJECT ABORT: bridge not ready | ' + diag);
            return;
          }
          window.AICamera._reset();
          try {
            (0, eval)(\(scriptJSON));
            window.AICamera._activate(\(fps));
            window.AICamera.log('overlay script active');
          } catch (e) {
            window.AICamera.log('SCRIPT ERROR: ' + (e && e.message ? e.message : e) + ' | ' + diag);
          }
        })()
        """
        webView?.evaluateJavaScript(js) { _, error in
            if let error {
                self.logLine("Overlay script failed to run: \(error.localizedDescription)")
            }
        }
    }

    private func scheduleExpiry() {
        expiryTask?.cancel()
        expiryTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard let self, let expiry = self.scriptExpiry else { return }
                if Date() >= expiry {
                    self.clear()
                    self.logLine("Overlay script expired.")
                    return
                }
            }
        }
    }
}

extension OverlayScriptRenderer: WKNavigationDelegate {
    /// The page is fully local. Cancel any navigation away from file:// URLs.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        guard navigationAction.request.url?.scheme == "file" else {
            logLine("Blocked non-file navigation: \(navigationAction.request.url?.absoluteString ?? "?")")
            return .cancel
        }
        return .allow
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageReady = true
        Self.diag("didFinish (page ready)")
        if let pending = pendingScript {
            pendingScript = nil
            inject(script: pending)
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // The web-content process crashed. The overlay disappears (stale
        // slot) and the page is reloaded so a later script can run.
        generation &+= 1
        scriptExpiry = nil
        pendingScript = nil
        pageReady = false
        slot.clear()
        logLine("Overlay renderer crashed; reloading.")
        if let pageURL = Bundle.main.url(forResource: "overlay", withExtension: "html") {
            webView.loadFileURL(pageURL, allowingReadAccessTo: pageURL.deletingLastPathComponent())
        }
    }
}

private final class FrameMessageHandler: NSObject, WKScriptMessageHandler {
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
            }
        case "log":
            onLog("\(message.body)")
        default:
            break
        }
    }
}
