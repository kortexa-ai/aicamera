import AICameraCore
import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

struct AudioPipelineError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct AudioUtterance: Sendable {
    let wavData: Data
    /// Monotonic time when this fixed ASR window finished capture.
    let endedAtUptime: TimeInterval
}

final class AudioPipelineController {
    private struct PendingSpeechIngress {
        let speechID: UUID
        let data: Data
        let completion: @Sendable (Bool) -> Void
    }

    typealias UtteranceHandler = @Sendable (AudioUtterance) -> Void
    typealias BargeInHandler = @Sendable () -> Void
    typealias ErrorHandler = @Sendable (String) -> Void

    private let configuration: CaptureConfiguration
    private let utteranceSeconds: Double
    private let transcriptionEnabled: Bool
    private let onUtterance: UtteranceHandler
    private let onBargeIn: BargeInHandler
    private let onError: ErrorHandler

    private let captureEngine = AVAudioEngine()
    private let outputEngine = AVAudioEngine()
    private let microphonePlayer = AVAudioPlayerNode()
    private let speechPlayer = AVAudioPlayerNode()
    private let processingQueue = DispatchQueue(label: "ai.kortexa.aicamera.audio-processing", qos: .userInitiated)
    /// At most two copied hardware buffers may wait off the real-time callback.
    private let processingSlots = DispatchSemaphore(value: 2)

    private var microphoneConverter: AVAudioConverter?
    private var asrConverter: AVAudioConverter?
    private var asrPCM = Data()
    private var lastBargeIn = Date.distantPast
    private var pendingMicrophoneBuffers = 0
    private var pendingSpeechBuffers = 0
    private var speechPCMStaging = Data()
    private var speechPCMStreamSampleRate: Int?
    private var speechPCMStreamFinishing = false
    private var activeSpeechID: UUID?
    private var pendingSpeechIngress: PendingSpeechIngress?
    private var speechPlaybackCompletion: (@Sendable (Bool) -> Void)?
    private var speechPlaybackGeneration: UInt64 = 0
    private var graphConfigured = false
    private var tapInstalled = false
    /// Access only on processingQueue.
    private var processingActive = false
    private var started = false

    private lazy var mixFormat: AVAudioFormat = {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: configuration.audioSampleRate,
            channels: 2,
            interleaved: false
        )!
    }()
    private let asrFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!

    init(
        configuration: CaptureConfiguration,
        utteranceSeconds: Double,
        transcriptionEnabled: Bool,
        onUtterance: @escaping UtteranceHandler,
        onBargeIn: @escaping BargeInHandler,
        onError: @escaping ErrorHandler
    ) {
        self.configuration = configuration
        self.utteranceSeconds = min(30, max(0.5, utteranceSeconds.isFinite ? utteranceSeconds : 3))
        self.transcriptionEnabled = transcriptionEnabled
        self.onUtterance = onUtterance
        self.onBargeIn = onBargeIn
        self.onError = onError
    }

    func start() throws {
        guard !started else { return }
        started = true
        do {
            guard let outputUID = configuration.virtualAudioOutputDeviceID else {
                throw AudioPipelineError(message: "Select a mixed audio destination in Settings.")
            }
            guard let outputDeviceID = DeviceDiscovery.audioDeviceID(
                forUID: outputUID,
                requiringScope: kAudioDevicePropertyScopeOutput
            ), DeviceDiscovery.isDuplexVirtualAudioDevice(outputDeviceID) else {
                throw AudioPipelineError(message: "Mixed audio destination '\(outputUID)' is not an available duplex virtual device. Install the AI Camera audio driver or select another loopback device.")
            }

            if !graphConfigured {
                outputEngine.attach(microphonePlayer)
                outputEngine.attach(speechPlayer)
                outputEngine.connect(microphonePlayer, to: outputEngine.mainMixerNode, format: mixFormat)
                outputEngine.connect(speechPlayer, to: outputEngine.mainMixerNode, format: mixFormat)
                graphConfigured = true
            }
            microphonePlayer.volume = Float(configuration.microphoneGain)
            speechPlayer.volume = Float(configuration.speechGain)
            try setCurrentDevice(outputDeviceID, on: outputEngine.outputNode)
            outputEngine.prepare()
            try outputEngine.start()
            microphonePlayer.play()
            speechPlayer.play()

            let inputNode = captureEngine.inputNode
            if let inputUID = configuration.audioDeviceID {
                guard let inputDeviceID = DeviceDiscovery.audioDeviceID(
                    forUID: inputUID,
                    requiringScope: kAudioDevicePropertyScopeInput
                ) else {
                    throw AudioPipelineError(message: "The configured microphone is not available. Select another microphone or Automatic.")
                }
                try setCurrentDevice(inputDeviceID, on: inputNode)
            }
            let selectedInputDeviceID = try currentDevice(on: inputNode)
            guard selectedInputDeviceID != outputDeviceID else {
                throw AudioPipelineError(message: "The microphone and mixed output cannot be the same device. Select a hardware microphone to prevent an audio loop.")
            }
            let inputFormat = inputNode.outputFormat(forBus: 0)
            guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
                throw AudioPipelineError(message: "The selected microphone has no usable input format.")
            }
            microphoneConverter = AVAudioConverter(from: inputFormat, to: mixFormat)
            asrConverter = transcriptionEnabled ? AVAudioConverter(from: mixFormat, to: asrFormat) : nil
            captureEngine.mainMixerNode.outputVolume = 0
            inputNode.installTap(onBus: 0, bufferSize: 1_024, format: inputFormat) { [weak self] buffer, _ in
                guard let self,
                      self.processingSlots.wait(timeout: .now()) == .success else { return }
                guard let copy = Self.copy(buffer) else {
                    self.processingSlots.signal()
                    return
                }
                self.processingQueue.async {
                    defer { self.processingSlots.signal() }
                    self.processMicrophone(copy)
                }
            }
            tapInstalled = true
            captureEngine.prepare()
            try captureEngine.start()
            processingQueue.sync { processingActive = true }
        } catch {
            tearDown()
            started = false
            throw error
        }
    }

    func stop() {
        guard started else { return }
        started = false
        tearDown()
    }

    private func tearDown() {
        if tapInstalled {
            captureEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        processingQueue.sync {
            processingActive = false
            asrPCM.removeAll(keepingCapacity: false)
            microphoneConverter = nil
            asrConverter = nil
            pendingMicrophoneBuffers = 0
            pendingSpeechBuffers = 0
            speechPCMStaging.removeAll(keepingCapacity: false)
            speechPCMStreamSampleRate = nil
            speechPCMStreamFinishing = false
            activeSpeechID = nil
            let ingressCompletion = pendingSpeechIngress?.completion
            pendingSpeechIngress = nil
            let playbackCompletion = speechPlaybackCompletion
            speechPlaybackCompletion = nil
            ingressCompletion?(false)
            playbackCompletion?(false)
            speechPlaybackGeneration &+= 1
        }
        captureEngine.stop()
        microphonePlayer.stop()
        speechPlayer.stop()
        outputEngine.stop()
    }

    func handleSpeech(
        _ event: SpeechPlaybackEvent,
        completion: @escaping @Sendable (Bool) -> Void
    ) {
        processingQueue.async { [weak self] in
            guard let self, self.processingActive else {
                completion(false)
                return
            }
            let accepted: Bool
            switch event {
            case let .wav(speechID, data):
                do {
                    self.resetSpeechPlayback(stopPlayer: true)
                    self.activeSpeechID = speechID
                    let decoded = try WAVFile.decodePCM16(data)
                    try self.scheduleSpeech(decoded)
                    // Keep the producing conversation active through the audible tail. A reset or
                    // barge-in completes this with false; the final player callback completes true.
                    self.speechPlaybackCompletion = completion
                } catch {
                    self.resetSpeechPlayback(stopPlayer: true)
                    self.onError("Speech playback: \(error.localizedDescription)")
                    completion(false)
                }
                return

            case let .beginPCM(speechID, sampleRate, channels):
                guard (8_000...192_000).contains(sampleRate), channels == 1 else {
                    self.onError("Speech playback: unsupported streaming PCM format.")
                    completion(false)
                    return
                }
                self.resetSpeechPlayback(stopPlayer: true)
                self.activeSpeechID = speechID
                self.speechPCMStreamSampleRate = sampleRate
                accepted = true

            case let .pcm(speechID, data):
                guard self.activeSpeechID == speechID,
                      let sampleRate = self.speechPCMStreamSampleRate,
                      !self.speechPCMStreamFinishing else {
                    completion(false)
                    return
                }
                let targetBytes = max(2, (sampleRate / 4) * MemoryLayout<Int16>.size)
                let maximumQueuedBytes = targetBytes * 4
                guard data.count <= maximumQueuedBytes else {
                    self.resetSpeechPlayback(stopPlayer: true)
                    self.onError("Speech playback: one PCM chunk exceeded the one-second ingress limit.")
                    completion(false)
                    return
                }
                let estimatedQueuedBytes = self.pendingSpeechBuffers * targetBytes
                    + self.speechPCMStaging.count
                guard estimatedQueuedBytes <= maximumQueuedBytes - data.count else {
                    // Hold exactly one upstream chunk and resume its awaited handler only after
                    // player completions create capacity. This applies backpressure without
                    // retaining an unbounded DispatchQueue of Data closures.
                    guard self.pendingSpeechIngress == nil else {
                        self.resetSpeechPlayback(stopPlayer: true)
                        self.onError("Speech playback: multiple pending PCM chunks were rejected.")
                        completion(false)
                        return
                    }
                    self.pendingSpeechIngress = PendingSpeechIngress(
                        speechID: speechID,
                        data: data,
                        completion: completion
                    )
                    return
                }
                self.speechPCMStaging.append(data)
                accepted = self.drainSpeechPCM()

            case let .finishPCM(speechID):
                guard self.activeSpeechID == speechID,
                      self.speechPCMStreamSampleRate != nil else {
                    completion(false)
                    return
                }
                self.speechPCMStreamFinishing = true
                self.speechPlaybackCompletion = completion
                if !self.drainSpeechPCM(), self.speechPlaybackCompletion != nil {
                    self.resetSpeechPlayback(stopPlayer: true)
                }
                return

            case let .stop(speechID):
                if let speechID, self.activeSpeechID != speechID {
                    accepted = false
                } else {
                    self.resetSpeechPlayback(stopPlayer: true)
                    accepted = true
                }
            }
            completion(accepted)
        }
    }

    @discardableResult
    private func drainSpeechPCM() -> Bool {
        guard let sampleRate = speechPCMStreamSampleRate else { return false }
        let bytesPerFrame = MemoryLayout<Int16>.size
        let targetBytes = max(bytesPerFrame, (sampleRate / 4) * bytesPerFrame)
        while pendingSpeechBuffers < 4 {
            let availableAligned = speechPCMStaging.count - (speechPCMStaging.count % bytesPerFrame)
            let bytesToSchedule: Int
            if availableAligned >= targetBytes {
                bytesToSchedule = targetBytes
            } else if speechPCMStreamFinishing, availableAligned > 0 {
                bytesToSchedule = availableAligned
            } else {
                break
            }
            let samples = Data(speechPCMStaging.prefix(bytesToSchedule))
            speechPCMStaging.removeFirst(bytesToSchedule)
            do {
                try scheduleSpeech(
                    PCM16Audio(samples: samples, sampleRate: sampleRate, channels: 1),
                    resetStream: false
                )
            } catch {
                resetSpeechPlayback(stopPlayer: true)
                onError("Speech playback: \(error.localizedDescription)")
                return false
            }
        }
        if speechPCMStreamFinishing, pendingSpeechBuffers == 0 {
            guard speechPCMStaging.isEmpty else {
                resetSpeechPlayback(stopPlayer: true)
                onError("Speech playback: streaming PCM ended with an incomplete sample.")
                return false
            }
            speechPCMStreamSampleRate = nil
            speechPCMStreamFinishing = false
            activeSpeechID = nil
            let completion = speechPlaybackCompletion
            speechPlaybackCompletion = nil
            completion?(true)
        }
        return true
    }

    private func admitPendingSpeechIngressIfPossible() {
        guard let ingress = pendingSpeechIngress,
              ingress.speechID == activeSpeechID,
              let sampleRate = speechPCMStreamSampleRate,
              !speechPCMStreamFinishing else { return }
        let targetBytes = max(2, (sampleRate / 4) * MemoryLayout<Int16>.size)
        let maximumQueuedBytes = targetBytes * 4
        let estimatedQueuedBytes = pendingSpeechBuffers * targetBytes + speechPCMStaging.count
        guard estimatedQueuedBytes <= maximumQueuedBytes - ingress.data.count else { return }

        pendingSpeechIngress = nil
        speechPCMStaging.append(ingress.data)
        let accepted = drainSpeechPCM()
        ingress.completion(accepted)
    }

    private func scheduleSpeech(_ decoded: PCM16Audio, resetStream: Bool = true) throws {
        guard decoded.channels > 0,
              !decoded.samples.isEmpty,
              decoded.samples.count % (MemoryLayout<Int16>.size * decoded.channels) == 0,
              let native = Self.audioBuffer(from: decoded),
              let converter = AVAudioConverter(from: native.format, to: mixFormat),
              let mixed = Self.convert(native, using: converter, to: mixFormat) else {
            throw AudioPipelineError(message: "The speech response has an unsupported audio format.")
        }
        guard pendingSpeechBuffers < 4 else {
            throw AudioPipelineError(message: "Speech output is busy; a stale response was dropped.")
        }
        if resetStream {
            speechPCMStaging.removeAll(keepingCapacity: true)
            speechPCMStreamSampleRate = nil
            speechPCMStreamFinishing = false
        }
        pendingSpeechBuffers += 1
        let generation = speechPlaybackGeneration
        speechPlayer.scheduleBuffer(mixed, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            self?.processingQueue.async { [weak self] in
                guard let self, generation == self.speechPlaybackGeneration else { return }
                self.pendingSpeechBuffers = max(0, self.pendingSpeechBuffers - 1)
                if self.speechPCMStreamSampleRate != nil {
                    self.drainSpeechPCM()
                    self.admitPendingSpeechIngressIfPossible()
                } else if self.pendingSpeechBuffers == 0 {
                    self.activeSpeechID = nil
                    let completion = self.speechPlaybackCompletion
                    self.speechPlaybackCompletion = nil
                    completion?(true)
                }
            }
        }
        if !speechPlayer.isPlaying { speechPlayer.play() }
    }

    private func resetSpeechPlayback(stopPlayer: Bool) {
        speechPlaybackGeneration &+= 1
        if stopPlayer { speechPlayer.stop() }
        pendingSpeechBuffers = 0
        speechPCMStaging.removeAll(keepingCapacity: true)
        speechPCMStreamSampleRate = nil
        speechPCMStreamFinishing = false
        activeSpeechID = nil
        let ingressCompletion = pendingSpeechIngress?.completion
        pendingSpeechIngress = nil
        let playbackCompletion = speechPlaybackCompletion
        speechPlaybackCompletion = nil
        ingressCompletion?(false)
        playbackCompletion?(false)
    }

    private func processMicrophone(_ input: AVAudioPCMBuffer) {
        guard processingActive,
              let microphoneConverter,
              let mixed = Self.convert(input, using: microphoneConverter, to: mixFormat) else { return }
        if pendingMicrophoneBuffers < 8 {
            pendingMicrophoneBuffers += 1
            microphonePlayer.scheduleBuffer(
                mixed,
                completionCallbackType: .dataPlayedBack
            ) { [weak self] _ in
                self?.processingQueue.async { [weak self] in
                    guard let self else { return }
                    self.pendingMicrophoneBuffers = max(0, self.pendingMicrophoneBuffers - 1)
                }
            }
            if !microphonePlayer.isPlaying { microphonePlayer.play() }
        }

        var peak: Float = 0
        if let channels = mixed.floatChannelData {
            let frameCount = Int(mixed.frameLength)
            for channel in 0..<Int(mixed.format.channelCount) {
                for index in 0..<frameCount {
                    peak = max(peak, abs(channels[channel][index]))
                }
            }
        }
        if pendingSpeechBuffers > 0,
           peak > 0.035,
           Date().timeIntervalSince(lastBargeIn) > 0.5 {
            lastBargeIn = Date()
            onBargeIn()
        }

        guard transcriptionEnabled,
              let asrConverter,
              let asrBuffer = Self.convert(mixed, using: asrConverter, to: asrFormat),
              let samples = asrBuffer.floatChannelData?[0] else { return }
        let count = Int(asrBuffer.frameLength)
        guard count > 0 else { return }
        var pcm = [Int16](repeating: 0, count: count)
        for index in 0..<count {
            let value = max(-1, min(1, samples[index]))
            pcm[index] = Int16(value * Float(Int16.max))
        }
        pcm.withUnsafeBytes { asrPCM.append(contentsOf: $0) }

        let segmentBytes = Int(16_000 * utteranceSeconds) * MemoryLayout<Int16>.size
        while asrPCM.count >= segmentBytes {
            let segment = Data(asrPCM.prefix(segmentBytes))
            asrPCM.removeFirst(segmentBytes)
            let hasSpeech = segment.withUnsafeBytes { bytes -> Bool in
                let samples = bytes.bindMemory(to: Int16.self)
                return samples.contains { abs(Int($0)) > 900 }
            }
            if hasSpeech {
                onUtterance(
                    AudioUtterance(
                        wavData: WAVFile.encodePCM16(samples: segment, sampleRate: 16_000, channels: 1),
                        endedAtUptime: ProcessInfo.processInfo.systemUptime
                    )
                )
            }
        }
        // Never retain more than two windows if an unexpected converter burst occurs.
        if asrPCM.count > segmentBytes * 2 {
            asrPCM = Data(asrPCM.suffix(segmentBytes))
        }
    }

    private func currentDevice(on node: AVAudioIONode) throws -> AudioDeviceID {
        guard let audioUnit = node.audioUnit else {
            throw AudioPipelineError(message: "Audio I/O unit is unavailable.")
        }
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitGetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            &size
        )
        guard status == noErr else {
            throw AudioPipelineError(message: "Core Audio could not read the selected device (OSStatus \(status)).")
        }
        return deviceID
    }

    private func setCurrentDevice(_ deviceID: AudioDeviceID, on node: AVAudioIONode) throws {
        guard let audioUnit = node.audioUnit else {
            throw AudioPipelineError(message: "Audio I/O unit is unavailable.")
        }
        var mutableID = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &mutableID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            throw AudioPipelineError(message: "Core Audio could not select device \(deviceID) (OSStatus \(status)).")
        }
    }

    private static func copy(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let destination = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: source.frameLength) else { return nil }
        destination.frameLength = source.frameLength
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: source.audioBufferList))
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(destination.mutableAudioBufferList)
        guard sourceBuffers.count == destinationBuffers.count else { return nil }
        for index in 0..<sourceBuffers.count {
            guard let sourceData = sourceBuffers[index].mData,
                  let destinationData = destinationBuffers[index].mData else { continue }
            let bytes = min(Int(sourceBuffers[index].mDataByteSize), Int(destinationBuffers[index].mDataByteSize))
            memcpy(destinationData, sourceData, bytes)
            destinationBuffers[index].mDataByteSize = UInt32(bytes)
        }
        return destination
    }

    private static func convert(
        _ input: AVAudioPCMBuffer,
        using converter: AVAudioConverter,
        to outputFormat: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let ratio = outputFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * ratio) + 32)
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return nil }
        var provided = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if provided {
                inputStatus.pointee = .noDataNow
                return nil
            }
            provided = true
            inputStatus.pointee = .haveData
            return input
        }
        guard conversionError == nil, status != .error else { return nil }
        return output.frameLength > 0 ? output : nil
    }

    private static func audioBuffer(from decoded: PCM16Audio) -> AVAudioPCMBuffer? {
        guard decoded.channels > 0,
              let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Double(decoded.sampleRate),
                channels: AVAudioChannelCount(decoded.channels),
                interleaved: false
              ) else { return nil }
        let frameCount = decoded.samples.count / (MemoryLayout<Int16>.size * decoded.channels)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)),
              let channels = buffer.floatChannelData else { return nil }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        decoded.samples.withUnsafeBytes { bytes in
            let samples = bytes.bindMemory(to: Int16.self)
            for frame in 0..<frameCount {
                for channel in 0..<decoded.channels {
                    channels[channel][frame] = Float(samples[frame * decoded.channels + channel]) / Float(Int16.max)
                }
            }
        }
        return buffer
    }
}
