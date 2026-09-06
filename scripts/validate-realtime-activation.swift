import AICameraCore
import Foundation

// Actual WebSocket session with an in-memory socket. No network or credentials are used.
private struct Failure: Error { let message: String }
private func require(_ value: Bool, _ message: String) throws {
    if !value { throw Failure(message: message) }
}
private final class Socket: RealtimeWebSocket, @unchecked Sendable {
    private let incoming = AsyncThrowingStream<URLSessionWebSocketTask.Message, Error>.makeStream()
    private let lock = NSLock()
    private var sent: [String] = []
    var automaticallyReady = true
    func resume() { emit(["type": "session.created"]) }
    func receive() async throws -> URLSessionWebSocketTask.Message {
        for try await message in incoming.stream { return message }
        throw Failure(message: "Socket closed")
    }
    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        guard case let .string(text) = message,
              let data = text.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { throw Failure(message: "Malformed send") }
        record(type)
        if type == "session.update", automaticallyReady { emit(["type": "session.updated"]) }
    }
    private func record(_ type: String) { lock.lock(); sent.append(type); lock.unlock() }
    func count(_ type: String) -> Int { lock.lock(); defer { lock.unlock() }; return sent.filter { $0 == type }.count }
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) { incoming.continuation.finish() }
    func emit(_ object: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: object)
        incoming.continuation.yield(.string(String(decoding: data, as: UTF8.self)))
    }
}
private final class Events: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    func record(_ event: RealtimeSessionEvent) {
        let name: String
        switch event {
        case .connected: name = "connected"
        case .speechStarted: name = "speechStarted"
        case .speechStopped: name = "speechStopped"
        case .responseDone: name = "done"
        case .audio: name = "audio"
        case .functionCall: name = "tool"
        case .transcript: name = "transcript"
        case .error: name = "error"
        }
        lock.lock(); counts[name, default: 0] += 1; lock.unlock()
    }
    func count(_ name: String) -> Int { lock.lock(); defer { lock.unlock() }; return counts[name, default: 0] }
}
@main
private struct RealtimeActivationValidation {
    static func main() async throws {
        try await turns()
        try await agentInputPause()
        try await cancelledConnection()
        print("Passed Realtime activation: unarmed/stale PCM denial, same-session turns, playback boundary, tool continuation, late/duplicate events, cancellation")
    }
    private static func session(_ socket: Socket) -> RealtimeConversationSession {
        RealtimeConversationSession(signalingURL: URL(string: "https://api.openai.com/v1/realtime")!,
            credential: .init(value: "Bearer synthetic-fixture"), socketFactory: { _ in socket })
    }
    private static func turns() async throws {
        let socket = Socket(), events = Events()
        let active = session(socket)
        let consumer = Task { for await event in active.events { events.record(event) } }
        try await active.connect(session: ["model": "synthetic-fixture"])
        active.appendInputPCM(Data(count: 4_800), capturedAt: ProcessInfo.processInfo.systemUptime)
        try await Task.sleep(for: .milliseconds(20))
        try require(socket.count("input_audio_buffer.append") == 0, "Unarmed audio escaped")
        try await active.armConversationAudio()
        active.appendInputPCM(Data(count: 4_800), capturedAt: ProcessInfo.processInfo.systemUptime - 1)
        try await Task.sleep(for: .milliseconds(20))
        try require(socket.count("input_audio_buffer.append") == 0, "Pre-arm audio escaped")
        let firstCapture = ProcessInfo.processInfo.systemUptime
        active.appendInputPCM(Data(count: 4_800), capturedAt: firstCapture)
        try await wait { socket.count("input_audio_buffer.append") == 1 }
        socket.emit(["type": "input_audio_buffer.speech_started"])
        socket.emit(["type": "input_audio_buffer.speech_stopped"])
        try await wait { events.count("speechStopped") == 1 }
        active.appendInputPCM(Data(count: 4_800), capturedAt: ProcessInfo.processInfo.systemUptime)
        socket.emit(audio)
        socket.emit(done)
        try await wait { events.count("done") == 1 }
        socket.emit(audio)
        socket.emit(done)
        socket.emit(["type": "response.function_call_arguments.done", "call_id": "late", "name": "clear_overlay", "arguments": "{}"])
        try await Task.sleep(for: .milliseconds(20))
        try require(socket.count("input_audio_buffer.append") == 1, "Audio escaped while responding")
        try require(events.count("audio") == 1 && events.count("done") == 1 && events.count("tool") == 0, "Late/duplicate response events escaped")
        try await active.armConversationAudio()
        active.appendInputPCM(Data(count: 4_800), capturedAt: firstCapture)
        try await Task.sleep(for: .milliseconds(20))
        try require(socket.count("input_audio_buffer.append") == 1, "Old-turn audio entered next turn")
        active.appendInputPCM(Data(count: 4_800), capturedAt: ProcessInfo.processInfo.systemUptime)
        try await wait { socket.count("input_audio_buffer.append") == 2 }
        try require(socket.count("session.update") == 1 && socket.count("input_audio_buffer.clear") == 2,
                    "Next turn reconnected or retained old input")
        socket.emit(["type": "input_audio_buffer.speech_started"])
        socket.emit(["type": "input_audio_buffer.speech_stopped"])
        socket.emit(["type": "response.function_call_arguments.done", "call_id": "call-fixture", "name": "clear_overlay", "arguments": "{}"])
        socket.emit(done)
        try await wait { events.count("done") == 2 }
        try require(events.count("tool") == 1, "Tool call did not reach host")
        try await active.completeFunctionCall(callID: "call-fixture", output: "{}")
        try await active.requestContinuation(["tool_choice": "none"])
        socket.emit(audio)
        socket.emit(done)
        try await wait { events.count("done") == 3 }
        try require(events.count("audio") == 2, "Tool continuation audio did not play")
        await active.close()
        let previous = events.count("audio")
        socket.emit(audio)
        active.appendInputPCM(Data(count: 4_800), capturedAt: ProcessInfo.processInfo.systemUptime)
        do { try await active.armConversationAudio(); throw Failure(message: "Closed session rearmed") }
        catch RealtimeSessionFailure.closed {}
        await consumer.value
        try require(events.count("audio") == previous && events.count("error") == 0, "Closed session emitted data or unexpected error")
    }
    private static func cancelledConnection() async throws {
        let socket = Socket()
        socket.automaticallyReady = false
        let active = session(socket)
        let connecting = Task { try await active.connect(session: ["model": "synthetic-fixture"]) }
        try await wait { socket.count("session.update") == 1 }
        connecting.cancel()
        do { try await connecting.value; throw Failure(message: "Cancelled connection succeeded") }
        catch RealtimeSessionFailure.closed {}
        socket.emit(["type": "session.updated"])
        do { try await active.armConversationAudio(); throw Failure(message: "Late connect reopened input") }
        catch RealtimeSessionFailure.closed {}
        await active.close()
    }
    private static func agentInputPause() async throws {
        let socket = Socket(), events = Events()
        let active = session(socket)
        let consumer = Task { for await event in active.events { events.record(event) } }
        try await active.connect(session: ["model": "synthetic-fixture"])
        try await active.armConversationAudio()
        let firstCapture = ProcessInfo.processInfo.systemUptime
        active.appendInputPCM(Data(count: 4_800), capturedAt: firstCapture)
        try await wait { socket.count("input_audio_buffer.append") == 1 }
        try await active.pauseInputAudio()
        active.appendInputPCM(Data(count: 4_800), capturedAt: ProcessInfo.processInfo.systemUptime)
        socket.emit(["type": "input_audio_buffer.speech_started"])
        socket.emit(["type": "input_audio_buffer.speech_stopped"])
        socket.emit(audio)
        socket.emit(done)
        try await Task.sleep(for: .milliseconds(30))
        try require(socket.count("input_audio_buffer.append") == 1 && events.count("audio") == 0,
                    "Paused input or a retired utterance escaped")
        try await active.armConversationAudio()
        active.appendInputPCM(Data(count: 4_800), capturedAt: firstCapture)
        active.appendInputPCM(Data(count: 4_800), capturedAt: ProcessInfo.processInfo.systemUptime)
        try await wait { socket.count("input_audio_buffer.append") == 2 }
        socket.emit(["type": "input_audio_buffer.speech_started"])
        socket.emit(["type": "input_audio_buffer.speech_stopped"])
        try await wait { events.count("speechStopped") == 1 }
        try await active.pauseInputAudio()
        active.appendInputPCM(Data(count: 4_800), capturedAt: ProcessInfo.processInfo.systemUptime)
        socket.emit(["type": "response.function_call_arguments.done", "call_id": "working", "name": "clear_overlay", "arguments": "{}"])
        socket.emit(audio)
        socket.emit(done)
        try await wait { events.count("done") == 1 }
        try require(events.count("tool") == 1 && events.count("audio") == 1,
                    "Agent input pause interrupted the current answer or tools")
        try await active.completeFunctionCall(callID: "working", output: "{}")
        try await active.requestContinuation(["tool_choice": "none"])
        socket.emit(audio)
        socket.emit(done)
        try await wait { events.count("done") == 2 }
        try require(socket.count("input_audio_buffer.append") == 2 && events.count("audio") == 2,
                    "Tool continuation reopened input or lost the answer")
        await active.close()
        await consumer.value
        try require(events.count("error") == 0, "Pause/resume unexpectedly failed the session")
    }
    private static var audio: [String: Any] { ["type": "response.output_audio.delta", "delta": Data([0, 0, 1, 0]).base64EncodedString()] }
    private static var done: [String: Any] { ["type": "response.done", "response": ["status": "completed"]] }
    private static func wait(_ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while !condition() {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw Failure(message: "Fixture timed out") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
