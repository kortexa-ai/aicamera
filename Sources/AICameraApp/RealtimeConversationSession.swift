import AICameraCore
import Foundation

/// Injected only by synthetic transport tests; production uses URLSession's WebSocket task.
protocol RealtimeWebSocket: Sendable {
    func resume()
    func receive() async throws -> URLSessionWebSocketTask.Message
    func send(_ message: URLSessionWebSocketTask.Message) async throws
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
}
extension URLSessionWebSocketTask: RealtimeWebSocket {}
private extension RealtimeWebSocket {
    func send(_ message: URLSessionWebSocketTask.Message, completion: @escaping @Sendable (Error?) -> Void) {
        Task {
            do { try await send(message); completion(nil) }
            catch { completion(error) }
        }
    }
}

/// Public OpenAI Realtime over WebSocket. Capture and playback belong to the host.
/// A serial queue owns the protocol; capture callbacks only admit bounded PCM copies.
final class RealtimeConversationSession: NSObject, RealtimeConversationClient, @unchecked Sendable {
    struct HeaderCredential: Sendable {
        let field: String
        let value: String
        init(field: String = "Authorization", value: String) { self.field = field; self.value = value }
    }
    typealias FunctionCall = RealtimeFunctionCall
    typealias TranscriptSource = RealtimeTranscriptSource
    typealias PCMChunk = RealtimePCMChunk
    typealias Event = RealtimeSessionEvent
    typealias Failure = RealtimeSessionFailure

    let events: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation
    private let endpointURL: URL
    private let credential: HeaderCredential
    private let queue = DispatchQueue(label: "ai.kortexa.aicamera.realtime")
    private let captureSlots = DispatchSemaphore(value: 2)
    private var urlSession: URLSession?
    private var socket: (any RealtimeWebSocket)?
    private let socketFactory: (@Sendable (URLRequest) -> any RealtimeWebSocket)?
    private var receiveTask: Task<Void, Never>?
    private var connecting: CheckedContinuation<Void, Error>?
    private var timeoutWork: DispatchWorkItem?
    private var gate = RealtimeTurnGate()
    private var armedAt: TimeInterval?
    private var closed = false
    private var ready = false
    private var sessionRequest: [String: Any]?
    private var sentConfiguration = false
    private var outbound: [(data: Data, audioBytes: Int)] = []
    private var sending = false
    private var outboundBytes = 0
    private var audioBytes = 0
    private var calls = Set<String>()
    private var localTranscript = RealtimeTranscriptBuffer()
    private var remoteTranscript = RealtimeTranscriptBuffer()

    init(signalingURL: URL, credential: HeaderCredential, socketFactory: (@Sendable (URLRequest) -> any RealtimeWebSocket)? = nil) {
        self.socketFactory = socketFactory
        endpointURL = signalingURL
        self.credential = credential
        let stream = AsyncStream<Event>.makeStream(bufferingPolicy: .bufferingNewest(256))
        events = stream.stream
        continuation = stream.continuation
        super.init()
    }

    deinit {
        socket?.cancel(with: .goingAway, reason: nil)
        urlSession?.invalidateAndCancel()
        receiveTask?.cancel()
        continuation.finish()
    }

    func connect(session: [String: Any]) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (result: CheckedContinuation<Void, Error>) in
                queue.async { [self] in
                    guard !closed else { result.resume(throwing: Failure.closed); return }
                    guard socket == nil else { result.resume(throwing: Failure.alreadyStarted); return }
                    connecting = result
                    do { try beginLocked(session) }
                    catch { closeLocked(error as? Failure ?? .invalidSession) }
                }
            }
        } onCancel: {
            self.queue.async { self.closeLocked(nil) }
        }
    }

    private func beginLocked(_ session: [String: Any]) throws {
        guard JSONSerialization.isValidJSONObject(session),
              try JSONSerialization.data(withJSONObject: session).count <= 128 * 1_024,
              let model = session["model"] as? String, !model.isEmpty else { throw Failure.invalidSession }
        guard var url = URLComponents(url: endpointURL, resolvingAgainstBaseURL: false),
              url.scheme == "https", url.host == "api.openai.com",
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw Failure.invalidURL
        }
        url.scheme = "wss"
        url.path = "/v1/realtime"
        url.queryItems = [URLQueryItem(name: "model", value: model)]
        guard let socketURL = url.url else { throw Failure.invalidURL }
        guard !credential.field.isEmpty, credential.field.utf8.count <= 128,
              !credential.value.isEmpty, credential.value.utf8.count <= 16 * 1_024,
              !(credential.field + credential.value).contains(where: { $0 == "\r" || $0 == "\n" }) else {
            throw Failure.invalidCredential
        }
        sessionRequest = session
        var request = URLRequest(url: socketURL, timeoutInterval: 30)
        request.setValue(credential.value, forHTTPHeaderField: credential.field)
        let socket: any RealtimeWebSocket
        if let socketFactory {
            socket = socketFactory(request)
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil
            configuration.urlCache = nil
            let urlSession = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            self.urlSession = urlSession
            let task = urlSession.webSocketTask(with: request)
            task.maximumMessageSize = 256 * 1_024
            socket = task
        }
        self.socket = socket
        socket.resume()
        scheduleDeadlineLocked(at: ProcessInfo.processInfo.systemUptime + 30)
        receiveTask = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    let message = try await socket.receive()
                    guard let self else { return }
                    await self.onQueue {
                        guard !self.closed else { return }
                        switch message {
                        case let .string(text): self.receiveLocked(Data(text.utf8))
                        case .data: self.closeLocked(.invalidEvent)
                        @unknown default: self.closeLocked(.invalidEvent)
                        }
                    }
                }
            } catch {
                await self?.onQueue { [weak self] in self?.closeLocked(.connectionFailed) }
            }
        }
    }

    func armOneShotAudio() async throws { try await armAudio(continuous: false) }
    func armConversationAudio() async throws { try await armAudio(continuous: true) }

    private func armAudio(continuous: Bool) async throws {
        try await onQueueThrowing {
            guard self.ready, !self.closed else { throw Failure.closed }
            let now = ProcessInfo.processInfo.systemUptime
            guard self.gate.arm(at: now, continuous: continuous) else { throw Failure.alreadyStarted }
            self.armedAt = now
            self.calls.removeAll()
            self.localTranscript = RealtimeTranscriptBuffer()
            self.remoteTranscript = RealtimeTranscriptBuffer()
            self.discardQueuedAudioLocked()
            self.sendLocked(["type": "input_audio_buffer.clear"])
            self.timeoutWork?.cancel()
            if let deadline = self.gate.deadline { self.scheduleDeadlineLocked(at: deadline) }
        }
    }

    /// Receives 24 kHz mono PCM16 from the already-selected AVCapture microphone.
    /// Work captured before this turn was armed must not enter its sender.
    func appendInputPCM(_ data: Data, capturedAt: TimeInterval) {
        guard !data.isEmpty, data.count <= 24_000, data.count % 2 == 0,
              captureSlots.wait(timeout: .now()) == .success else { return }
        queue.async { [self] in
            defer { captureSlots.signal() }
            guard !closed, gate.isOpen, let armedAt, capturedAt >= armedAt else { return }
            sendLocked(["type": "input_audio_buffer.append", "audio": data.base64EncodedString()], audioBytes: data.count)
        }
    }

    func close() async { await onQueue { self.closeLocked(nil) } }

    func completeFunctionCall(callID: String, output: String) async throws {
        guard !callID.isEmpty, callID.utf8.count <= 512, output.utf8.count <= 64 * 1_024 else {
            throw Failure.invalidEvent
        }
        try await onQueueThrowing {
            guard !self.closed else { throw Failure.closed }
            self.sendLocked(["type": "conversation.item.create", "item": [
                "type": "function_call_output", "call_id": callID, "output": output
            ]])
        }
    }

    func requestContinuation(_ response: [String: Any] = [:]) async throws {
        try await onQueueThrowing {
            guard !self.closed else { throw Failure.closed }
            guard self.gate.continueResponse(at: ProcessInfo.processInfo.systemUptime) else { throw Failure.alreadyStarted }
            self.scheduleDeadlineLocked(at: self.gate.deadline!)
            self.sendLocked(["type": "response.create", "response": response])
        }
    }

    private func sendLocked(_ object: [String: Any], audioBytes: Int = 0) {
        guard !closed else { return }
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object), data.count <= 128 * 1_024,
              outbound.count < 64, outboundBytes + data.count <= 512 * 1_024,
              self.audioBytes + audioBytes <= 48_000 else { closeLocked(.eventOverflow); return }
        outbound.append((data, audioBytes))
        outboundBytes += data.count
        self.audioBytes += audioBytes
        drainLocked()
    }

    private func drainLocked() {
        guard !closed, !sending, !outbound.isEmpty, let socket else { return }
        let item = outbound.removeFirst()
        sending = true
        socket.send(.string(String(decoding: item.data, as: UTF8.self))) { [weak self] error in
            self?.queue.async {
                guard let self, !self.closed else { return }
                self.sending = false
                self.outboundBytes -= item.data.count
                self.audioBytes -= item.audioBytes
                if error != nil { self.closeLocked(.connectionFailed) }
                else { self.drainLocked() }
            }
        }
    }

    private func receiveLocked(_ data: Data) {
        guard data.count <= 256 * 1_024,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { closeLocked(.invalidEvent); return }
        switch type {
        case "session.created":
            guard !sentConfiguration, let sessionRequest else { return }
            sentConfiguration = true
            sendLocked(["type": "session.update", "session": sessionRequest])
            self.sessionRequest = nil
        case "session.updated":
            guard sentConfiguration, !ready else { return }
            ready = true
            timeoutWork?.cancel()
            let result = connecting
            connecting = nil
            result?.resume()
            emit(.connected)
        case "input_audio_buffer.speech_started":
            guard gate.isOpen else { return }
            gate.speechStarted(at: ProcessInfo.processInfo.systemUptime)
            scheduleDeadlineLocked(at: gate.deadline!)
            emit(.speechStarted)
        case "input_audio_buffer.speech_stopped":
            guard gate.isOpen else { return }
            gate.speechStopped(at: ProcessInfo.processInfo.systemUptime)
            // Drop unsent audio immediately, including callbacks admitted before the VAD event.
            discardQueuedAudioLocked()
            scheduleDeadlineLocked(at: gate.deadline!)
            emit(.speechStopped)
        case "conversation.item.input_audio_transcription.delta": transcript(object, key: "delta", source: .local, final: false)
        case "conversation.item.input_audio_transcription.completed": transcript(object, key: "transcript", source: .local, final: true)
        case "response.output_audio_transcript.delta", "response.audio_transcript.delta": transcript(object, key: "delta", source: .remote, final: false)
        case "response.output_audio_transcript.done", "response.audio_transcript.done": transcript(object, key: "transcript", source: .remote, final: true)
        case "response.output_audio.delta", "response.audio.delta":
            guard gate.phase == .responding else { return }
            guard let encoded = object["delta"] as? String,
                  let pcm = Data(base64Encoded: encoded), !pcm.isEmpty, pcm.count % 2 == 0 else {
                closeLocked(.invalidEvent); return
            }
            emit(.audio(.init(data: pcm, sampleRate: 24_000, channels: 1)))
        case "response.function_call_arguments.done": tool(object)
        case "response.output_item.done":
            if let item = object["item"] as? [String: Any], item["type"] as? String == "function_call" { tool(item) }
        case "response.done":
            guard let response = object["response"] as? [String: Any], response["status"] as? String == "completed" else {
                closeLocked(.serverError); return
            }
            // Receipt closes the network deadline. Only the host can rearm after playback drains.
            guard gate.responseCompleted() else { return }
            timeoutWork?.cancel()
            emit(.responseDone)
        case "error": closeLocked(.serverError)
        default: break
        }
    }

    private func transcript(_ object: [String: Any], key: String, source: TranscriptSource, final: Bool) {
        guard let fragment = object[key] as? String, fragment.utf8.count <= 16 * 1_024 else { return }
        let item = object["item_id"] as? String
        let text: String
        switch source {
        case .local: text = localTranscript.update(fragment: fragment, itemID: item, isFinal: final)
        case .remote: text = remoteTranscript.update(fragment: fragment, itemID: item, isFinal: final)
        }
        emit(.transcript(source: source, text: text, isFinal: final))
    }

    private func tool(_ object: [String: Any]) {
        guard gate.phase == .responding else { return }
        guard let id = object["call_id"] as? String, !id.isEmpty, id.utf8.count <= 512,
              !calls.contains(id) else { return }
        guard calls.count < 8 else { closeLocked(.toolLimit); return }
        guard let name = object["name"] as? String, name.utf8.count <= 512,
              let arguments = object["arguments"] as? String, arguments.utf8.count <= 64 * 1_024 else {
            closeLocked(.invalidEvent); return
        }
        calls.insert(id)
        emit(.functionCall(.init(callID: id, name: name, arguments: arguments)))
    }

    private func discardQueuedAudioLocked() {
        for item in outbound where item.audioBytes > 0 { outboundBytes -= item.data.count; audioBytes -= item.audioBytes }
        outbound.removeAll { $0.audioBytes > 0 }
    }

    private func emit(_ event: Event) {
        if case .dropped = continuation.yield(event) { closeLocked(.eventOverflow) }
    }

    private func scheduleDeadlineLocked(at deadline: TimeInterval) {
        timeoutWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.closed else { return }
            if !self.ready { self.closeLocked(.connectionTimeout); return }
            guard let reason = self.gate.expire(at: ProcessInfo.processInfo.systemUptime) else { return }
            switch reason {
            case .noSpeech: self.closeLocked(.noSpeechTimeout)
            case .utterance: self.closeLocked(.utteranceTimeout)
            case .response: self.closeLocked(.responseTimeout)
            }
        }
        timeoutWork = work
        queue.asyncAfter(deadline: .now() + max(0, deadline - ProcessInfo.processInfo.systemUptime), execute: work)
    }

    private func closeLocked(_ failure: Failure?) {
        guard !closed else { return }
        closed = true
        gate.close()
        timeoutWork?.cancel()
        socket?.cancel(with: .normalClosure, reason: nil)
        urlSession?.invalidateAndCancel()
        urlSession = nil
        socket = nil
        receiveTask?.cancel()
        receiveTask = nil
        outbound.removeAll()
        outboundBytes = 0
        audioBytes = 0
        let result = connecting
        connecting = nil
        result?.resume(throwing: failure ?? Failure.closed)
        if let failure { continuation.yield(.error(failure)) }
        continuation.finish()
    }

    private func onQueue(_ action: @escaping () -> Void) async {
        await withCheckedContinuation { result in queue.async { action(); result.resume() } }
    }
    private func onQueueThrowing(_ action: @escaping () throws -> Void) async throws {
        try await withCheckedThrowingContinuation { (result: CheckedContinuation<Void, Error>) in
            queue.async {
                do { try action(); result.resume() }
                catch { result.resume(throwing: error) }
            }
        }
    }
}

extension RealtimeConversationSession: URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
        queue.async { self.closeLocked(.connectionFailed) }
    }
}
