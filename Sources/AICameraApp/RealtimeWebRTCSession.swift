import AVFoundation
import Foundation
import LiveKitWebRTC

/// A bounded, one-call OpenAI Realtime WebRTC transport.
///
/// All WebRTC and data-channel state is owned by a private serial queue. Media is
/// never persisted. The local audio track starts disabled and is the microphone
/// privacy gate.
public final class RealtimeWebRTCSession: NSObject, @unchecked Sendable {
    public struct HeaderCredential: Sendable {
        public let field: String
        public let value: String

        public init(field: String = "Authorization", value: String) {
            self.field = field
            self.value = value
        }
    }

    public struct FunctionCall: Sendable, Equatable {
        public let callID: String
        public let name: String
        public let arguments: String
    }

    public enum TranscriptSource: Sendable {
        case local
        case remote
    }

    public enum Failure: String, Error, Sendable {
        case alreadyStarted
        case closed
        case invalidURL
        case invalidCredential
        case invalidSession
        case sessionTooLarge
        case peerConnectionCreation
        case audioTransceiverCreation
        case dataChannelCreation
        case offerCreation
        case localDescription
        case iceTimeout
        case signalingTransport
        case signalingRedirect
        case signalingStatus
        case signalingContentType
        case signalingResponseTooLarge
        case invalidAnswer
        case remoteDescription
        case connectionTimeout
        case connectionFailed
        case channelClosed
        case outboundEventTooLarge
        case outboundEncoding
        case outboundSend
        case invalidFunctionOutput
        case serverError
    }

    public struct PCMChunk: Sendable {
        public let data: Data
        public let sampleRate: Int
        public let channels: Int
    }

    public enum Event: Sendable {
        case connected
        case speechStarted
        case speechStopped
        case transcript(source: TranscriptSource, text: String, isFinal: Bool)
        case functionCall(FunctionCall)
        case responseDone
        case error(Failure)
        case audio(PCMChunk)
    }

    private enum Limit {
        static let credentialFieldBytes = 128
        static let credentialValueBytes = 16 * 1024
        static let sessionBytes = 128 * 1024
        static let sdpBytes = 1 * 1024 * 1024
        static let signalingResponseBytes = 1 * 1024 * 1024
        static let inboundEventBytes = 256 * 1024
        static let outboundEventBytes = 128 * 1024
        static let textBytes = 16 * 1024
        static let functionArgumentsBytes = 64 * 1024
        static let functionOutputBytes = 64 * 1024
        static let pcmBytes = 1 * 1024 * 1024
        static let pcmFrames: AVAudioFrameCount = 96_000
        static let iceSeconds: TimeInterval = 20
        static let connectionSeconds: TimeInterval = 45
        static let requestSeconds: TimeInterval = 30
    }

    public let events: AsyncStream<Event>

    private let signalingURL: URL
    private let credential: HeaderCredential
    private let stateQueue = DispatchQueue(label: "ai.kortexa.aicamera.realtime-webrtc")
    private let eventContinuation: AsyncStream<Event>.Continuation

    private var factory: LKRTCPeerConnectionFactory?
    private var peer: LKRTCPeerConnection?
    private var dataChannel: LKRTCDataChannel?
    private var localAudioTrack: LKRTCAudioTrack?
    private var remoteAudioTracks: [ObjectIdentifier: LKRTCAudioTrack] = [:]
    private var requestSession: URLSession?
    private var requestTask: URLSessionDataTask?
    private var pendingSessionData: Data?
    private var connectContinuation: CheckedContinuation<Void, Error>?
    private var timeoutWork: DispatchWorkItem?
    private var generation: UInt64 = 0
    private var started = false
    private var closed = false
    private var microphoneArmed = false
    private var connectedEmitted = false
    private var completedCallIDs = Set<String>()

    public init(signalingURL: URL, credential: HeaderCredential) {
        self.signalingURL = signalingURL
        self.credential = credential
        var continuation: AsyncStream<Event>.Continuation!
        self.events = AsyncStream(bufferingPolicy: .bufferingNewest(256)) { continuation = $0 }
        self.eventContinuation = continuation
        super.init()
    }

    deinit {
        // The privacy gate closes before any transport object is released.
        localAudioTrack?.isEnabled = false
        dataChannel?.delegate = nil
        peer?.delegate = nil
        peer?.close()
        requestTask?.cancel()
        requestSession?.invalidateAndCancel()
        eventContinuation.finish()
    }

    /// Creates the offer, waits for complete ICE gathering, signals it, and waits
    /// for the ordered `oai-events` channel to open.
    public func connect(session: [String: Any]) async throws {
        let sessionData: Data
        do {
            guard JSONSerialization.isValidJSONObject(session) else { throw Failure.invalidSession }
            sessionData = try JSONSerialization.data(withJSONObject: session)
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.invalidSession
        }
        guard sessionData.count <= Limit.sessionBytes else { throw Failure.sessionTooLarge }
        try validateInputs()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            stateQueue.async { [weak self] in
                guard let self else { continuation.resume(throwing: Failure.closed); return }
                guard !self.closed else { continuation.resume(throwing: Failure.closed); return }
                guard !self.started else { continuation.resume(throwing: Failure.alreadyStarted); return }
                self.started = true
                self.generation &+= 1
                self.connectContinuation = continuation
                self.begin(sessionData: sessionData, generation: self.generation)
            }
        }
    }

    /// Opens the microphone gate for one utterance. The gate closes on the next
    /// server `input_audio_buffer.speech_stopped` event.
    public func armOneShotAudio() async throws {
        try await onStateQueue {
            guard !self.closed else { throw Failure.closed }
            guard self.dataChannel?.readyState == .open, let track = self.localAudioTrack else {
                throw Failure.channelClosed
            }
            self.microphoneArmed = true
            track.isEnabled = true
        }
    }

    /// Closes the microphone privacy gate without closing the session.
    public func closeMicrophoneGate() async {
        await onStateQueueNoThrow { self.closeGateLocked() }
    }

    /// Sends a bounded `function_call_output`, then asks the model to continue.
    /// Both messages use the single serialized data-channel send path.
    public func completeFunctionCall(
        callID: String,
        output: String,
        continuation response: [String: Any] = [:]
    ) async throws {
        guard callID.utf8.count <= 512, !callID.isEmpty,
              output.utf8.count <= Limit.functionOutputBytes,
              JSONSerialization.isValidJSONObject(response) else {
            throw Failure.invalidFunctionOutput
        }
        try await onStateQueue {
            try self.sendJSONLocked([
                "type": "conversation.item.create",
                "item": ["type": "function_call_output", "call_id": callID, "output": output]
            ])
            try self.sendJSONLocked(["type": "response.create", "response": response])
        }
    }

    /// Requests another response without returning a tool result.
    public func requestContinuation(_ response: [String: Any] = [:]) async throws {
        guard JSONSerialization.isValidJSONObject(response) else { throw Failure.invalidSession }
        try await onStateQueue { try self.sendJSONLocked(["type": "response.create", "response": response]) }
    }

    /// Idempotently closes the microphone gate, network request, channel, and peer.
    public func close() async {
        await onStateQueueNoThrow { self.closeLocked(report: nil) }
    }

    private func validateInputs() throws {
        guard let scheme = signalingURL.scheme?.lowercased(),
              let host = signalingURL.host?.lowercased(),
              (scheme == "https" || (scheme == "http" && Self.isLoopback(host))),
              signalingURL.user == nil, signalingURL.password == nil,
              signalingURL.query == nil, signalingURL.fragment == nil else {
            throw Failure.invalidURL
        }
        let fieldBytes = credential.field.utf8.count
        let valueBytes = credential.value.utf8.count
        guard fieldBytes > 0, fieldBytes <= Limit.credentialFieldBytes,
              valueBytes > 0, valueBytes <= Limit.credentialValueBytes,
              !credential.field.contains("\r"), !credential.field.contains("\n"),
              !credential.value.contains("\r"), !credential.value.contains("\n") else {
            throw Failure.invalidCredential
        }
    }

    private func begin(sessionData: Data, generation: UInt64) {
        initializeWebRTCOnce()
        let factory = LKRTCPeerConnectionFactory()
        self.factory = factory

        // Manual rendering suppresses normal playout in this LiveKit build while
        // RTCAudioRenderer sinks continue to receive decoded PCM. A nonzero result
        // means the API declined it; renderer delivery remains enabled.
        _ = factory.audioDeviceModule.setManualRenderingMode(true)

        let configuration = LKRTCConfiguration()
        configuration.sdpSemantics = .unifiedPlan
        configuration.continualGatheringPolicy = .gatherOnce
        let constraints = LKRTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: ["DtlsSrtpKeyAgreement": "true"]
        )
        guard let peer = factory.peerConnection(with: configuration, constraints: constraints, delegate: self) else {
            failLocked(.peerConnectionCreation); return
        }
        self.peer = peer

        let source = factory.audioSource(with: nil)
        let track = factory.audioTrack(with: source, trackId: "aicamera-microphone")
        track.isEnabled = false
        localAudioTrack = track
        let transceiverConfiguration = LKRTCRtpTransceiverInit()
        transceiverConfiguration.direction = .sendRecv
        guard peer.addTransceiver(with: track, init: transceiverConfiguration) != nil else {
            failLocked(.audioTransceiverCreation); return
        }

        let channelConfiguration = LKRTCDataChannelConfiguration()
        channelConfiguration.isOrdered = true
        guard let channel = peer.dataChannel(forLabel: "oai-events", configuration: channelConfiguration) else {
            failLocked(.dataChannelCreation); return
        }
        dataChannel = channel
        channel.delegate = self

        pendingSessionData = sessionData
        scheduleTimeout(seconds: Limit.connectionSeconds, generation: generation, failure: .connectionTimeout)
        let offerConstraints = LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        peer.offer(for: offerConstraints) { [weak self] offer, error in
            self?.stateQueue.async {
                guard let self, self.isCurrent(generation) else { return }
                guard error == nil, let offer else { self.failLocked(.offerCreation); return }
                peer.setLocalDescription(offer) { [weak self] error in
                    self?.stateQueue.async {
                        guard let self, self.isCurrent(generation) else { return }
                        guard error == nil else { self.failLocked(.localDescription); return }
                        self.scheduleTimeout(seconds: Limit.iceSeconds, generation: generation, failure: .iceTimeout)
                        if peer.iceGatheringState == .complete {
                            self.pendingSessionData = nil
                            self.postOfferLocked(sessionData: sessionData, generation: generation)
                        }
                    }
                }
            }
        }
    }

    private func postOfferLocked(sessionData: Data, generation: UInt64) {
        guard isCurrent(generation), requestTask == nil,
              let sdp = peer?.localDescription?.sdp,
              let sdpData = sdp.data(using: .utf8), sdpData.count <= Limit.sdpBytes else {
            failLocked(.invalidAnswer); return
        }
        timeoutWork?.cancel()
        scheduleTimeout(seconds: Limit.connectionSeconds, generation: generation, failure: .connectionTimeout)

        let boundary = "AICameraBoundary-" + UUID().uuidString
        var body = Data()
        func append(_ text: String) { body.append(Data(text.utf8)) }
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"sdp\"\r\n\r\n")
        body.append(sdpData)
        append("\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"session\"\r\n\r\n")
        body.append(sessionData)
        append("\r\n--\(boundary)--\r\n")

        var request = URLRequest(url: signalingURL)
        request.httpMethod = "POST"
        request.timeoutInterval = Limit.requestSeconds
        request.setValue(credential.value, forHTTPHeaderField: credential.field)
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("text/plain, application/sdp", forHTTPHeaderField: "Accept")
        request.httpBody = body

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = Limit.requestSeconds
        configuration.timeoutIntervalForResource = Limit.requestSeconds
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        requestSession = session
        let task = session.dataTask(with: request) { [weak self] data, response, error in
            self?.stateQueue.async {
                guard let self, self.isCurrent(generation) else { return }
                self.requestTask = nil
                self.requestSession?.finishTasksAndInvalidate()
                self.requestSession = nil
                guard error == nil, let http = response as? HTTPURLResponse, let data else {
                    self.failLocked(.signalingTransport); return
                }
                guard http.statusCode == 200 || http.statusCode == 201 else {
                    self.failLocked(.signalingStatus); return
                }
                let mediaType = (http.value(forHTTPHeaderField: "Content-Type") ?? "")
                    .split(separator: ";", maxSplits: 1).first?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard mediaType == "text/plain" || mediaType == "application/sdp" else {
                    self.failLocked(.signalingContentType); return
                }
                guard data.count <= Limit.signalingResponseBytes,
                      let answerSDP = String(data: data, encoding: .utf8),
                      answerSDP.utf8.count <= Limit.sdpBytes,
                      answerSDP.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("v=") else {
                    self.failLocked(data.count > Limit.signalingResponseBytes ? .signalingResponseTooLarge : .invalidAnswer)
                    return
                }
                let answer = LKRTCSessionDescription(type: .answer, sdp: answerSDP)
                self.peer?.setRemoteDescription(answer) { [weak self] error in
                    self?.stateQueue.async {
                        guard let self, self.isCurrent(generation) else { return }
                        if error != nil { self.failLocked(.remoteDescription) }
                        else { self.attachKnownRemoteTracksLocked() }
                    }
                }
            }
        }
        requestTask = task
        task.resume()
    }

    private func scheduleTimeout(seconds: TimeInterval, generation: UInt64, failure: Failure) {
        timeoutWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isCurrent(generation) else { return }
            self.failLocked(failure)
        }
        timeoutWork = work
        stateQueue.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func isCurrent(_ expectedGeneration: UInt64) -> Bool {
        !closed && generation == expectedGeneration
    }

    private func closeGateLocked() {
        microphoneArmed = false
        localAudioTrack?.isEnabled = false
    }

    private func closeLocked(report failure: Failure?) {
        guard !closed else { return }
        closeGateLocked()
        closed = true
        generation &+= 1
        timeoutWork?.cancel()
        timeoutWork = nil
        requestTask?.cancel()
        requestTask = nil
        requestSession?.invalidateAndCancel()
        requestSession = nil
        dataChannel?.delegate = nil
        dataChannel?.close()
        dataChannel = nil
        for track in remoteAudioTracks.values { track.remove(self) }
        remoteAudioTracks.removeAll()
        peer?.delegate = nil
        peer?.close()
        peer = nil
        factory = nil
        if let continuation = connectContinuation {
            connectContinuation = nil
            continuation.resume(throwing: failure ?? Failure.closed)
        }
        if let failure { eventContinuation.yield(.error(failure)) }
        eventContinuation.finish()
    }

    private func failLocked(_ failure: Failure) {
        closeLocked(report: failure)
    }

    private func sendJSONLocked(_ object: [String: Any]) throws {
        guard !closed, let dataChannel, dataChannel.readyState == .open else { throw Failure.channelClosed }
        let data: Data
        do { data = try JSONSerialization.data(withJSONObject: object) }
        catch { throw Failure.outboundEncoding }
        guard data.count <= Limit.outboundEventBytes else { throw Failure.outboundEventTooLarge }
        guard dataChannel.sendData(LKRTCDataBuffer(data: data, isBinary: false)) else { throw Failure.outboundSend }
    }

    private func handleEventLocked(_ data: Data) {
        guard !closed, data.count <= Limit.inboundEventBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String, type.utf8.count <= 256 else { return }

        switch type {
        case "input_audio_buffer.speech_started":
            eventContinuation.yield(.speechStarted)
        case "input_audio_buffer.speech_stopped":
            closeGateLocked()
            eventContinuation.yield(.speechStopped)
        case "conversation.item.input_audio_transcription.delta":
            yieldTranscript(object["delta"], source: .local, final: false)
        case "conversation.item.input_audio_transcription.completed":
            yieldTranscript(object["transcript"], source: .local, final: true)
        case "response.audio_transcript.delta", "response.output_audio_transcript.delta":
            yieldTranscript(object["delta"], source: .remote, final: false)
        case "response.audio_transcript.done", "response.output_audio_transcript.done":
            yieldTranscript(object["transcript"], source: .remote, final: true)
        case "response.function_call_arguments.done":
            yieldFunctionCall(object)
        case "response.output_item.done":
            if let item = object["item"] as? [String: Any], item["type"] as? String == "function_call" {
                yieldFunctionCall(item)
            }
        case "response.done":
            eventContinuation.yield(.responseDone)
        case "error":
            failLocked(.serverError)
        default:
            break
        }
    }

    private func yieldTranscript(_ value: Any?, source: TranscriptSource, final: Bool) {
        guard let text = value as? String, !text.isEmpty else { return }
        eventContinuation.yield(.transcript(source: source, text: bounded(text, bytes: Limit.textBytes), isFinal: final))
    }

    private func yieldFunctionCall(_ object: [String: Any]) {
        guard let callID = object["call_id"] as? String, !callID.isEmpty, callID.utf8.count <= 512,
              !completedCallIDs.contains(callID) else { return }
        let name = bounded((object["name"] as? String) ?? "", bytes: 512)
        let arguments = bounded((object["arguments"] as? String) ?? "", bytes: Limit.functionArgumentsBytes)
        completedCallIDs.insert(callID)
        eventContinuation.yield(.functionCall(FunctionCall(callID: callID, name: name, arguments: arguments)))
    }

    private func bounded(_ string: String, bytes: Int) -> String {
        guard string.utf8.count > bytes else { return string }
        var end = string.startIndex
        var count = 0
        while end < string.endIndex {
            let next = string.index(after: end)
            let width = string[end..<next].utf8.count
            if count + width > bytes { break }
            count += width
            end = next
        }
        return String(string[..<end])
    }

    private func attachKnownRemoteTracksLocked() {
        guard let peer else { return }
        for receiver in peer.receivers { attachRemoteTrackLocked(receiver.track) }
        for transceiver in peer.transceivers { attachRemoteTrackLocked(transceiver.receiver.track) }
    }

    private func attachRemoteTrackLocked(_ mediaTrack: LKRTCMediaStreamTrack?) {
        guard let track = mediaTrack as? LKRTCAudioTrack,
              track !== localAudioTrack else { return }
        let identifier = ObjectIdentifier(track)
        guard remoteAudioTracks[identifier] == nil else { return }
        remoteAudioTracks[identifier] = track
        track.add(self)
    }

    private func removeRemoteTrackLocked(_ mediaTrack: LKRTCMediaStreamTrack?) {
        guard let track = mediaTrack as? LKRTCAudioTrack else { return }
        let identifier = ObjectIdentifier(track)
        if let retained = remoteAudioTracks.removeValue(forKey: identifier) { retained.remove(self) }
    }

    private func copyPCM16(_ source: AVAudioPCMBuffer) -> PCMChunk? {
        let frames = source.frameLength
        guard frames > 0, frames <= Limit.pcmFrames,
              source.format.sampleRate.isFinite,
              (8_000...192_000).contains(source.format.sampleRate),
              let targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: source.format.sampleRate,
                channels: 1,
                interleaved: true
              ),
              let converter = AVAudioConverter(from: source.format, to: targetFormat),
              let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frames) else { return nil }
        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            guard !supplied else {
                inputStatus.pointee = .endOfStream
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return source
        }
        guard conversionError == nil,
              status != .error,
              output.frameLength > 0,
              let buffer = UnsafeMutableAudioBufferListPointer(output.mutableAudioBufferList).first,
              let bytes = buffer.mData else { return nil }
        let byteCount = Int(buffer.mDataByteSize)
        guard byteCount > 0, byteCount <= Limit.pcmBytes else { return nil }
        return PCMChunk(
            data: Data(bytes: bytes, count: byteCount),
            sampleRate: Int(targetFormat.sampleRate.rounded()),
            channels: 1
        )
    }

    private func onStateQueue<T>(_ operation: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            stateQueue.async {
                do { continuation.resume(returning: try operation()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func onStateQueueNoThrow(_ operation: @escaping () -> Void) async {
        await withCheckedContinuation { continuation in
            stateQueue.async { operation(); continuation.resume() }
        }
    }

    private static func isLoopback(_ host: String) -> Bool {
        host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    private static let initializationLock = NSLock()
    private static var didInitializeWebRTC = false
    private func initializeWebRTCOnce() {
        Self.initializationLock.lock()
        defer { Self.initializationLock.unlock() }
        if !Self.didInitializeWebRTC {
            LKRTCInitializeSSL()
            Self.didInitializeWebRTC = true
        }
    }
}

extension RealtimeWebRTCSession: LKRTCDataChannelDelegate {
    public func dataChannelDidChangeState(_ dataChannel: LKRTCDataChannel) {
        stateQueue.async { [weak self] in
            guard let self, !self.closed, dataChannel === self.dataChannel else { return }
            switch dataChannel.readyState {
            case .open:
                guard !self.connectedEmitted else { return }
                self.connectedEmitted = true
                self.timeoutWork?.cancel()
                self.timeoutWork = nil
                self.eventContinuation.yield(.connected)
                if let continuation = self.connectContinuation {
                    self.connectContinuation = nil
                    continuation.resume()
                }
            case .closing, .closed:
                if !self.closed { self.failLocked(.channelClosed) }
            default:
                break
            }
        }
    }

    public func dataChannel(_ dataChannel: LKRTCDataChannel, didReceiveMessageWith buffer: LKRTCDataBuffer) {
        guard !buffer.isBinary, buffer.data.count <= Limit.inboundEventBytes else { return }
        let data = buffer.data
        stateQueue.async { [weak self] in
            guard let self, !self.closed, dataChannel === self.dataChannel else { return }
            self.handleEventLocked(data)
        }
    }
}

extension RealtimeWebRTCSession: LKRTCPeerConnectionDelegate {
    public func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange stateChanged: LKRTCSignalingState) {}
    public func peerConnection(_ peerConnection: LKRTCPeerConnection, didAdd stream: LKRTCMediaStream) {
        stateQueue.async { [weak self] in
            guard let self, peerConnection === self.peer, !self.closed else { return }
            for track in stream.audioTracks { self.attachRemoteTrackLocked(track) }
        }
    }
    public func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove stream: LKRTCMediaStream) {
        stateQueue.async { [weak self] in
            guard let self, peerConnection === self.peer else { return }
            for track in stream.audioTracks { self.removeRemoteTrackLocked(track) }
        }
    }
    public func peerConnectionShouldNegotiate(_ peerConnection: LKRTCPeerConnection) {}
    public func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCIceConnectionState) {
        guard newState == .failed || newState == .disconnected else { return }
        stateQueue.async { [weak self] in
            guard let self, peerConnection === self.peer, !self.closed else { return }
            self.failLocked(.connectionFailed)
        }
    }
    public func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCIceGatheringState) {
        guard newState == .complete else { return }
        stateQueue.async { [weak self] in
            guard let self, peerConnection === self.peer, self.isCurrent(self.generation),
                  self.requestTask == nil, let sessionData = self.pendingSessionData else { return }
            self.pendingSessionData = nil
            self.postOfferLocked(sessionData: sessionData, generation: self.generation)
        }
    }
    public func peerConnection(_ peerConnection: LKRTCPeerConnection, didGenerate candidate: LKRTCIceCandidate) {}
    public func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove candidates: [LKRTCIceCandidate]) {}
    public func peerConnection(_ peerConnection: LKRTCPeerConnection, didOpen dataChannel: LKRTCDataChannel) {}

    public func peerConnection(_ peerConnection: LKRTCPeerConnection, didStartReceivingOn transceiver: LKRTCRtpTransceiver) {
        stateQueue.async { [weak self] in
            guard let self, peerConnection === self.peer, !self.closed else { return }
            self.attachRemoteTrackLocked(transceiver.receiver.track)
        }
    }

    public func peerConnection(_ peerConnection: LKRTCPeerConnection, didAdd rtpReceiver: LKRTCRtpReceiver, streams mediaStreams: [LKRTCMediaStream]) {
        stateQueue.async { [weak self] in
            guard let self, peerConnection === self.peer, !self.closed else { return }
            self.attachRemoteTrackLocked(rtpReceiver.track)
        }
    }

    public func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove rtpReceiver: LKRTCRtpReceiver) {
        stateQueue.async { [weak self] in
            guard let self, peerConnection === self.peer else { return }
            self.removeRemoteTrackLocked(rtpReceiver.track)
        }
    }
}

extension RealtimeWebRTCSession: LKRTCAudioRenderer {
    public func render(pcmBuffer: AVAudioPCMBuffer) {
        guard let chunk = copyPCM16(pcmBuffer) else { return }
        stateQueue.async { [weak self] in
            guard let self, !self.closed else { return }
            self.eventContinuation.yield(.audio(chunk))
        }
    }
}

extension RealtimeWebRTCSession: URLSessionTaskDelegate {
    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
        stateQueue.async { [weak self] in
            guard let self, task === self.requestTask, !self.closed else { return }
            self.failLocked(.signalingRedirect)
        }
    }
}
