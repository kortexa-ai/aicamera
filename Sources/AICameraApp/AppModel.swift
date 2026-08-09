import AICameraCore
import AppKit
import AudioToolbox
import AVFoundation
import Combine
import Foundation

// The producer relinquishes the preview after invoking its callback; only the main actor uses it.
private struct SendableImage: @unchecked Sendable {
    let value: NSImage
}

private final class PipelineRunGate: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true

    var isActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return active
    }

    func cancel() {
        lock.lock(); active = false; lock.unlock()
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var isStopping = false
    @Published private(set) var statusText = "Stopped"
    @Published private(set) var previewImage: NSImage?
    @Published private(set) var lastError: String?
    @Published private(set) var currentSnapshot = SceneSnapshot()
    @Published private(set) var videoDevices: [MediaDevice] = []
    @Published private(set) var audioInputDevices: [MediaDevice] = []
    @Published private(set) var audioOutputDevices: [AudioOutputDevice] = []

    let configurationController = ConfigurationController()
    let cameraExtensionManager = CameraExtensionManager()
    let audioDriverManager = AudioDriverManager()

    private var pipeline: PipelineCoordinator?
    private var videoController: VideoPipelineController?
    private var audioController: AudioPipelineController?
    private var runGate: PipelineRunGate?
    private var startTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var managerCancellables = Set<AnyCancellable>()

    var deviceOperationInProgress: Bool {
        isStopping || cameraExtensionManager.hasPendingRequest || audioDriverManager.status.isBusy
    }

    init() {
        cameraExtensionManager.objectWillChange
            .merge(with: audioDriverManager.objectWillChange)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &managerCancellables)
        refreshDevicesAndDrivers()
    }

    func refreshDevicesAndDrivers() {
        videoDevices = DeviceDiscovery.videoInputs(excluding: AICameraVirtualCamera.deviceUID)
        audioInputDevices = DeviceDiscovery.audioInputs()
        audioOutputDevices = DeviceDiscovery.audioOutputs()
        cameraExtensionManager.refresh()
        audioDriverManager.refresh()
    }

    func start() {
        guard !isRunning, startTask == nil, stopTask == nil else { return }
        guard configurationController.validationMessage == nil else {
            lastError = "Repair and save the profile before starting the proxy."
            statusText = "Invalid profile"
            return
        }
        statusText = "Requesting permissions…"
        lastError = nil
        startTask = Task { [weak self] in
            guard let self else { return }
            let cameraAllowed = await Self.requestAccess(for: .video)
            guard !Task.isCancelled else { self.startTask = nil; return }
            guard cameraAllowed else {
                self.lastError = "Camera access was denied. Enable AI Camera in System Settings → Privacy & Security → Camera."
                self.statusText = "Permission denied"
                self.startTask = nil
                return
            }
            let microphoneAllowed = await Self.requestAccess(for: .audio)
            guard !Task.isCancelled else { self.startTask = nil; return }
            self.startProxy(microphoneAllowed: microphoneAllowed)
            self.startTask = nil
        }
    }

    func stop() {
        beginStop()
    }

    func activateCameraExtension() {
        runAfterStop { [weak self] in self?.cameraExtensionManager.activate() }
    }

    func deactivateCameraExtension() {
        runAfterStop { [weak self] in self?.cameraExtensionManager.deactivate() }
    }

    func installAudioDriver() {
        runAfterStop { [weak self] in self?.audioDriverManager.install() }
    }

    func uninstallAudioDriver() {
        runAfterStop { [weak self] in self?.audioDriverManager.uninstall() }
    }

    private func runAfterStop(_ action: @escaping @MainActor () -> Void) {
        guard stopTask == nil, !cameraExtensionManager.hasPendingRequest,
              !audioDriverManager.status.isBusy else {
            lastError = "Wait for the current device operation to finish."
            return
        }
        if isRunning || startTask != nil || pipeline != nil {
            beginStop(after: action)
        } else {
            action()
        }
    }

    private func beginStop(after completion: (@MainActor () -> Void)? = nil) {
        guard stopTask == nil else { return }
        startTask?.cancel()
        startTask = nil
        runGate?.cancel()
        runGate = nil

        let coordinator = pipeline
        let video = videoController
        let audio = audioController
        pipeline = nil
        isRunning = false
        isStopping = true
        statusText = "Stopping…"

        // Cancel actor-owned inference tasks before tearing down capture. The synchronous run gate
        // above prevents capture callbacks from queuing new work while this await is pending.
        stopTask = Task { [weak self] in
            // Stop capture/playback before CMIO teardown. The run gate intentionally rejects the
            // coordinator's stop event, and a failed camera stop must not leave speech audible.
            audio?.stop()
            if let coordinator { await coordinator.stop() }
            let videoStopStatus = video?.stop() ?? noErr
            guard let self else {
                if videoStopStatus == noErr { completion?() }
                return
            }
            if self.audioController === audio { self.audioController = nil }
            self.previewImage = nil
            self.isStopping = false
            self.stopTask = nil

            guard videoStopStatus == noErr else {
                // Keep the controller so Stop can retry the CMIO teardown. Do not continue into a
                // requested install/remove action while the feeder may still own the stream.
                self.videoController = video
                self.isRunning = true
                self.statusText = "Stop failed"
                self.lastError = "Virtual camera stop failed with status \(videoStopStatus). Select Stop Proxy to retry."
                return
            }

            if self.videoController === video { self.videoController = nil }
            self.isRunning = false
            self.statusText = "Stopped"
            completion?()
        }
    }

    private func startProxy(microphoneAllowed: Bool) {
        let configuration = configurationController.configuration
        do {
            try ConfigurationValidator.validate(configuration)
        } catch {
            lastError = error.localizedDescription
            statusText = "Invalid profile"
            return
        }

        let gate = PipelineRunGate()
        let coordinator = PipelineCoordinator(
            configuration: configuration,
            secrets: AppSecretResolver(),
            onSnapshot: { [weak self] snapshot in
                guard gate.isActive else { return }
                Task { @MainActor [weak model = self] in
                    guard gate.isActive else { return }
                    model?.currentSnapshot = snapshot
                    model?.videoController?.update(snapshot: snapshot)
                }
            },
            onSpeech: { [weak self] event in
                guard gate.isActive else { return false }
                return await withCheckedContinuation { continuation in
                    Task { @MainActor [weak model = self] in
                        guard gate.isActive, let audio = model?.audioController else {
                            continuation.resume(returning: false)
                            return
                        }
                        audio.handleSpeech(event) { accepted in
                            continuation.resume(returning: accepted)
                        }
                    }
                }
            },
            onError: { [weak self] message in
                guard gate.isActive else { return }
                Task { @MainActor [weak model = self] in
                    guard gate.isActive else { return }
                    model?.lastError = message
                }
            }
        )
        let video = VideoPipelineController(
            configuration: configuration,
            onPreview: { [weak self] image in
                guard gate.isActive else { return }
                let sendableImage = SendableImage(value: image)
                Task { @MainActor [weak model = self, sendableImage] in
                    guard gate.isActive else { return }
                    model?.previewImage = sendableImage.value
                }
            },
            onGestures: { observations, frameID in
                guard gate.isActive else { return }
                Task {
                    guard gate.isActive else { return }
                    await coordinator.submit(gestures: observations, frameID: frameID)
                }
            },
            onFrame: { packet in
                guard gate.isActive else { return }
                Task {
                    guard gate.isActive else { return }
                    await coordinator.submit(frame: packet)
                }
            },
            onError: { [weak self] message in
                guard gate.isActive else { return }
                Task { @MainActor [weak model = self] in
                    guard gate.isActive else { return }
                    model?.lastError = message
                }
            }
        )

        do {
            try video.start()
        } catch {
            gate.cancel()
            let stopStatus = video.stop()
            if stopStatus == noErr {
                lastError = error.localizedDescription
                statusText = "Video failed"
            } else {
                videoController = video
                isRunning = true
                lastError = "\(error.localizedDescription) Camera cleanup also failed with status \(stopStatus); select Stop Proxy to retry."
                statusText = "Stop failed"
            }
            return
        }

        var audio: AudioPipelineController?
        if microphoneAllowed {
            let controller = AudioPipelineController(
                configuration: configuration.capture,
                utteranceSeconds: configuration.pipeline.conversation.utteranceSeconds,
                transcriptionEnabled: configuration.pipeline.conversation.enabled
                    && configuration.pipeline.conversation.transcriptionEnabled
                    && configuration.pipeline.conversation.transcriptionEndpointID != nil,
                onUtterance: { utterance in
                    guard gate.isActive else { return }
                    Task {
                        guard gate.isActive else { return }
                        await coordinator.submit(utterance: utterance)
                    }
                },
                onBargeIn: {
                    guard gate.isActive else { return }
                    Task {
                        guard gate.isActive else { return }
                        _ = await coordinator.bargeIn()
                    }
                },
                onError: { [weak self] message in
                    guard gate.isActive else { return }
                    Task { @MainActor [weak self] in
                        guard gate.isActive else { return }
                        self?.lastError = message
                    }
                }
            )
            do {
                try controller.start()
                audio = controller
            } catch {
                lastError = "Audio proxy is unavailable: \(error.localizedDescription)"
            }
        } else {
            lastError = "Microphone access was denied. Video is running without the audio proxy."
        }

        pipeline = coordinator
        runGate = gate
        videoController = video
        audioController = audio
        isRunning = true
        switch (video.isFeedingVirtualCamera, audio != nil) {
        case (true, true): statusText = "Camera and audio proxy live"
        case (true, false): statusText = "Camera proxy only"
        case (false, true): statusText = "Audio proxy only; video preview live"
        case (false, false): statusText = "Preview only"
        }
        Task {
            guard gate.isActive else { return }
            await coordinator.started()
        }
    }

    private static func requestAccess(for mediaType: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: mediaType) {
        case .authorized:
            return true
        case .denied, .restricted:
            return false
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: mediaType) { granted in
                    continuation.resume(returning: granted)
                }
            }
        @unknown default:
            return false
        }
    }
}
