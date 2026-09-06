import Foundation

/// Transport contract; native capture, playback, and tool side effects stay in the host.
public protocol RealtimeConversationClient: AnyObject, Sendable {
    var events: AsyncStream<RealtimeSessionEvent> { get }
    func connect(session: [String: Any]) async throws
    func armOneShotAudio() async throws
    func armConversationAudio() async throws
    func pauseInputAudio() async throws
    func appendInputPCM(_ data: Data, capturedAt: TimeInterval)
    func completeFunctionCall(callID: String, output: String) async throws
    func requestContinuation(_ response: [String: Any]) async throws
    func close() async
}

public extension RealtimeConversationClient {
    func armConversationAudio() async throws { try await armOneShotAudio() }
    func pauseInputAudio() async throws { throw RealtimeSessionFailure.invalidSession }
}

public struct RealtimeFunctionCall: Sendable, Equatable {
    public let callID: String
    public let name: String
    public let arguments: String
    public init(callID: String, name: String, arguments: String) {
        self.callID = callID; self.name = name; self.arguments = arguments
    }
}
public enum RealtimeTranscriptSource: Sendable { case local, remote }
public struct RealtimePCMChunk: Sendable {
    public let data: Data
    public let sampleRate: Int
    public let channels: Int
    public init(data: Data, sampleRate: Int, channels: Int) {
        self.data = data; self.sampleRate = sampleRate; self.channels = channels
    }

    /// The host player accepts at most one second per ingress call. Preserve sample order
    /// when a server sends a larger message, including a final partial second.
    public var playbackBuffers: [Data]? {
        guard (8_000...192_000).contains(sampleRate), channels == 1,
              !data.isEmpty, data.count <= 256 * 1_024, data.count % 2 == 0 else { return nil }
        let bytesPerSecond = sampleRate * MemoryLayout<Int16>.size
        return stride(from: 0, to: data.count, by: bytesPerSecond).map { offset in
            data.subdata(in: (data.startIndex + offset)..<(data.startIndex + min(offset + bytesPerSecond, data.count)))
        }
    }
}
public enum RealtimeSessionEvent: Sendable {
    case connected, speechStarted, speechStopped
    case transcript(source: RealtimeTranscriptSource, text: String, isFinal: Bool)
    case functionCall(RealtimeFunctionCall)
    case responseDone
    case audio(RealtimePCMChunk)
    case error(RealtimeSessionFailure)
}
public enum RealtimeSessionFailure: String, LocalizedError, Sendable {
    case closed, alreadyStarted, invalidURL, invalidCredential, invalidSession
    case connectionTimeout, connectionFailed, serverError, invalidEvent, eventOverflow, toolLimit
    case noSpeechTimeout, utteranceTimeout, responseTimeout
    public var errorDescription: String? {
        switch self {
        case .noSpeechTimeout: return "No speech detected. Start the agent to try again."
        case .utteranceTimeout: return "The 30-second listening limit was reached. Start the agent to try again."
        case .responseTimeout: return "The response timed out. Start the agent to try again."
        case .connectionFailed: return "OpenAI could not connect. Check the network, model, and credential."
        case .serverError: return "OpenAI could not complete this response. Check the model and credential, then try another turn."
        default: return "Realtime connection failed (\(rawValue))."
        }
    }
}

/// Bounded utterances within an explicitly armed conversation. Input stays closed during replies.
/// The transport owns this value on its serial queue and uses monotonic time.
public struct RealtimeTurnGate: Sendable {
    public enum Phase: Equatable, Sendable { case ready, listening, paused, responding, awaitingPlayback, closed }
    public enum Timeout: Equatable, Sendable { case noSpeech, utterance, response }
    public private(set) var phase: Phase = .ready
    public private(set) var deadline: TimeInterval?
    public private(set) var timeout: Timeout?
    private var armedAt: TimeInterval?

    public init() {}
    public var isOpen: Bool { phase == .listening }

    @discardableResult
    public mutating func arm(at now: TimeInterval, continuous: Bool = false) -> Bool {
        guard (phase == .ready || phase == .paused || phase == .awaitingPlayback), now.isFinite else { return false }
        phase = .listening
        armedAt = now
        deadline = continuous ? nil : now + 10
        timeout = continuous ? nil : .noSpeech
        return true
    }

    public mutating func speechStarted(at now: TimeInterval? = nil) {
        guard isOpen, timeout != .utterance, let armedAt else { return }
        let start = now ?? armedAt
        guard start.isFinite else { return }
        deadline = start + 30
        timeout = .utterance
    }

    public mutating func speechStopped(at now: TimeInterval) {
        guard isOpen, now.isFinite else { return }
        phase = .responding
        deadline = now + 120
        timeout = .response
    }

    @discardableResult
    public mutating func responseCompleted() -> Bool {
        guard phase == .responding else { return false }
        phase = .awaitingPlayback
        deadline = nil
        timeout = nil
        return true
    }

    @discardableResult
    public mutating func continueResponse(at now: TimeInterval) -> Bool {
        guard (phase == .ready || phase == .awaitingPlayback), now.isFinite else { return false }
        phase = .responding
        deadline = now + 120
        timeout = .response
        return true
    }

    @discardableResult
    public mutating func expire(at now: TimeInterval) -> Timeout? {
        guard let deadline, now >= deadline else { return nil }
        let reason = timeout
        close()
        return reason
    }

    public mutating func close() {
        phase = .closed
        armedAt = nil
        deadline = nil
        timeout = nil
    }

    /// Discard an unfinished utterance, while preserving an answer that is already in progress.
    @discardableResult
    public mutating func pauseInput() -> Bool {
        guard phase == .listening || phase == .ready else { return false }
        phase = .paused
        armedAt = nil
        deadline = nil
        timeout = nil
        return true
    }
}

/// A bounded transcript for one speaker/item. Deltas are text fragments, not full captions.
public struct RealtimeTranscriptBuffer: Sendable {
    private var itemID: String?
    private var text = ""
    public init() {}

    public mutating func update(fragment: String, itemID: String?, isFinal: Bool) -> String {
        if self.itemID != itemID || isFinal { text = "" }
        self.itemID = itemID
        text = (text + fragment).aicameraLimited(to: AICameraContentLimits.transcriptCharacters)
        let result = text
        if isFinal { text = ""; self.itemID = nil }
        return result
    }
}

/// Reject malformed tool input before any renderer side effect.
public enum RealtimeOverlayCommand: Equatable, Sendable {
    case render(script: String, ttlSeconds: Double)
    case clear

    public static func parse(name: String, arguments: String, configuration: ScriptOverlayConfiguration) -> Self? {
        guard arguments.utf8.count <= configuration.maxScriptBytes + 1_024,
              let data = arguments.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              case let .object(object) = value else { return nil }
        if name == "clear_overlay" { return object.isEmpty ? .clear : nil }
        guard name == "render_overlay",
              Set(object.keys).isSubset(of: ["script", "ttlSeconds"]),
              let script = object["script"]?.stringValue, !script.isEmpty,
              script.utf8.count <= configuration.maxScriptBytes else { return nil }
        let ttl: Double
        if let value = object["ttlSeconds"] {
            guard let number = value.numberValue, number.isFinite,
                  (1...configuration.maximumTTLSeconds).contains(number) else { return nil }
            ttl = number
        } else { ttl = configuration.defaultTTLSeconds }
        return .render(script: script, ttlSeconds: ttl)
    }
}

/// Builds the public Realtime session contract without any credential material.
public enum RealtimeSessionConfiguration {
    public static func request(
        endpoint: EndpointConfiguration,
        conversation: ConversationConfiguration,
        profile: AICameraConfiguration,
        toolsAvailable: Bool,
        agentTools: AgentToolCapabilities? = nil
    ) -> [String: Any] {
        let width = 640
        let height = 360
        let mirror = profile.capture.mirrorVideo ? "mirrored horizontally" : "not mirrored"
        let capabilities = agentTools ?? AgentToolCapabilities(visuals: toolsAvailable)
        let tools = AgentToolCatalog.definitions(capabilities: capabilities, script: profile.overlays.script)
        var instructions = conversation.systemPrompt
        instructions += "\nKeep spoken replies concise. Use one short sentence unless the user asks for detail."
        instructions += AgentToolCatalog.instructions(capabilities: capabilities)
        if capabilities.visuals {
            instructions += """

            You can control a transparent three.js overlay on the camera with the provided client tools.
            The overlay canvas is \(width)x\(height), origin is top-left in canvas pixels, and camera output is \(mirror).
            For a three.js visual request, call render_overlay before claiming it is visible. Use show_card for readable text.
            The script runs immediately in an already-loaded page. Do not wait for DOMContentLoaded or another page event.
            THREE and window.AICamera are already available. Add meshes to AICamera.scene, position AICamera.camera, and use AICamera.onFrame(function(dt) { ... }) for animation.
            Follow this known-good pattern: const mesh = new THREE.Mesh(new THREE.TorusGeometry(1.2, 0.35, 32, 96), new THREE.MeshStandardMaterial({color: 0x8b5cf6})); AICamera.scene.add(mesh); AICamera.camera.position.set(0, 0, 5); AICamera.camera.lookAt(0, 0, 0); AICamera.onFrame(function(dt) { mesh.rotation.x += dt * 0.5; mesh.rotation.y += dt; });
            Adapt the geometry, material, position, and animation to the request, but preserve that host API structure.
            Do not create another canvas, scene, camera, renderer, render loop, or HTML document. Do not call requestAnimationFrame.
            Keep the existing renderer background transparent. Do not use network requests, external assets, recording, or persistence.
            A new render replaces the old one and expires automatically.
            """
        }
        if capabilities.visuals && conversation.includeSceneSummary {
            instructions += "\nCurrent clean scene context: \(profile.overlays.script.allowSceneData ? "bounded sceneData is available to the script" : "no script sceneData is enabled")."
        }
        return [
            "type": "realtime",
            "model": endpoint.model ?? "",
            "instructions": instructions,
            "output_modalities": ["audio"],
            "audio": [
                "input": [
                    "format": ["type": "audio/pcm", "rate": 24_000],
                    "transcription": ["model": "gpt-4o-mini-transcribe"],
                    "turn_detection": [
                        "type": "server_vad",
                        "create_response": true,
                        "interrupt_response": false,
                        "silence_duration_ms": 500
                    ]
                ],
                "output": [
                    "format": ["type": "audio/pcm", "rate": 24_000],
                    "voice": endpoint.options["voice"]?.stringValue ?? ""
                ]
            ],
            "tool_choice": tools.isEmpty ? "none" : "auto",
            "tools": tools
        ]
    }

}
