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

final class AudioPipelineController: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    /// The buffer is freshly allocated in the capture callback, then transferred once to
    /// processingQueue and never mutated elsewhere.
    private struct CapturedAudioBuffer: @unchecked Sendable {
        let value: AVAudioPCMBuffer
    }

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

    private let captureSession = AVCaptureSession()
    private let captureOutput = AVCaptureAudioDataOutput()
    /// Owns capture-session configuration and start/stop lifecycle.
    private let captureControlQueue = DispatchQueue(
        label: "ai.kortexa.aicamera.audio-capture-control",
        qos: .userInitiated
    )
    /// Receives only bounded AVCapture sample callbacks.
    private let captureCallbackQueue = DispatchQueue(
        label: "ai.kortexa.aicamera.audio-capture-callback",
        qos: .userInteractive
    )
    private let outputEngine = AVAudioEngine()
    private let microphonePlayer = AVAudioPlayerNode()
    private let speechPlayer = AVAudioPlayerNode()
    private let processingQueue = DispatchQueue(label: "ai.kortexa.aicamera.audio-processing", qos: .userInitiated)
    /// At most two copied hardware buffers may wait beyond the AVCapture callback.
    private let processingSlots = DispatchSemaphore(value: 2)

    private var microphoneConverter: AVAudioConverter?
    private var asrConverter: AVAudioConverter?
    private var realtimeConverter: AVAudioConverter?
    private var realtimeAudioHandler: (@Sendable (Data, TimeInterval) -> Void)?
    private let realtimeFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false)!
    private var asrPCM = Data()
    private var lastBargeIn = Date.distantPast
    /// Access only on processingQueue. Fast attack and bounded exponential decay.
    private var smoothedInputLevel: Float = 0
    /// Snapshot lock is used only by processingQueue and UI polling, never by the capture callback.
    private let inputLevelLock = NSLock()
    private var latestInputLevel: Float = 0
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
    private var publishToVirtualMicrophone = false
    private var speechOutputEnabled = false
    /// The controller has immutable configuration and AppModel discards it after stop.
    private var captureConfigured = false
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
        super.init()
    }

    func start(publishToVirtualMicrophone: Bool = true) throws {
        try captureControlQueue.sync {
            try startLocked(publishToVirtualMicrophone: publishToVirtualMicrophone)
        }
    }

    private func startLocked(publishToVirtualMicrophone: Bool) throws {
        guard !started else { return }
        started = true
        do {
            var outputDeviceID: AudioDeviceID?
            if publishToVirtualMicrophone {
                let outputUID = configuration.virtualAudioOutputDeviceID ?? AICameraAudioDevice.uid
                guard let resolvedOutputDeviceID = DeviceDiscovery.audioDeviceID(
                    forUID: outputUID,
                    requiringScope: kAudioDevicePropertyScopeOutput
                ), DeviceDiscovery.isDuplexVirtualAudioDevice(resolvedOutputDeviceID) else {
                    throw AudioPipelineError(message: "Configured audio destination '\(outputUID)' is not available. Install or update the AI Camera microphone.")
                }
                outputDeviceID = resolvedOutputDeviceID

                try configureSpeechOutput(deviceID: resolvedOutputDeviceID, includeMicrophone: true)
            }

            let selectedInputDeviceID: AudioDeviceID
            let selectedInputUID: String
            if let inputUID = configuration.audioDeviceID {
                guard let inputDeviceID = DeviceDiscovery.physicalAudioInputDeviceID(
                    forUID: inputUID
                ) else {
                    throw AudioPipelineError(message: "The configured microphone is not available. Select another microphone or System Default.")
                }
                selectedInputDeviceID = inputDeviceID
                selectedInputUID = inputUID
            } else {
                let resolution = DeviceDiscovery.resolveDefaultAudioInput(
                    excludingUID: AICameraAudioDevice.uid
                )
                guard let inputDeviceID = resolution.deviceID,
                      let inputUID = resolution.device?.id else {
                    throw AudioPipelineError(message: "No hardware microphone is available.")
                }
                selectedInputDeviceID = inputDeviceID
                selectedInputUID = inputUID
            }
            if let outputDeviceID, selectedInputDeviceID == outputDeviceID {
                throw AudioPipelineError(message: "The microphone and mixed output cannot be the same device. Select a hardware microphone to prevent an audio loop.")
            }
            guard let captureDevice = DeviceDiscovery.audioCaptureDevice(forUID: selectedInputUID) else {
                throw AudioPipelineError(message: "The selected microphone is not available to AVFoundation.")
            }
            try configureCaptureSession(device: captureDevice)
            processingQueue.sync {
                microphoneConverter = nil
                asrConverter = transcriptionEnabled
                    ? AVAudioConverter(from: mixFormat, to: asrFormat)
                    : nil
                self.publishToVirtualMicrophone = publishToVirtualMicrophone
                processingActive = true
            }
            captureSession.startRunning()
            guard captureSession.isRunning else {
                throw AudioPipelineError(message: "The physical microphone capture could not start.")
            }
        } catch {
            tearDownLocked()
            started = false
            throw error
        }
    }

    /// Local Talk replies go to the selected system output, without microphone monitoring.
    /// Ordinary microphone testing does not start an output engine.
    func enableLocalSpeechPlayback() throws {
        try captureControlQueue.sync {
            guard started else { throw AudioPipelineError(message: "Start the microphone first.") }
            if outputEngine.isRunning { return }
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var deviceID = AudioDeviceID(kAudioObjectUnknown)
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID) == noErr,
                  deviceID != kAudioObjectUnknown,
                  !DeviceDiscovery.isDuplexVirtualAudioDevice(deviceID) else {
                throw AudioPipelineError(message: "Choose speakers or headphones as the macOS sound output for Talk.")
            }
            try configureSpeechOutput(deviceID: deviceID, includeMicrophone: false)
        }
    }

    func setRealtimeAudioHandler(_ handler: (@Sendable (Data, TimeInterval) -> Void)?) {
        processingQueue.async { [weak self] in
            guard let self else { return }
            self.realtimeAudioHandler = handler
            self.realtimeConverter = handler == nil ? nil : AVAudioConverter(from: self.mixFormat, to: self.realtimeFormat)
            // A partial batch must never carry Realtime audio into a later ASR request.
            self.asrPCM.removeAll(keepingCapacity: true)
            self.asrConverter = handler == nil && self.transcriptionEnabled
                ? AVAudioConverter(from: self.mixFormat, to: self.asrFormat) : nil
        }
    }

    func disableLocalSpeechPlayback() {
        captureControlQueue.sync {
            let isLocalOutput = processingQueue.sync { !publishToVirtualMicrophone && speechOutputEnabled }
            guard isLocalOutput else { return }
            processingQueue.sync {
                speechOutputEnabled = false
                resetSpeechPlayback(stopPlayer: true)
            }
            outputEngine.stop()
        }
    }

    private func configureSpeechOutput(deviceID: AudioDeviceID, includeMicrophone: Bool) throws {
        if !graphConfigured {
            outputEngine.attach(microphonePlayer)
            outputEngine.attach(speechPlayer)
            if includeMicrophone {
                outputEngine.connect(microphonePlayer, to: outputEngine.mainMixerNode, format: mixFormat)
            }
            outputEngine.connect(speechPlayer, to: outputEngine.mainMixerNode, format: mixFormat)
            graphConfigured = true
        }
        microphonePlayer.volume = includeMicrophone ? Float(configuration.microphoneGain) : 0
        speechPlayer.volume = Float(configuration.speechGain)
        try setCurrentDevice(deviceID, on: outputEngine.outputNode)
        outputEngine.prepare()
        do { try outputEngine.start() }
        catch { throw AudioPipelineError(message: "Speech output could not start: \(error.localizedDescription)") }
        if includeMicrophone { microphonePlayer.play() }
        speechPlayer.play()
        processingQueue.sync { speechOutputEnabled = true }
    }

    func stop() {
        captureControlQueue.sync {
            guard started else { return }
            started = false
            tearDownLocked()
        }
    }

    func inputLevelSnapshot() -> Float {
        inputLevelLock.lock()
        defer { inputLevelLock.unlock() }
        return latestInputLevel
    }

    private func storeInputLevel(_ level: Float) {
        inputLevelLock.lock()
        latestInputLevel = min(1, max(0, level.isFinite ? level : 0))
        inputLevelLock.unlock()
    }

    private func tearDownLocked() {
        captureOutput.setSampleBufferDelegate(nil, queue: nil)
        if captureSession.isRunning { captureSession.stopRunning() }
        captureCallbackQueue.sync {}
        processingQueue.sync {
            processingActive = false
            publishToVirtualMicrophone = false
            speechOutputEnabled = false
            smoothedInputLevel = 0
            storeInputLevel(0)
            asrPCM.removeAll(keepingCapacity: false)
            microphoneConverter = nil
            asrConverter = nil
            realtimeConverter = nil
            realtimeAudioHandler = nil
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
        microphonePlayer.stop()
        speechPlayer.stop()
        outputEngine.stop()
    }

    func handleSpeech(
        _ event: SpeechPlaybackEvent,
        completion: @escaping @Sendable (Bool) -> Void
    ) {
        processingQueue.async { [weak self] in
            guard let self, self.processingActive, self.speechOutputEnabled else {
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

    private func configureCaptureSession(device: AVCaptureDevice) throws {
        guard !captureConfigured else {
            captureOutput.setSampleBufferDelegate(self, queue: captureCallbackQueue)
            return
        }
        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }

        let input = try AVCaptureDeviceInput(device: device)
        guard captureSession.canAddInput(input) else {
            throw AudioPipelineError(message: "The selected microphone cannot be added to the capture session.")
        }
        captureSession.addInput(input)
        guard captureSession.canAddOutput(captureOutput) else {
            captureSession.removeInput(input)
            throw AudioPipelineError(message: "Microphone sample output is unavailable.")
        }
        captureSession.addOutput(captureOutput)
        captureOutput.setSampleBufferDelegate(self, queue: captureCallbackQueue)
        captureConfigured = true
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard processingSlots.wait(timeout: .now()) == .success else { return }
        guard let buffer = Self.audioBuffer(from: sampleBuffer) else {
            processingSlots.signal()
            return
        }
        let captured = CapturedAudioBuffer(value: buffer)
        let capturedAt = ProcessInfo.processInfo.systemUptime
        let slots = processingSlots
        processingQueue.async { [weak self, captured, slots] in
            defer { slots.signal() }
            guard let self, self.processingActive else { return }
            let buffer = captured.value
            if self.microphoneConverter?.inputFormat != buffer.format {
                self.microphoneConverter = AVAudioConverter(from: buffer.format, to: self.mixFormat)
            }
            self.processMicrophone(buffer, capturedAt: capturedAt)
        }
    }

    private func processMicrophone(_ input: AVAudioPCMBuffer, capturedAt: TimeInterval) {
        guard processingActive,
              let microphoneConverter,
              let mixed = Self.convert(input, using: microphoneConverter, to: mixFormat) else { return }
        if publishToVirtualMicrophone, pendingMicrophoneBuffers < 8 {
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
        let normalizedLevel = AudioLevelMeter.normalizedPeak(peak)
        smoothedInputLevel = normalizedLevel >= smoothedInputLevel
            ? normalizedLevel
            : max(normalizedLevel, smoothedInputLevel * 0.82)
        storeInputLevel(smoothedInputLevel)

        if pendingSpeechBuffers > 0,
           peak > 0.035,
           Date().timeIntervalSince(lastBargeIn) > 0.5 {
            lastBargeIn = Date()
            onBargeIn()
        }

        deliverRealtimePCM(mixed, capturedAt: capturedAt)

        guard realtimeAudioHandler == nil, transcriptionEnabled,
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

    private func deliverRealtimePCM(_ mixed: AVAudioPCMBuffer, capturedAt: TimeInterval) {
        guard let handler = realtimeAudioHandler, let converter = realtimeConverter,
              let buffer = Self.convert(mixed, using: converter, to: realtimeFormat),
              let samples = buffer.floatChannelData?[0], buffer.frameLength <= 12_000 else { return }
        var pcm = [Int16](repeating: 0, count: Int(buffer.frameLength))
        for index in pcm.indices {
            let sample = samples[index]
            pcm[index] = sample.isFinite ? Int16(max(-1, min(1, sample)) * Float(Int16.max)) : 0
        }
        pcm.withUnsafeBytes { handler(Data($0), capturedAt) }
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

    private static func audioBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard CMSampleBufferDataIsReady(sampleBuffer),
              let description = CMSampleBufferGetFormatDescription(sampleBuffer) else { return nil }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        guard format.streamDescription.pointee.mFormatID == kAudioFormatLinearPCM else { return nil }
        let sampleCount = CMSampleBufferGetNumSamples(sampleBuffer)
        let channelCount = Int(format.channelCount)
        let bytesPerFrame = max(1, Int(format.streamDescription.pointee.mBytesPerFrame))
        guard sampleCount > 0,
              sampleCount <= 16_384,
              format.sampleRate.isFinite,
              (8_000...384_000).contains(format.sampleRate),
              (1...32).contains(channelCount),
              bytesPerFrame <= 1_024,
              sampleCount * bytesPerFrame * channelCount <= 4 * 1_024 * 1_024,
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: format,
                  frameCapacity: AVAudioFrameCount(sampleCount)
              ) else { return nil }
        buffer.frameLength = AVAudioFrameCount(sampleCount)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(sampleCount),
            into: buffer.mutableAudioBufferList
        )
        return status == noErr ? buffer : nil
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
