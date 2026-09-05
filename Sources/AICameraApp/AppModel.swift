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

enum RealtimeConversationState: String, Sendable {
    case idle = "Ready to talk"
    case connecting = "Connecting…"
    case listening = "Listening…"
    case responding = "Responding…"
    case failed = "Realtime failed"
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
    @Published private(set) var cameraIsActive = false
    @Published private(set) var microphoneIsActive = false
    @Published private(set) var statusText = "Ready — waiting for an app"
    @Published private(set) var previewImage: NSImage?
    @Published private(set) var lastError: String?
    @Published private(set) var cameraLaneError: String?
    @Published private(set) var microphoneLaneError: String?
    @Published private(set) var currentSnapshot = SceneSnapshot()
    @Published private(set) var videoDevices: [MediaDevice] = []
    @Published private(set) var audioInputDevices: [MediaDevice] = []
    @Published private(set) var audioOutputDevices: [AudioOutputDevice] = []
    @Published private(set) var cameraSourceText = "System Default — checking…"
    @Published private(set) var microphoneSourceText = "System Default — checking…"
    @Published private(set) var cameraSourceWarning: String?
    @Published private(set) var microphoneSourceWarning: String?
    @Published private(set) var cameraSourceAvailable = false
    @Published private(set) var microphoneSourceAvailable = false
    @Published private(set) var cameraVirtualDeviceAvailable = false
    @Published private(set) var cameraTestActive = false
    @Published private(set) var microphoneTestActive = false
    @Published private(set) var microphoneInputLevel: Float = 0
    @Published var selectedSettingsPage: AICameraSettingsPage = .general
    @Published private(set) var selectedSettingsLane: AICameraSettingsLane?
    @Published private(set) var settingsNavigationGeneration: UInt64 = 0
    @Published private(set) var cameraAuthorization = AVCaptureDevice.authorizationStatus(for: .video)
    @Published private(set) var microphoneAuthorization = AVCaptureDevice.authorizationStatus(for: .audio)
    @Published private(set) var realtimeConversationState: RealtimeConversationState = .idle

    let configurationController = ConfigurationController()
    let cameraExtensionManager = CameraExtensionManager()
    let audioDriverManager = AudioDriverManager()
    let demandMonitor = MediaDemandMonitor()
    let loginItemController = LoginItemController()
    let builtinVisionModelController = BuiltinVisionModelController()
    let builtinTranslationModelController = BuiltinTranslationModelController()

    private var pipeline: PipelineCoordinator?
    private var videoController: VideoPipelineController?
    private var scriptRenderer: OverlayScriptRenderer?
    @Published private(set) var overlayScriptLog: String?
    @Published var overlayScriptDraft = ""
    /// Retained only to retry a failed feeder teardown; it is never treated as an active lane.
    private var failedVideoCleanupController: VideoPipelineController?
    private var audioController: AudioPipelineController?
    private var runGate: PipelineRunGate?
    private var cameraRunGate: PipelineRunGate?
    private var microphoneRunGate: PipelineRunGate?
    private var stopTask: Task<Void, Never>?
    private var pipelineStopTask: Task<Void, Never>?
    private var pipelineStopGeneration: UInt64 = 0
    private var pendingDemandReconcile = false
    private var cameraPermissionTask: Task<Void, Never>?
    private var microphonePermissionTask: Task<Void, Never>?
    private var cameraPermissionGeneration: UInt64 = 0
    private var microphonePermissionGeneration: UInt64 = 0
    private var managerCancellables = Set<AnyCancellable>()
    private var lifecycleCancellables = Set<AnyCancellable>()
    private var realtimeSession: (any RealtimeConversationClient)?
    private var realtimeEventTask: Task<Void, Never>?
    private var realtimeConnectTask: Task<Void, Never>?
    private var realtimeFinishTask: Task<Void, Never>?
    private var realtimeGeneration: UInt64 = 0
    private var realtimeOwnsMicrophoneTest = false
    private var realtimeSpeechID: UUID?
    private var realtimeAudioQueue: [Data] = []
    private var realtimeAudioQueueBytes = 0
    private var realtimeAudioSending = false
    private var realtimeAudioFinishRequested = false
    private var realtimeAcceptingAudio = false
    private var realtimeAudioSampleRate: Int?
    private var realtimeToolContinuationPending = false

    var currentError: String? {
        lastError ?? cameraLaneError ?? microphoneLaneError
    }

    var cameraVirtualDeviceStatusText: String {
        cameraExtensionManager.status == .active && !cameraVirtualDeviceAvailable
            ? "Active — device unavailable"
            : cameraExtensionManager.status.label
    }

    var cameraVirtualDeviceIsReady: Bool {
        cameraExtensionManager.status == .active && cameraVirtualDeviceAvailable
    }

    var deviceOperationInProgress: Bool {
        isStopping || pipelineStopTask != nil
            || cameraPermissionTask != nil || microphonePermissionTask != nil
            || cameraExtensionManager.hasPendingRequest || audioDriverManager.status.isBusy
    }

    var externalClientIsUsingMedia: Bool {
        demandMonitor.cameraRequested || demandMonitor.microphoneRequested
    }

    var canStartCameraTest: Bool {
        !externalClientIsUsingMedia && !deviceOperationInProgress
            && configurationController.isConfigurationUsable
            && cameraExtensionManager.status.isInstalled
            && cameraAuthorization == .authorized
            && cameraSourceAvailable
    }

    var canStartMicrophoneTest: Bool {
        !externalClientIsUsingMedia && !deviceOperationInProgress
            && configurationController.isConfigurationUsable
            && microphoneAuthorization == .authorized
            && microphoneSourceAvailable
    }

    var hasConfiguredAIFeatures: Bool {
        configurationController.configuration.pipeline.videoStages.contains(where: \.enabled)
            || configurationController.configuration.pipeline.conversation.enabled
            || configurationController.configuration.pipeline.conversation.transcriptionEnabled
            || configurationController.configuration.pipeline.translation.enabled
    }

    var scriptOverlayEnabled: Bool {
        configurationController.configuration.overlays.script.enabled
    }

    var realtimeConversationEnabled: Bool {
        let conversation = configurationController.configuration.pipeline.conversation
        return conversation.enabled && conversation.realtimeEnabled && conversation.realtimeEndpointID != nil
    }

    var realtimeConversationActive: Bool {
        realtimeConversationState != .idle && realtimeConversationState != .failed
    }

    var canStartRealtimeConversation: Bool {
        realtimeConversationEnabled
            && !externalClientIsUsingMedia
            && (microphoneTestActive || canStartMicrophoneTest)
            && realtimeConnectTask == nil
    }

    var isPurePassthrough: Bool {
        !hasConfiguredAIFeatures
            && !configurationController.configuration.capture.mirrorVideo
            && !configurationController.configuration.overlays.enabled
    }

    init() {
        cameraExtensionManager.objectWillChange
            .merge(with: audioDriverManager.objectWillChange)
            .sink { [weak self] _ in
                guard let self else { return }
                self.objectWillChange.send()
                Task { @MainActor [weak self] in
                    await Task.yield()
                    self?.demandMonitor.refresh()
                    self?.reconcileDemand()
                }
            }
            .store(in: &managerCancellables)

        demandMonitor.$snapshot
            .removeDuplicates()
            .sink { [weak self] _ in
                // @Published emits from willSet. Reconcile on the next MainActor turn so
                // demandMonitor exposes the new atomic camera/microphone snapshot.
                Task { @MainActor [weak self] in
                    await Task.yield()
                    self?.reconcileDemand()
                }
            }
            .store(in: &lifecycleCancellables)

        configurationController.$configuration
            .dropFirst()
            .debounce(for: .milliseconds(200), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.cameraLaneError = nil
                self?.microphoneLaneError = nil
                self?.refreshResolvedSources()
                self?.beginStop()
            }
            .store(in: &lifecycleCancellables)

        Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.refreshAuthorizationIfNeeded() }
            .store(in: &lifecycleCancellables)

        Timer.publish(every: 0.1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.refreshMicrophoneInputLevel() }
            .store(in: &lifecycleCancellables)

        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                self?.refreshDevicesAndDrivers()
                self?.reconcileDemand()
            }
            .store(in: &lifecycleCancellables)

        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in self?.stopForTermination() }
            .store(in: &lifecycleCancellables)

        refreshDevicesAndDrivers()
        reconcileDemand()
    }

    func refreshDevicesAndDrivers() {
        videoDevices = DeviceDiscovery.videoInputs(excluding: AICameraVirtualCamera.deviceUID)
        cameraVirtualDeviceAvailable = DeviceDiscovery.videoDeviceIsAvailable(
            withUID: AICameraVirtualCamera.deviceUID
        )
        audioInputDevices = DeviceDiscovery.audioInputs()
        audioOutputDevices = DeviceDiscovery.audioOutputs()
        refreshResolvedSources()
        cameraAuthorization = AVCaptureDevice.authorizationStatus(for: .video)
        microphoneAuthorization = AVCaptureDevice.authorizationStatus(for: .audio)
        loginItemController.refresh()
        cameraExtensionManager.refresh()
        audioDriverManager.refresh()
        demandMonitor.refresh()
        updateStatus()
    }

    private func refreshResolvedSources() {
        let capture = configurationController.configuration.capture
        cameraSourceWarning = nil
        microphoneSourceWarning = nil
        cameraSourceAvailable = false
        microphoneSourceAvailable = false

        if let configuredID = capture.videoDeviceID {
            let resolution = DeviceDiscovery.resolveVideoInput(
                requestedID: configuredID,
                excluding: AICameraVirtualCamera.deviceUID,
                requestedFPS: Double(capture.framesPerSecond)
            )
            if let device = resolution.device {
                cameraSourceAvailable = true
                cameraSourceText = "\(device.localizedName) — selected"
            } else {
                cameraSourceText = "Selected camera unavailable or incompatible"
                cameraSourceWarning = "Select an available physical camera and compatible frame rate in Settings."
            }
        } else {
            let resolution = DeviceDiscovery.resolveVideoInput(
                requestedID: nil,
                excluding: AICameraVirtualCamera.deviceUID,
                requestedFPS: Double(capture.framesPerSecond)
            )
            if let device = resolution.device {
                cameraSourceAvailable = true
                cameraSourceText = resolution.fallback == nil
                    ? "System Default — \(device.localizedName)"
                    : "Fallback — \(device.localizedName)"
            } else {
                cameraSourceText = "System Default — no compatible physical camera"
            }
            if let fallback = resolution.fallback {
                cameraSourceWarning = defaultInputWarning(
                    lane: "camera",
                    fallback: fallback,
                    selectedName: resolution.device?.localizedName
                )
            }
        }

        if let configuredID = capture.audioDeviceID {
            if let device = audioInputDevices.first(where: { $0.id == configuredID }) {
                microphoneSourceAvailable = true
                microphoneSourceText = "\(device.name) — selected"
            } else {
                microphoneSourceText = "Selected microphone unavailable"
                microphoneSourceWarning = "Select an available local physical microphone in Settings."
            }
        } else {
            let resolution = DeviceDiscovery.resolveDefaultAudioInput(
                excludingUID: AICameraAudioDevice.uid
            )
            if let device = resolution.device {
                microphoneSourceAvailable = true
                microphoneSourceText = resolution.fallback == nil
                    ? "System Default — \(device.name)"
                    : "Fallback — \(device.name)"
            } else {
                microphoneSourceText = "System Default — no physical microphone"
            }
            if let fallback = resolution.fallback {
                microphoneSourceWarning = defaultInputWarning(
                    lane: "microphone",
                    fallback: fallback,
                    selectedName: resolution.device?.name
                )
            }
        }
    }

    private func defaultInputWarning(
        lane: String,
        fallback: DefaultInputFallback,
        selectedName: String?
    ) -> String {
        if fallback.reason == .incompatibleVideoFrameRate {
            let framesPerSecond = configurationController.configuration.capture.framesPerSecond
            let description = "The system camera default, \(fallback.excludedDefault.name), does not support \(framesPerSecond) fps"
            if let selectedName {
                return "\(description). Using \(selectedName) instead."
            }
            return "\(description). Select a compatible physical camera or frame rate in Settings."
        }

        let defaultDescription = fallback.isOwnVirtualDevice
            ? "AI Camera is the system \(lane) default"
            : "The system \(lane) default, \(fallback.excludedDefault.name), is not an eligible local physical input"
        if let selectedName {
            let reason = fallback.isOwnVirtualDevice ? " to prevent a capture loop" : " instead"
            return "\(defaultDescription). Using \(selectedName)\(reason)."
        }
        return "\(defaultDescription). Select an eligible local physical \(lane) in Settings."
    }

    func selectSettings(
        page: AICameraSettingsPage,
        lane: AICameraSettingsLane? = nil
    ) {
        selectedSettingsPage = page
        selectedSettingsLane = lane
        settingsNavigationGeneration &+= 1
    }

    func setOpenAtLogin(_ enabled: Bool) {
        loginItemController.setEnabled(enabled)
        if let error = loginItemController.errorMessage {
            lastError = error
        } else {
            lastError = nil
        }
    }

    func toggleCameraTest() {
        demandMonitor.refresh()
        if cameraTestActive {
            cameraTestActive = false
            reconcileDemand()
            return
        }
        guard canStartCameraTest else { return }
        lastError = nil
        cameraLaneError = nil
        cameraTestActive = true
        reconcileDemand()
    }

    func toggleMicrophoneTest() {
        demandMonitor.refresh()
        if microphoneTestActive {
            microphoneTestActive = false
            microphoneInputLevel = 0
            reconcileDemand()
            return
        }
        guard canStartMicrophoneTest else { return }
        lastError = nil
        microphoneLaneError = nil
        microphoneTestActive = true
        microphoneInputLevel = 0
        reconcileDemand()
    }

    func retryDemand() {
        lastError = nil
        cameraLaneError = nil
        microphoneLaneError = nil
        refreshDevicesAndDrivers()
        reconcileDemand()
    }

    func requestCameraAccess() {
        requestCameraAccess(after: nil)
    }

    func requestMicrophoneAccess() {
        requestMicrophoneAccess(after: nil)
    }

    func openCameraPrivacySettings() {
        Self.openPrivacySettings(pane: "Privacy_Camera")
    }

    func openMicrophonePrivacySettings() {
        Self.openPrivacySettings(pane: "Privacy_Microphone")
    }

    func activateCameraExtension() {
        guard retryFailedCameraCleanup() else { return }
        runAfterStop { [weak self] in
            self?.requestCameraAccess { [weak self] in
                self?.cameraExtensionManager.activate()
            }
        }
    }

    func deactivateCameraExtension() {
        guard retryFailedCameraCleanup() else { return }
        runAfterStop { [weak self] in self?.cameraExtensionManager.deactivate() }
    }

    func installAudioDriver() {
        runAfterStop { [weak self] in
            self?.requestMicrophoneAccess { [weak self] in
                self?.audioDriverManager.install()
            }
        }
    }

    func uninstallAudioDriver() {
        runAfterStop { [weak self] in self?.audioDriverManager.uninstall() }
    }

    private func refreshMicrophoneInputLevel() {
        guard microphoneTestActive, microphoneIsActive, let audioController else {
            if microphoneInputLevel != 0 { microphoneInputLevel = 0 }
            return
        }
        let sampledLevel = audioController.inputLevelSnapshot()
        let level: Float = sampledLevel < 0.01 ? 0 : sampledLevel
        if (level == 0 && microphoneInputLevel != 0)
            || abs(level - microphoneInputLevel) >= 0.005 {
            microphoneInputLevel = level
        }
    }

    private func refreshAuthorizationIfNeeded() {
        let currentCameraAuthorization = AVCaptureDevice.authorizationStatus(for: .video)
        let currentMicrophoneAuthorization = AVCaptureDevice.authorizationStatus(for: .audio)
        guard currentCameraAuthorization != cameraAuthorization
            || currentMicrophoneAuthorization != microphoneAuthorization else { return }
        cameraAuthorization = currentCameraAuthorization
        microphoneAuthorization = currentMicrophoneAuthorization
        reconcileDemand()
    }

    private func reconcileDemand() {
        let hadActiveTest = cameraTestActive || microphoneTestActive
        let externalDemandArrived = demandMonitor.cameraRequested
            || demandMonitor.microphoneRequested
        let microphoneTestWasActive = microphoneTestActive
        let testDemand = MediaTestDemandDecision.resolve(
            cameraClientRequested: demandMonitor.cameraRequested,
            microphoneClientRequested: demandMonitor.microphoneRequested,
            cameraTestRequested: cameraTestActive,
            microphoneTestRequested: microphoneTestActive
        )
        cameraTestActive = testDemand.cameraTestActive
        microphoneTestActive = testDemand.microphoneTestActive
        if microphoneTestWasActive && !microphoneTestActive {
            microphoneInputLevel = 0
        }
        if hadActiveTest && externalDemandArrived,
           !isStopping, stopTask == nil,
           pipeline != nil || videoController != nil || audioController != nil {
            // A client takeover is a clean privacy boundary: cancel all test-derived model,
            // inference, conversation, speech, and scene state before serving the client.
            beginStop()
            return
        }
        if cameraTestActive && (!configurationController.isConfigurationUsable
            || !cameraExtensionManager.status.isInstalled
            || cameraAuthorization != .authorized || !cameraSourceAvailable) {
            cameraTestActive = false
        }
        if microphoneTestActive && (!configurationController.isConfigurationUsable
            || !audioDriverManager.status.isInstalled
            || microphoneAuthorization != .authorized || !microphoneSourceAvailable) {
            microphoneTestActive = false
            microphoneInputLevel = 0
        }

        guard !isStopping, stopTask == nil else { return }
        if pipelineStopTask != nil {
            pendingDemandReconcile = true
            updateStatus()
            return
        }

        let decision = MediaDemandDecision.resolve(
            configurationUsable: configurationController.isConfigurationUsable,
            cameraRequested: demandMonitor.cameraRequested || cameraTestActive,
            cameraAvailable: cameraExtensionManager.status.isInstalled,
            cameraAuthorized: cameraAuthorization == .authorized,
            microphoneRequested: demandMonitor.microphoneRequested || microphoneTestActive,
            microphoneAvailable: audioDriverManager.status.isInstalled,
            microphoneAuthorized: microphoneAuthorization == .authorized
        )

        // Start every desired lane before stopping any undesired lane. Shared coordinator
        // teardown is evaluated once after both decisions, so one lane cannot starve the other.
        if decision.cameraShouldRun { startCameraIfNeeded() }
        if decision.microphoneShouldRun { startMicrophoneIfNeeded() }
        if !decision.cameraShouldRun { stopCameraIfNeeded() }
        if !decision.microphoneShouldRun { stopMicrophoneIfNeeded() }
        stopPipelineIfUnused()
        updateStatus()
    }

    private func startCameraIfNeeded() {
        guard retryFailedCameraCleanup() else {
            if cameraTestActive { cameraTestActive = false }
            return
        }
        guard videoController == nil else { return }
        guard !deviceOperationInProgress else {
            if pipelineStopTask != nil { pendingDemandReconcile = true }
            return
        }
        let (coordinator, pipelineGate) = ensurePipeline()
        let laneGate = PipelineRunGate()
        cameraRunGate?.cancel()
        cameraRunGate = laneGate
        let configuration = configurationController.configuration
        ensureScriptRenderer(for: configuration)
        let video = VideoPipelineController(
            configuration: configuration,
            onPreview: { [weak self] image in
                guard pipelineGate.isActive, laneGate.isActive else { return }
                let sendableImage = SendableImage(value: image)
                Task { @MainActor [weak model = self, sendableImage] in
                    guard pipelineGate.isActive, laneGate.isActive else { return }
                    model?.previewImage = sendableImage.value
                }
            },
            onGestures: { observations, frameID in
                guard pipelineGate.isActive, laneGate.isActive else { return }
                Task {
                    guard pipelineGate.isActive, laneGate.isActive else { return }
                    await coordinator.submit(gestures: observations, frameID: frameID)
                }
            },
            onFrame: { packet in
                guard pipelineGate.isActive, laneGate.isActive else { return }
                Task {
                    guard pipelineGate.isActive, laneGate.isActive else { return }
                    await coordinator.submit(frame: packet)
                }
            },
            onError: { [weak self] message in
                guard pipelineGate.isActive, laneGate.isActive else { return }
                Task { @MainActor [weak model = self] in
                    guard pipelineGate.isActive, laneGate.isActive else { return }
                    model?.cameraLaneError = message
                }
            },
            scriptRenderer: scriptRenderer
        )

        do {
            try video.start(publishToVirtualCamera: demandMonitor.cameraRequested)
            videoController = video
            cameraIsActive = true
            cameraLaneError = nil
        } catch {
            laneGate.cancel()
            if cameraRunGate === laneGate { cameraRunGate = nil }
            if cameraTestActive { cameraTestActive = false }
            let stopStatus = video.stop()
            if stopStatus == noErr {
                cameraLaneError = error.localizedDescription
            } else {
                videoController = nil
                failedVideoCleanupController = video
                cameraIsActive = false
                previewImage = nil
                cameraLaneError = "\(error.localizedDescription) Camera cleanup also failed with status \(stopStatus)."
            }
        }
        updateStatus()
    }

    private func startMicrophoneIfNeeded() {
        guard audioController == nil else { return }
        guard !deviceOperationInProgress else {
            if pipelineStopTask != nil { pendingDemandReconcile = true }
            return
        }
        let (coordinator, pipelineGate) = ensurePipeline()
        let laneGate = PipelineRunGate()
        microphoneRunGate?.cancel()
        microphoneRunGate = laneGate
        let configuration = configurationController.configuration
        let controller = AudioPipelineController(
            configuration: configuration.capture,
            utteranceSeconds: configuration.pipeline.conversation.utteranceSeconds,
            transcriptionEnabled: configuration.pipeline.conversation.transcriptionEnabled
                && configuration.pipeline.conversation.transcriptionEndpointID != nil,
            onUtterance: { utterance in
                guard pipelineGate.isActive, laneGate.isActive else { return }
                Task {
                    guard pipelineGate.isActive, laneGate.isActive else { return }
                    await coordinator.submit(utterance: utterance)
                }
            },
            onBargeIn: {
                guard pipelineGate.isActive, laneGate.isActive else { return }
                Task {
                    guard pipelineGate.isActive, laneGate.isActive else { return }
                    _ = await coordinator.bargeIn()
                }
            },
            onError: { [weak self] message in
                guard pipelineGate.isActive, laneGate.isActive else { return }
                Task { @MainActor [weak self] in
                    guard pipelineGate.isActive, laneGate.isActive else { return }
                    self?.microphoneLaneError = message
                }
            }
        )
        do {
            try controller.start(
                publishToVirtualMicrophone: demandMonitor.microphoneRequested
            )
            audioController = controller
            microphoneIsActive = true
            microphoneLaneError = nil
        } catch {
            laneGate.cancel()
            if microphoneRunGate === laneGate { microphoneRunGate = nil }
            if microphoneTestActive { microphoneTestActive = false }
            microphoneInputLevel = 0
            microphoneLaneError = "Microphone proxy is unavailable: \(error.localizedDescription)"
        }
        updateStatus()
    }

    private func ensurePipeline() -> (PipelineCoordinator, PipelineRunGate) {
        if let pipeline, let runGate { return (pipeline, runGate) }

        let configuration = configurationController.configuration
        let builtinDetectionModelID = configuration.pipeline.videoStages.first(where: {
            $0.kind == .objectDetection && $0.options["provider"]?.stringValue == "builtin"
        })?.options["model"]?.stringValue
        let gate = PipelineRunGate()
        let coordinator = PipelineCoordinator(
            configuration: configuration,
            secrets: AppSecretResolver(),
            builtinDetectionClient: builtinVisionModelController.makeDetectionClient(
                modelID: builtinDetectionModelID
            ),
            builtinTranslationClient: configuration.pipeline.translation.enabled
                ? builtinTranslationModelController.makeTranslationClient()
                : nil,
            onSnapshot: { [weak self] snapshot in
                guard gate.isActive else { return }
                Task { @MainActor [weak model = self] in
                    guard gate.isActive, let model else { return }
                    model.currentSnapshot = snapshot
                    if model.cameraRunGate?.isActive == true {
                        model.videoController?.update(snapshot: snapshot)
                        model.pushSceneData(to: snapshot)
                    }
                }
            },
            onSpeech: { [weak self] event in
                guard gate.isActive else { return false }
                return await withCheckedContinuation { continuation in
                    Task { @MainActor [weak model = self] in
                        guard gate.isActive, let model,
                              model.microphoneRunGate?.isActive == true,
                              let audio = model.audioController else {
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
        pipeline = coordinator
        runGate = gate
        Task {
            guard gate.isActive else { return }
            await coordinator.started()
        }
        return (coordinator, gate)
    }

    // MARK: - Realtime conversation

    func toggleRealtimeConversation() {
        if realtimeConversationActive {
            stopRealtimeConversation()
        } else {
            startRealtimeConversation()
        }
    }

    func startRealtimeConversation() {
        guard canStartRealtimeConversation else {
            lastError = "Realtime conversation is not configured or the microphone is unavailable."
            return
        }
        let profile = configurationController.configuration
        let conversation = profile.pipeline.conversation
        guard let endpointID = conversation.realtimeEndpointID,
              let endpoint = profile.endpoints.first(where: { $0.id == endpointID }),
              endpoint.adapter == .openAIRealtime else {
            lastError = "The Realtime endpoint is missing."
            return
        }
        do {
            var dataClasses: Set<MediaDataClass> = [.rawAudio, .transcript, .promptText]
            if conversation.includeSceneSummary { dataClasses.insert(.sceneMetadata) }
            try PrivacyGate(configuration: profile.privacy).authorize(endpoint: endpoint, data: dataClasses)
        } catch {
            lastError = "Realtime privacy gate: \(error.localizedDescription)"
            return
        }
        realtimeOwnsMicrophoneTest = !microphoneTestActive
        if !microphoneTestActive {
            microphoneTestActive = true
            reconcileDemand()
        }
        guard microphoneRunGate?.isActive == true, let audioController else {
            realtimeOwnsMicrophoneTest = false
            lastError = "The microphone could not start for Talk."
            return
        }
        do { try audioController.enableLocalSpeechPlayback() }
        catch {
            lastError = error.localizedDescription
            closeRealtimeTransport(state: .failed, stopSpeech: true)
            return
        }
        let coordinator = pipeline

        realtimeGeneration &+= 1
        let generation = realtimeGeneration
        realtimeConversationState = .connecting
        realtimeFinishTask?.cancel()
        realtimeFinishTask = nil
        realtimeToolContinuationPending = false
        resetRealtimeAudio(stopPlayback: true)
        realtimeAcceptingAudio = true
        lastError = nil
        realtimeConnectTask = Task { [weak self] in
            guard let self else { return }
            do {
                await coordinator?.setRealtimeTranscriptionActive(true)
                try Task.checkCancellation()
                guard let secret = try await AppSecretResolver().resolve(endpoint.auth), !secret.isEmpty else {
                    throw NSError(
                        domain: "AICamera.Realtime",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "The Realtime credential is missing from Keychain."]
                    )
                }
                guard !Task.isCancelled, generation == self.realtimeGeneration else { return }
                let signalingURL = try Self.realtimeSignalingURL(for: endpoint)
                let session = RealtimeConversationSession(
                    signalingURL: signalingURL,
                    credential: .init(field: endpoint.auth.header, value: endpoint.auth.prefix + secret)
                )
                audioController.setRealtimeAudioHandler { [weak session] data, capturedAt in
                    session?.appendInputPCM(data, capturedAt: capturedAt)
                }
                self.realtimeSession = session
                self.realtimeEventTask = Task { [weak self, weak session] in
                    guard let self, let session else { return }
                    for await event in session.events {
                        guard !Task.isCancelled else { return }
                        await self.handleRealtimeEvent(event, session: session, generation: generation)
                    }
                }
                let request = RealtimeSessionConfiguration.request(
                    endpoint: endpoint,
                    conversation: conversation,
                    profile: profile,
                    toolsAvailable: profile.overlays.script.enabled && self.cameraRunGate?.isActive == true
                )
                try await session.connect(session: request)
                guard !Task.isCancelled, generation == self.realtimeGeneration else {
                    await session.close()
                    return
                }
                try await session.armOneShotAudio()
                self.realtimeConversationState = .listening
                self.realtimeConnectTask = nil
            } catch is CancellationError {
                return
            } catch {
                guard generation == self.realtimeGeneration else { return }
                self.realtimeConnectTask = nil
                self.lastError = "Realtime: \(error.localizedDescription)"
                self.closeRealtimeTransport(state: .failed, stopSpeech: true)
            }
        }
    }

    func stopRealtimeConversation() {
        closeRealtimeTransport(state: .idle, stopSpeech: true)
    }

    private func closeRealtimeTransport(
        state: RealtimeConversationState,
        stopSpeech: Bool
    ) {
        realtimeGeneration &+= 1
        realtimeConnectTask?.cancel()
        realtimeConnectTask = nil
        realtimeEventTask?.cancel()
        realtimeEventTask = nil
        realtimeFinishTask?.cancel()
        realtimeFinishTask = nil
        let session = realtimeSession
        audioController?.setRealtimeAudioHandler(nil)
        realtimeSession = nil
        realtimeConversationState = state
        realtimeToolContinuationPending = false
        if stopSpeech {
            resetRealtimeAudio(stopPlayback: true)
        }
        // Close the transport before re-enabling independent transcription.
        // A new Talk invalidates this cleanup before it can unmute the fallback lane.
        let coordinator = pipeline
        let generation = realtimeGeneration
        Task { [weak self] in
            await session?.close()
            guard let self, self.realtimeGeneration == generation else { return }
            await coordinator?.setRealtimeTranscriptionActive(false)
        }
        audioController?.disableLocalSpeechPlayback()
        if realtimeOwnsMicrophoneTest {
            realtimeOwnsMicrophoneTest = false
            microphoneTestActive = false
            reconcileDemand()
        }
    }

    private func handleRealtimeEvent(
        _ event: RealtimeSessionEvent,
        session: any RealtimeConversationClient,
        generation: UInt64
    ) async {
        guard generation == realtimeGeneration, session === realtimeSession else { return }
        switch event {
        case .connected:
            break
        case .speechStarted:
            realtimeConversationState = .listening
        case .speechStopped:
            realtimeConversationState = .responding
        case let .transcript(_, text, isFinal):
            await pipeline?.submitRealtimeTranscript(text: text, isFinal: isFinal)
        case let .functionCall(call):
            realtimeToolContinuationPending = true
            await executeRealtimeTool(call, session: session, generation: generation)
        case .responseDone:
            if realtimeToolContinuationPending {
                realtimeToolContinuationPending = false
                do { try await session.requestContinuation(["tool_choice": "none"]) }
                catch {
                    guard generation == realtimeGeneration else { return }
                    lastError = error.localizedDescription
                    closeRealtimeTransport(state: .failed, stopSpeech: true)
                }
            } else {
                finishRealtimeResponse(session: session, generation: generation)
            }
        case let .error(failure):
            lastError = failure.localizedDescription
            closeRealtimeTransport(state: .failed, stopSpeech: true)
        case let .audio(chunk):
            enqueueRealtimeAudio(chunk)
        }
    }

    private func finishRealtimeResponse(
        session: any RealtimeConversationClient,
        generation: UInt64
    ) {
        realtimeFinishTask?.cancel()
        realtimeFinishTask = Task { @MainActor [weak self, weak session] in
            guard let self, let session,
                  generation == self.realtimeGeneration,
                  session === self.realtimeSession else { return }
            self.realtimeFinishTask = nil
            self.realtimeAcceptingAudio = false
            await session.close()
            guard generation == self.realtimeGeneration else { return }
            guard self.realtimeSpeechID != nil else {
                self.closeRealtimeTransport(state: .idle, stopSpeech: false)
                return
            }
            self.realtimeAudioFinishRequested = true
            self.drainRealtimeAudioQueue()
        }
    }

    private func enqueueRealtimeAudio(_ chunk: RealtimePCMChunk) {
        guard realtimeAcceptingAudio, let audio = audioController,
              microphoneRunGate?.isActive == true else { return }
        guard let buffers = chunk.playbackBuffers else {
            lastError = "Realtime audio has an invalid PCM format or message size."
            closeRealtimeTransport(state: .failed, stopSpeech: true)
            return
        }
        if realtimeSpeechID != nil {
            guard realtimeAudioSampleRate == chunk.sampleRate else {
                lastError = "Realtime audio format changed during a response."
                stopRealtimeConversation()
                return
            }
        } else {
            let newID = UUID()
            realtimeSpeechID = newID
            realtimeAudioSampleRate = chunk.sampleRate
            audio.handleSpeech(.beginPCM(
                speechID: newID,
                sampleRate: chunk.sampleRate,
                channels: chunk.channels
            )) { [weak self] accepted in
                guard !accepted else { return }
                Task { @MainActor [weak self] in
                    guard self?.realtimeSpeechID == newID else { return }
                    self?.lastError = "Realtime audio output could not start."
                    self?.stopRealtimeConversation()
                }
            }
        }
        let maximumPendingBytes = max(2, chunk.sampleRate * MemoryLayout<Int16>.size * 120)
        guard chunk.data.count <= maximumPendingBytes,
              realtimeAudioQueueBytes <= maximumPendingBytes - chunk.data.count else {
            lastError = "Realtime audio exceeded its bounded two-minute response limit."
            stopRealtimeConversation()
            return
        }
        realtimeAudioQueue.append(contentsOf: buffers)
        realtimeAudioQueueBytes += chunk.data.count
        drainRealtimeAudioQueue()
    }

    private func drainRealtimeAudioQueue() {
        guard !realtimeAudioSending,
              let audio = audioController,
              let speechID = realtimeSpeechID else { return }
        guard !realtimeAudioQueue.isEmpty else {
            if realtimeAudioFinishRequested {
                realtimeAudioFinishRequested = false
                realtimeAudioSending = true
                audio.handleSpeech(.finishPCM(speechID: speechID)) { [weak self] playedToEnd in
                    Task { @MainActor [weak self] in
                        guard let self, self.realtimeSpeechID == speechID else { return }
                        self.realtimeAudioSending = false
                        self.realtimeAudioSampleRate = nil
                        self.realtimeSpeechID = nil
                        guard playedToEnd else {
                            self.lastError = "Realtime audio playback did not reach its final buffer."
                            self.closeRealtimeTransport(state: .failed, stopSpeech: true)
                            return
                        }
                        self.closeRealtimeTransport(state: .idle, stopSpeech: false)
                    }
                }
            }
            return
        }
        let data = realtimeAudioQueue.removeFirst()
        realtimeAudioQueueBytes -= data.count
        realtimeAudioSending = true
        audio.handleSpeech(.pcm(speechID: speechID, data: data)) { [weak self] accepted in
            Task { @MainActor [weak self] in
                guard let self, self.realtimeSpeechID == speechID else { return }
                self.realtimeAudioSending = false
                guard accepted else {
                    self.lastError = "Realtime audio output rejected a serialized chunk."
                    self.stopRealtimeConversation()
                    return
                }
                self.drainRealtimeAudioQueue()
            }
        }
    }

    private func resetRealtimeAudio(stopPlayback: Bool) {
        realtimeAcceptingAudio = false
        realtimeAudioQueue.removeAll(keepingCapacity: true)
        realtimeAudioQueueBytes = 0
        realtimeAudioSending = false
        realtimeAudioFinishRequested = false
        realtimeAudioSampleRate = nil
        realtimeSpeechID = nil
        if stopPlayback {
            audioController?.handleSpeech(.stop(speechID: nil)) { _ in }
        }
    }

    private func executeRealtimeTool(
        _ call: RealtimeFunctionCall,
        session: any RealtimeConversationClient,
        generation: UInt64
    ) async {
        let result = applyRealtimeTool(call)
        guard generation == realtimeGeneration,
              session === realtimeSession,
              let outputData = try? JSONSerialization.data(withJSONObject: result),
              let output = String(data: outputData, encoding: .utf8) else { return }
        do {
            try await session.completeFunctionCall(
                callID: call.callID,
                output: output
            )
        } catch {
            lastError = "Realtime tool result: \(error.localizedDescription)"
            closeRealtimeTransport(state: .failed, stopSpeech: true)
        }
    }

    private func applyRealtimeTool(_ call: RealtimeFunctionCall) -> [String: Any] {
        let configuration = configurationController.configuration.overlays.script
        guard configuration.enabled, let renderer = scriptRenderer, cameraRunGate?.isActive == true else {
            return ["ok": false, "error": "Overlay tools require enabled Tools and an active camera test."]
        }
        guard let command = RealtimeOverlayCommand.parse(name: call.name, arguments: call.arguments, configuration: configuration) else {
            return ["ok": false, "error": "Unknown tool or invalid arguments."]
        }
        switch command {
        case let .render(script, ttl):
            guard renderer.load(script: script, ttlSeconds: ttl) else {
                return ["ok": false, "error": "Script rejected by host limits."]
            }
            overlayScriptLog = "Realtime overlay active"
            return ["ok": true, "width": 640, "height": 360, "ttlSeconds": ttl]
        case .clear:
            renderer.clear()
            overlayScriptLog = "Overlay cleared by Realtime"
            return ["ok": true]
        }
    }

    private static func realtimeSignalingURL(for endpoint: EndpointConfiguration) throws -> URL {
        if let path = endpoint.path, !path.isEmpty {
            guard let url = URL(string: path, relativeTo: endpoint.baseURL)?.absoluteURL else {
                throw NSError(domain: "AICamera.Realtime", code: 2)
            }
            return url
        }
        if endpoint.baseURL.path.hasSuffix("/v1/realtime/calls") {
            return endpoint.baseURL
        }
        if endpoint.baseURL.path.hasSuffix("/v1") {
            return endpoint.baseURL.appendingPathComponent("realtime/calls")
        }
        return endpoint.baseURL.appendingPathComponent("v1/realtime/calls")
    }

    // MARK: - Script overlay

    private func ensureScriptRenderer(for configuration: AICameraConfiguration) {
        guard configuration.overlays.script.enabled, scriptRenderer == nil else { return }
        let renderer = OverlayScriptRenderer(
            scriptConfiguration: configuration.overlays.script,
            onLog: { [weak self] line in
                Task { @MainActor [weak self] in
                    self?.overlayScriptLog = line
                }
            }
        )
        renderer.start()
        scriptRenderer = renderer
    }

    private func stopScriptRenderer() {
        scriptRenderer?.stop()
        scriptRenderer = nil
    }

    /// Dev/acceptance entry point: run a pasted overlay script on the live
    /// camera test. Phase 2 replaces this with the agent `render_overlay` tool.
    func loadOverlayScript(_ script: String) {
        let scriptConfig = configurationController.configuration.overlays.script
        guard let renderer = scriptRenderer else {
            overlayScriptLog = "Start the camera test first."
            return
        }
        if renderer.load(script: script, ttlSeconds: scriptConfig.defaultTTLSeconds) {
            overlayScriptLog = "Script loaded (\(Int(scriptConfig.defaultTTLSeconds))s TTL)."
        } else {
            overlayScriptLog = "Script rejected (max \(scriptConfig.maxScriptBytes) bytes)."
        }
    }

    func clearOverlayScript() {
        scriptRenderer?.clear()
        overlayScriptLog = "Overlay cleared."
    }

    private func pushSceneData(to snapshot: SceneSnapshot) {
        guard let renderer = scriptRenderer,
              configurationController.configuration.overlays.script.allowSceneData else { return }
        renderer.updateSceneData(Self.sceneDataJSON(for: snapshot))
    }

    private static func sceneDataJSON(for snapshot: SceneSnapshot) -> String {
        struct DetectionPayload: Encodable {
            let label: String
            let confidence: Double
            let box: [Double]
        }
        struct Payload: Encodable {
            let detections: [DetectionPayload]
            let gestures: [String]
            let transcript: String?
            let agentResponse: String?
        }
        let payload = Payload(
            detections: snapshot.detections.map {
                DetectionPayload(
                    label: $0.label,
                    confidence: $0.confidence,
                    box: [$0.boundingBox.x, $0.boundingBox.y, $0.boundingBox.width, $0.boundingBox.height]
                )
            },
            gestures: snapshot.gestures.map(\.kind.rawValue),
            transcript: snapshot.transcript?.text,
            agentResponse: snapshot.agentResponse
        )
        guard let data = try? JSONEncoder().encode(payload),
              let json = String(data: data, encoding: .utf8) else {
            return "null"
        }
        return json
    }

    @discardableResult
    private func retryFailedCameraCleanup() -> Bool {
        guard let controller = failedVideoCleanupController else { return true }
        let status = controller.stop()
        guard status == noErr else {
            cameraLaneError = "Virtual camera cleanup failed with status \(status)."
            return false
        }
        failedVideoCleanupController = nil
        cameraLaneError = nil
        return true
    }

    private func stopCameraIfNeeded() {
        cameraRunGate?.cancel()
        cameraRunGate = nil
        stopScriptRenderer()
        guard let video = videoController else {
            _ = retryFailedCameraCleanup()
            previewImage = nil
            cameraIsActive = false
            return
        }
        let status = video.stop()
        guard status == noErr else {
            videoController = nil
            failedVideoCleanupController = video
            cameraIsActive = false
            previewImage = nil
            cameraLaneError = "Virtual camera cleanup failed with status \(status)."
            return
        }
        videoController = nil
        previewImage = nil
        cameraIsActive = false
    }

    private func stopMicrophoneIfNeeded() {
        if realtimeConversationActive { stopRealtimeConversation() }
        microphoneRunGate?.cancel()
        microphoneRunGate = nil
        microphoneInputLevel = 0
        guard let audio = audioController else {
            microphoneIsActive = false
            return
        }
        audio.stop()
        audioController = nil
        microphoneIsActive = false
    }

    private func stopPipelineIfUnused() {
        guard pipelineStopTask == nil, videoController == nil, audioController == nil,
              let coordinator = pipeline else { return }
        cameraRunGate?.cancel()
        microphoneRunGate?.cancel()
        cameraRunGate = nil
        microphoneRunGate = nil
        runGate?.cancel()
        runGate = nil
        pipeline = nil
        currentSnapshot = SceneSnapshot()
        pipelineStopGeneration &+= 1
        let generation = pipelineStopGeneration
        pipelineStopTask = Task { [weak self] in
            await coordinator.stop()
            guard let self, self.pipelineStopGeneration == generation else { return }
            self.pipelineStopTask = nil
            let shouldReconcile = self.pendingDemandReconcile
            self.pendingDemandReconcile = false
            if shouldReconcile {
                self.reconcileDemand()
            } else {
                self.updateStatus()
            }
        }
    }

    private func runAfterStop(_ action: @escaping @MainActor () -> Void) {
        guard stopTask == nil, pipelineStopTask == nil,
              cameraPermissionTask == nil, microphonePermissionTask == nil,
              !cameraExtensionManager.hasPendingRequest, !audioDriverManager.status.isBusy else {
            lastError = "Wait for the current device operation to finish."
            return
        }
        if pipeline != nil || videoController != nil || audioController != nil {
            beginStop(after: action)
        } else {
            action()
        }
    }

    private func beginStop(after completion: (@MainActor () -> Void)? = nil) {
        guard stopTask == nil else { return }
        stopRealtimeConversation()
        cameraTestActive = false
        microphoneTestActive = false
        microphoneInputLevel = 0
        cameraRunGate?.cancel()
        microphoneRunGate?.cancel()
        cameraRunGate = nil
        microphoneRunGate = nil
        if pipelineStopTask != nil {
            pendingDemandReconcile = true
            return
        }
        cameraPermissionGeneration &+= 1
        microphonePermissionGeneration &+= 1
        cameraPermissionTask?.cancel()
        microphonePermissionTask?.cancel()
        cameraPermissionTask = nil
        microphonePermissionTask = nil
        runGate?.cancel()
        runGate = nil

        let coordinator = pipeline
        let video = videoController
        let audio = audioController
        pipeline = nil
        videoController = nil
        audioController = nil
        stopScriptRenderer()
        currentSnapshot = SceneSnapshot()
        cameraIsActive = false
        microphoneIsActive = false
        microphoneInputLevel = 0
        isRunning = false
        isStopping = true
        statusText = "Applying changes…"

        stopTask = Task { [weak self] in
            audio?.stop()
            let videoStopStatus = video?.stop() ?? noErr
            if let coordinator { await coordinator.stop() }
            guard let self else {
                if videoStopStatus == noErr { completion?() }
                return
            }
            self.previewImage = nil
            self.isStopping = false
            self.stopTask = nil

            guard videoStopStatus == noErr else {
                self.failedVideoCleanupController = video
                self.cameraIsActive = false
                self.previewImage = nil
                self.cameraLaneError = "Virtual camera cleanup failed with status \(videoStopStatus)."
                self.demandMonitor.refresh()
                self.reconcileDemand()
                return
            }

            completion?()
            self.demandMonitor.refresh()
            self.reconcileDemand()
        }
    }

    private func stopForTermination() {
        stopRealtimeConversation()
        cameraPermissionGeneration &+= 1
        microphonePermissionGeneration &+= 1
        cameraPermissionTask?.cancel()
        microphonePermissionTask?.cancel()
        cameraPermissionTask = nil
        microphonePermissionTask = nil
        cameraRunGate?.cancel()
        microphoneRunGate?.cancel()
        cameraRunGate = nil
        microphoneRunGate = nil
        runGate?.cancel()
        runGate = nil
        audioController?.stop()
        _ = videoController?.stop()
        _ = failedVideoCleanupController?.stop()
        audioController = nil
        videoController = nil
        failedVideoCleanupController = nil
        cameraIsActive = false
        microphoneIsActive = false
        cameraTestActive = false
        microphoneTestActive = false
        microphoneInputLevel = 0
        stopScriptRenderer()
        if let pipeline {
            Task { await pipeline.stop() }
        }
        pipeline = nil
    }

    private func updateStatus() {
        isRunning = cameraIsActive || microphoneIsActive
        if isStopping || pipelineStopTask != nil {
            statusText = "Applying changes…"
        } else if !configurationController.isConfigurationUsable {
            statusText = "Profile repair required"
        } else if cameraTestActive && microphoneTestActive {
            statusText = cameraIsActive && microphoneIsActive
                ? "Testing camera and microphone"
                : "Starting media tests…"
        } else if cameraTestActive {
            statusText = cameraIsActive ? "Testing camera" : "Starting camera test…"
        } else if microphoneTestActive {
            statusText = microphoneIsActive ? "Testing microphone" : "Starting microphone test…"
        } else if cameraIsActive && microphoneIsActive {
            statusText = "Camera and microphone in use"
        } else if cameraIsActive {
            statusText = "Camera in use"
        } else if microphoneIsActive {
            statusText = "Microphone in use"
        } else if demandMonitor.cameraRequested && cameraAuthorization != .authorized {
            statusText = "Camera access required"
        } else if demandMonitor.microphoneRequested && microphoneAuthorization != .authorized {
            statusText = "Microphone access required"
        } else if currentError != nil {
            statusText = "Attention required"
        } else if demandMonitor.cameraRequested || demandMonitor.microphoneRequested {
            statusText = "Starting…"
        } else if !cameraExtensionManager.status.isInstalled && !audioDriverManager.status.isInstalled {
            statusText = "Setup required"
        } else {
            statusText = "Ready — waiting for an app"
        }
    }

    private func requestCameraAccess(after action: (@MainActor () -> Void)?) {
        guard cameraPermissionTask == nil else { return }
        cameraPermissionGeneration &+= 1
        let generation = cameraPermissionGeneration
        cameraPermissionTask = Task { [weak self] in
            let allowed = await Self.requestAccess(for: .video)
            guard let self, !Task.isCancelled,
                  self.cameraPermissionGeneration == generation else { return }
            self.cameraAuthorization = AVCaptureDevice.authorizationStatus(for: .video)
            self.cameraPermissionTask = nil
            if allowed {
                self.lastError = nil
            } else {
                self.lastError = "Camera access was denied. Enable AI Camera in System Settings → Privacy & Security → Camera."
            }
            action?()
            self.reconcileDemand()
        }
    }

    private func requestMicrophoneAccess(after action: (@MainActor () -> Void)?) {
        guard microphonePermissionTask == nil else { return }
        microphonePermissionGeneration &+= 1
        let generation = microphonePermissionGeneration
        microphonePermissionTask = Task { [weak self] in
            let allowed = await Self.requestAccess(for: .audio)
            guard let self, !Task.isCancelled,
                  self.microphonePermissionGeneration == generation else { return }
            self.microphoneAuthorization = AVCaptureDevice.authorizationStatus(for: .audio)
            self.microphonePermissionTask = nil
            if allowed {
                self.lastError = nil
            } else {
                self.lastError = "Microphone access was denied. Enable AI Camera in System Settings → Privacy & Security → Microphone."
            }
            action?()
            self.reconcileDemand()
        }
    }

    private static func openPrivacySettings(pane: String) {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(pane)"
        ) else { return }
        NSWorkspace.shared.open(url)
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
