import AICameraCore
import AppKit
import CoreVideo
import Foundation
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
        let faceGeneration: UUID?
        let faceTrackingID: String?
    }

    /// An overlay frame older than this is ignored by the compositor.
    static let overlayFreshnessSeconds: TimeInterval = 0.15

    /// The canvas renders at half the typical output resolution: the base64
    /// channel stays cheap (~5 ms/frame) and the compositor upscales.
    private let canvasWidth = OverlayFramePolicy.width
    private let canvasHeight = OverlayFramePolicy.height

    private let scriptConfiguration: ScriptOverlayConfiguration
    private let onLog: @Sendable (String) -> Void
    private let faceAnchors: FaceAnchorState?
    private let slot = LatestValueSlot<Frame>()
    // Script messages may contain scene or transcript text. Keep only a bounded UI value;
    // never send them to persistent logs. Throttle before scheduling the UI callback.
    private var lastLogTime = -Double.infinity
    private func logLine(_ line: String) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastLogTime >= 0.25 else { return }
        lastLogTime = now
        onLog(String(decoding: line.utf8.prefix(512), as: UTF8.self))
    }

    private var window: NSWindow?
    private var webView: WKWebView?
    private var messageHandler: FrameMessageHandler?
    private var pageReady = false
    private var pendingScript: String?
    private var scriptExpiry: Date?
    private var expiryTask: Task<Void, Never>?
    private var frameGeneration = UUID().uuidString
    private var lastFrameSequence = -1
    private var expectedNavigation: WKNavigation?
    private let pageURL: URL?
    private var pendingSceneData: String?
    private var sceneUpdateInFlight = false
    private var faceEffectGeneration: UUID?
    private var faceUpdateTask: Task<Void, Never>?
    private var faceUpdateInFlight = false
    var isFaceEffect: Bool { faceEffectGeneration != nil }
    private(set) var scriptIsRunning = false

    init(
        scriptConfiguration: ScriptOverlayConfiguration,
        pageURL: URL? = Bundle.main.url(forResource: "overlay", withExtension: "html"),
        faceAnchors: FaceAnchorState? = nil,
        onLog: @escaping @Sendable (String) -> Void
    ) {
        self.scriptConfiguration = scriptConfiguration
        self.pageURL = pageURL
        self.onLog = onLog
        self.faceAnchors = faceAnchors
    }

    // MARK: - Lifecycle (main thread)

    func start() {
        guard window == nil else { return }
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

        guard pageURL != nil else {
            logLine("Overlay page is missing from the app bundle.")
            return
        }
        loadPage()
    }

    func stop() {
        scriptIsRunning = false
        endFaceEffect()
        frameGeneration = UUID().uuidString
        lastFrameSequence = -1
        scriptExpiry = nil
        pendingScript = nil
        expiryTask?.cancel()
        expiryTask = nil
        slot.clear()
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        expectedNavigation = nil
        pendingSceneData = nil
        sceneUpdateInFlight = false
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
    func load(script: String, ttlSeconds: Double, followsFace: Bool = false) -> Bool {
        guard scriptConfiguration.enabled,
              webView != nil, !script.isEmpty,
              script.utf8.count <= scriptConfiguration.maxScriptBytes,
              ttlSeconds.isFinite, (1...scriptConfiguration.maximumTTLSeconds).contains(ttlSeconds),
              !followsFace || faceAnchors != nil else {
            return false
        }
        frameGeneration = UUID().uuidString
        lastFrameSequence = -1
        slot.clear()
        scriptIsRunning = false
        endFaceEffect()
        if followsFace, let faceAnchors {
            faceEffectGeneration = faceAnchors.begin()
            startFaceUpdates()
        }
        scriptExpiry = Date().addingTimeInterval(ttlSeconds)
        pendingScript = script
        // A new document releases old timers, callbacks, scene globals, and GPU resources.
        // If the initial document is still loading, replace its single pending script instead.
        if pageReady { loadPage() }
        scheduleExpiry()
        return true
    }

    /// Deactivates the current script and clears pending overlay frames.
    func clear() {
        scriptIsRunning = false
        endFaceEffect()
        frameGeneration = UUID().uuidString
        lastFrameSequence = -1
        scriptExpiry = nil
        pendingScript = nil
        expiryTask?.cancel()
        expiryTask = nil
        slot.clear()
        if webView != nil { loadPage() }
    }

    /// Pushes the current scene snapshot (JSON) to the page. Only called
    /// when `allowSceneData` is enabled.
    func updateSceneData(_ json: String) {
        guard scriptConfiguration.allowSceneData, pageReady, scriptExpiry != nil,
              json.utf8.count <= 64 * 1_024, let data = json.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data)) != nil else { return }
        pendingSceneData = json
        sendPendingSceneData()
    }

    private func sendPendingSceneData() {
        guard !sceneUpdateInFlight, let json = pendingSceneData else { return }
        pendingSceneData = nil
        sceneUpdateInFlight = true
        let current = frameGeneration
        webView?.evaluateJavaScript("window.AICamera._setSceneData(\(json))") { [weak self] _, _ in
            guard let self, self.frameGeneration == current else { return }
            self.sceneUpdateInFlight = false
            self.sendPendingSceneData()
        }
    }

    private func endFaceEffect() {
        faceUpdateTask?.cancel()
        faceUpdateTask = nil
        if let generation = faceEffectGeneration { faceAnchors?.end(generation: generation) }
        faceEffectGeneration = nil
        faceUpdateInFlight = false
    }

    private func startFaceUpdates() {
        let generation = faceEffectGeneration
        faceUpdateTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.faceEffectGeneration == generation else { return }
                self.sendFaceUpdate()
                try? await Task.sleep(for: .milliseconds(60))
            }
        }
    }

    private func sendFaceUpdate() {
        guard pageReady, faceEffectGeneration != nil, !faceUpdateInFlight else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let json = faceAnchors?.fresh(at: now)?.json(at: now) ?? "null"
        guard json.utf8.count <= 2_048 else { return }
        faceUpdateInFlight = true
        let generation = frameGeneration
        webView?.evaluateJavaScript("window.AICamera._setFaceAnchor(\(json))") { [weak self] _, _ in
            guard let self, self.frameGeneration == generation else { return }
            self.faceUpdateInFlight = false
        }
    }

    // MARK: - Real-time read path (any thread)

    /// Returns the latest overlay frame when it is still fresh, else nil.
    func latestFreshOverlay() -> CVPixelBuffer? {
        guard let frame = slot.fresh(maxAge: Self.overlayFreshnessSeconds) else { return nil }
        if let generation = frame.faceGeneration {
            guard let tracked = faceAnchors?.fresh(), tracked.generation == generation,
                  tracked.trackingID.uuidString == frame.faceTrackingID else { return nil }
        }
        return frame.pixelBuffer
    }

    // MARK: - Frame intake (main thread)

    private func handleFrame(_ body: [String: Any]) {
        guard let expiry = scriptExpiry, Date() < expiry,
              let frame = OverlayFramePolicy.decode(body, generation: frameGeneration, after: lastFrameSequence) else { return }
        lastFrameSequence = frame.sequence
        // The page keeps one unacknowledged frame. A slow native consumer pauses publication
        // instead of accumulating megabyte messages; rendering and camera capture stay independent.
        webView?.evaluateJavaScript("window.AICamera._ackFrame('\(frameGeneration)', \(frame.sequence))")
        guard let pixelBuffer = Self.makeOverlayPixelBuffer(data: frame.pixels, width: canvasWidth, height: canvasHeight) else { return }
        slot.store(Frame(pixelBuffer: pixelBuffer, date: Date(), faceGeneration: faceEffectGeneration,
                         faceTrackingID: body["faceTrackingID"] as? String))
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
        let fps = scriptConfiguration.maximumFps
        let currentGeneration = frameGeneration
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
            return false;
          }
          window.AICamera._reset();
          try {
            (0, eval)(\(scriptJSON));
            window.AICamera._activate(\(fps), '\(currentGeneration)');
            window.AICamera.log('overlay script active');
            return true;
          } catch (e) {
            window.AICamera.log('SCRIPT ERROR: ' + (e && e.message ? e.message : e) + ' | ' + diag);
            return false;
          }
        })()
        """
        webView?.evaluateJavaScript(js) { [weak self] result, error in
            guard let self, self.frameGeneration == currentGeneration else { return }
            if let error {
                self.logLine("Overlay script failed to run: \(error.localizedDescription)")
            }
            self.scriptIsRunning = error == nil && result as? Bool == true
            if self.isFaceEffect && !self.scriptIsRunning { self.clear() }
        }
    }

    private func loadPage() {
        pageReady = false
        pendingSceneData = nil
        sceneUpdateInFlight = false
        faceUpdateInFlight = false
        webView?.stopLoading()
        guard let pageURL else { return }
        expectedNavigation = webView?.loadFileURL(pageURL, allowingReadAccessTo: pageURL.deletingLastPathComponent())
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
    /// Only the bundled renderer document may navigate in this web view.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        guard navigationAction.request.url == pageURL else {
            logLine("Blocked overlay navigation.")
            return .cancel
        }
        return .allow
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === self.webView, navigation === expectedNavigation else { return }
        pageReady = true
        if let pending = pendingScript {
            pendingScript = nil
            inject(script: pending)
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === self.webView else { return }
        scriptIsRunning = false
        endFaceEffect()
        // The web-content process crashed. The overlay disappears (stale
        // slot) and the page is reloaded so a later script can run.
        frameGeneration = UUID().uuidString
        lastFrameSequence = -1
        scriptExpiry = nil
        pendingScript = nil
        pageReady = false
        slot.clear()
        logLine("Overlay renderer crashed; reloading.")
        expiryTask?.cancel()
        expiryTask = nil
        loadPage()
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
            if let line = message.body as? String { onLog(line) }
        default:
            break
        }
    }
}
