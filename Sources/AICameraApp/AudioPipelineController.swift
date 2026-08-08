import AICameraCore
import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

struct AudioPipelineError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

final class AudioPipelineController {
    typealias UtteranceHandler = @Sendable (Data) -> Void
    typealias BargeInHandler = @Sendable () -> Void
    typealias ErrorHandler = @Sendable (String) -> Void

    private let configuration: CaptureConfiguration
    private let utteranceSeconds: Double
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
        onUtterance: @escaping UtteranceHandler,
        onBargeIn: @escaping BargeInHandler,
        onError: @escaping ErrorHandler
    ) {
        self.configuration = configuration
        self.utteranceSeconds = min(30, max(0.5, utteranceSeconds.isFinite ? utteranceSeconds : 3))
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
                throw AudioPipelineError(message: "Mixed audio destination '\(outputUID)' is not an available duplex virtual device. Install AI Camera Audio or select another loopback device.")
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
            asrConverter = AVAudioConverter(from: mixFormat, to: asrFormat)
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
        }
        captureEngine.stop()
        microphonePlayer.stop()
        speechPlayer.stop()
        outputEngine.stop()
    }

    func playSpeech(wavData: Data) {
        processingQueue.async { [weak self] in
            guard let self, self.processingActive else { return }
            do {
                let decoded = try WAVFile.decodePCM16(wavData)
                guard let native = Self.audioBuffer(from: decoded),
                      let converter = AVAudioConverter(from: native.format, to: self.mixFormat),
                      let mixed = Self.convert(native, using: converter, to: self.mixFormat) else {
                    throw AudioPipelineError(message: "The speech response has an unsupported audio format.")
                }
                // Do not let repeated responses create an unbounded player-node queue.
                guard self.pendingSpeechBuffers < 4 else {
                    self.onError("Speech output is busy; a stale response was dropped.")
                    return
                }
                if !self.speechPlayer.isPlaying { self.speechPlayer.play() }
                self.pendingSpeechBuffers += 1
                self.speechPlayer.scheduleBuffer(
                    mixed,
                    completionCallbackType: .dataPlayedBack
                ) { [weak self] _ in
                    self?.processingQueue.async { [weak self] in
                        guard let self else { return }
                        self.pendingSpeechBuffers = max(0, self.pendingSpeechBuffers - 1)
                    }
                }
            } catch {
                self.onError("Speech playback: \(error.localizedDescription)")
            }
        }
    }

    func stopSpeech() {
        processingQueue.async { [weak self] in
            guard let self else { return }
            self.speechPlayer.stop()
            self.pendingSpeechBuffers = 0
            if self.processingActive { self.speechPlayer.play() }
        }
    }

    private func processMicrophone(_ input: AVAudioPCMBuffer) {
        guard processingActive,
              let microphoneConverter,
              let mixed = Self.convert(input, using: microphoneConverter, to: mixFormat) else { return }
        if pendingMicrophoneBuffers < 8 {
            if !microphonePlayer.isPlaying { microphonePlayer.play() }
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
        }

        guard let asrConverter,
              let asrBuffer = Self.convert(mixed, using: asrConverter, to: asrFormat),
              let samples = asrBuffer.floatChannelData?[0] else { return }
        let count = Int(asrBuffer.frameLength)
        guard count > 0 else { return }
        var peak: Float = 0
        var pcm = [Int16](repeating: 0, count: count)
        for index in 0..<count {
            let value = max(-1, min(1, samples[index]))
            peak = max(peak, abs(value))
            pcm[index] = Int16(value * Float(Int16.max))
        }
        pcm.withUnsafeBytes { asrPCM.append(contentsOf: $0) }

        if pendingSpeechBuffers > 0,
           peak > 0.035,
           Date().timeIntervalSince(lastBargeIn) > 0.5 {
            lastBargeIn = Date()
            onBargeIn()
        }

        let segmentBytes = Int(16_000 * utteranceSeconds) * MemoryLayout<Int16>.size
        while asrPCM.count >= segmentBytes {
            let segment = Data(asrPCM.prefix(segmentBytes))
            asrPCM.removeFirst(segmentBytes)
            let hasSpeech = segment.withUnsafeBytes { bytes -> Bool in
                let samples = bytes.bindMemory(to: Int16.self)
                return samples.contains { abs(Int($0)) > 900 }
            }
            if hasSpeech {
                onUtterance(WAVFile.encodePCM16(samples: segment, sampleRate: 16_000, channels: 1))
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
