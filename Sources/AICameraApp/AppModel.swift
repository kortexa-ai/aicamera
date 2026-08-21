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
    private var realtimeSession: RealtimeWebRTCSession?
    private var realtimeEventTask: Task<Void, Never>?
    private var realtimeConnectTask: Task<Void, Never>?
    private var realtimeReceiveTailTask: Task<Void, Never>?
    private var realtimeResponseDonePending = false
    private var realtimeGeneration: UInt64 = 0
    private var realtimeSpeechID: UUID?
    private var realtimeAudioQueue: [Data] = []
    private var realtimeAudioQueueBytes = 0
    private var realtimeAudioSending = false
    private var realtimeAudioFinishRequested = false
    private var realtimeAudioSampleRate: Int?
    private var realtimeToolContinuationPending = false
    private var realtimeResponseDoneCount = 0

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
            && audioDriverManager.status.isInstalled
            && microphoneAuthorization == .authorized
            && microphoneSourceAvailable
    }

    var hasConfiguredAIFeatures: Bool {
        configurationController.configuration.pipeline.videoStages.contains(where: \.enabled)
            || configurationController.configuration.pipeline.conversation.enabled
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
            transcriptionEnabled: configuration.pipeline.conversation.enabled
                && configuration.pipeline.conversation.transcriptionEnabled
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
                    || configuration.pipeline.conversation.realtimeEnabled
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
        let gate = PipelineRunGate()
        let coordinator = PipelineCoordinator(
            configuration: configuration,
            secrets: AppSecretResolver(),
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
        if !microphoneTestActive {
            microphoneTestActive = true
            reconcileDemand()
        }
        guard microphoneRunGate?.isActive == true, audioController != nil else {
            lastError = "The microphone test could not start for Realtime output."
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

        realtimeGeneration &+= 1
        let generation = realtimeGeneration
        realtimeConversationState = .connecting
        realtimeReceiveTailTask?.cancel()
        realtimeReceiveTailTask = nil
        realtimeResponseDonePending = false
        realtimeToolContinuationPending = false
        realtimeResponseDoneCount = 0
        resetRealtimeAudio(stopPlayback: true)
        lastError = nil
        realtimeConnectTask = Task { [weak self] in
            guard let self else { return }
            do {
                guard let secret = try await AppSecretResolver().resolve(endpoint.auth), !secret.isEmpty else {
                    throw NSError(
                        domain: "AICamera.Realtime",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "The Realtime credential is missing from Keychain."]
                    )
                }
                guard !Task.isCancelled, generation == self.realtimeGeneration else { return }
                let signalingURL = try Self.realtimeSignalingURL(for: endpoint)
                let session = RealtimeWebRTCSession(
                    signalingURL: signalingURL,
                    credential: .init(field: endpoint.auth.header, value: endpoint.auth.prefix + secret)
                )
                self.realtimeSession = session
                self.realtimeEventTask = Task { [weak self, weak session] in
                    guard let self, let session else { return }
                    for await event in session.events {
                        guard !Task.isCancelled else { return }
                        await self.handleRealtimeEvent(event, session: session, generation: generation)
                    }
                }
                let request = Self.realtimeSessionRequest(
                    endpoint: endpoint,
                    conversation: conversation,
                    profile: profile
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
        realtimeReceiveTailTask?.cancel()
        realtimeReceiveTailTask = nil
        realtimeResponseDonePending = false
        let session = realtimeSession
        realtimeSession = nil
        realtimeConversationState = state
        realtimeToolContinuationPending = false
        realtimeResponseDoneCount = 0
        if stopSpeech {
            resetRealtimeAudio(stopPlayback: true)
        }
        Task { await session?.close() }
    }

    private func handleRealtimeEvent(
        _ event: RealtimeWebRTCSession.Event,
        session: RealtimeWebRTCSession,
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
            await session.closeMicrophoneGate()
        case .transcript:
            // Keep renderer and tool diagnostics visible in the compact UI.
            break
        case let .functionCall(call):
            realtimeToolContinuationPending = true
            await executeRealtimeTool(call, session: session, generation: generation)
        case .responseDone:
            realtimeResponseDoneCount += 1
            if !realtimeToolContinuationPending || realtimeResponseDoneCount >= 2 {
                scheduleRealtimeReceiveTail(session: session, generation: generation)
            }
        case let .error(failure):
            lastError = "Realtime: \(failure.rawValue)"
            closeRealtimeTransport(state: .failed, stopSpeech: true)
        case let .audio(chunk):
            enqueueRealtimeAudio(chunk)
            if realtimeResponseDonePending {
                scheduleRealtimeReceiveTail(session: session, generation: generation)
            }
        }
    }

    private func scheduleRealtimeReceiveTail(
        session: RealtimeWebRTCSession,
        generation: UInt64
    ) {
        realtimeResponseDonePending = true
        realtimeReceiveTailTask?.cancel()
        realtimeReceiveTailTask = Task { @MainActor [weak self, weak session] in
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return
            }
            guard let self, let session,
                  generation == self.realtimeGeneration,
                  session === self.realtimeSession else { return }
            self.realtimeReceiveTailTask = nil
            self.realtimeResponseDonePending = false
            guard self.realtimeSpeechID != nil else {
                self.closeRealtimeTransport(state: .idle, stopSpeech: false)
                return
            }
            self.realtimeAudioFinishRequested = true
            self.drainRealtimeAudioQueue()
        }
    }

    private func enqueueRealtimeAudio(_ chunk: RealtimeWebRTCSession.PCMChunk) {
        guard let audio = audioController,
              microphoneRunGate?.isActive == true,
              chunk.channels == 1,
              !chunk.data.isEmpty else { return }
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
        realtimeAudioQueue.append(chunk.data)
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
        _ call: RealtimeWebRTCSession.FunctionCall,
        session: RealtimeWebRTCSession,
        generation: UInt64
    ) async {
        let result: [String: Any]
        switch call.name {
        case "render_overlay":
            guard let arguments = call.arguments.data(using: .utf8),
                  arguments.count <= configurationController.configuration.overlays.script.maxScriptBytes + 1_024,
                  let object = try? JSONSerialization.jsonObject(with: arguments) as? [String: Any],
                  let script = object["script"] as? String else {
                result = ["ok": false, "error": "invalid render_overlay arguments"]
                break
            }
            let scriptConfiguration = configurationController.configuration.overlays.script
            let requestedTTL = (object["ttlSeconds"] as? NSNumber)?.doubleValue
            let ttl = min(
                scriptConfiguration.maximumTTLSeconds,
                max(1, requestedTTL?.isFinite == true ? requestedTTL! : scriptConfiguration.maximumTTLSeconds)
            )
            guard let renderer = scriptRenderer, cameraRunGate?.isActive == true else {
                result = ["ok": false, "error": "camera renderer unavailable; start the camera test"]
                break
            }
            if renderer.load(script: script, ttlSeconds: ttl) {
                overlayScriptLog = "Realtime overlay active"
                result = ["ok": true, "width": 640, "height": 360, "ttlSeconds": ttl]
            } else {
                result = ["ok": false, "error": "script rejected by host limits"]
            }
        case "clear_overlay":
            scriptRenderer?.clear()
            overlayScriptLog = "Overlay cleared by Realtime"
            result = ["ok": true]
        default:
            result = ["ok": false, "error": "unsupported client tool"]
        }
        guard generation == realtimeGeneration,
              session === realtimeSession,
              let outputData = try? JSONSerialization.data(withJSONObject: result),
              let output = String(data: outputData, encoding: .utf8) else { return }
        do {
            try await session.completeFunctionCall(
                callID: call.callID,
                output: output,
                continuation: ["tool_choice": "none"]
            )
        } catch {
            lastError = "Realtime tool result: \(error.localizedDescription)"
            closeRealtimeTransport(state: .failed, stopSpeech: true)
        }
    }

    private static func realtimeSignalingURL(for endpoint: EndpointConfiguration) throws -> URL {
        if let path = endpoint.path, !path.isEmpty {
            guard let url = URL(string: path, relativeTo: endpoint.baseURL)?.absoluteURL else {
                throw NSError(domain: "AICamera.Realtime", code: 2)
            }
            return url
        }
        if endpoint.baseURL.path.hasSuffix("/v1") {
            return endpoint.baseURL.appendingPathComponent("realtime/calls")
        }
        return endpoint.baseURL.appendingPathComponent("v1/realtime/calls")
    }

    private static func realtimeSessionRequest(
        endpoint: EndpointConfiguration,
        conversation: ConversationConfiguration,
        profile: AICameraConfiguration
    ) -> [String: Any] {
        let width = 640
        let height = 360
        let mirror = profile.capture.mirrorVideo ? "mirrored horizontally" : "not mirrored"
        var instructions = conversation.systemPrompt
        instructions += """

        Keep spoken replies concise. Use one short sentence unless the user asks for detail.
        You can control a transparent three.js overlay on the camera with the provided client tools.
        The overlay canvas is \(width)x\(height), origin is top-left in canvas pixels, and camera output is \(mirror).
        For every visual request, call render_overlay before claiming it is visible.
        The script runs immediately in an already-loaded page. Do not wait for DOMContentLoaded or another page event.
        THREE and window.AICamera are already available. Add meshes to AICamera.scene, position AICamera.camera, and use AICamera.onFrame(function(dt) { ... }) for animation.
        Follow this known-good pattern: const mesh = new THREE.Mesh(new THREE.TorusGeometry(1.2, 0.35, 32, 96), new THREE.MeshStandardMaterial({color: 0x8b5cf6})); AICamera.scene.add(mesh); AICamera.camera.position.set(0, 0, 5); AICamera.camera.lookAt(0, 0, 0); AICamera.onFrame(function(dt) { mesh.rotation.x += dt * 0.5; mesh.rotation.y += dt; });
        Adapt the geometry, material, position, and animation to the request, but preserve that host API structure.
        Do not create another canvas, scene, camera, renderer, render loop, or HTML document. Do not call requestAnimationFrame.
        Keep the existing renderer background transparent. Do not use network requests, external assets, recording, or persistence.
        A new render replaces the old one and expires automatically.
        """
        if conversation.includeSceneSummary {
            instructions += "\nCurrent clean scene context: \(profile.overlays.script.allowSceneData ? "bounded sceneData is available to the script" : "no script sceneData is enabled")."
        }
        let renderParameters: [String: Any] = [
            "type": "object",
            "properties": [
                "script": ["type": "string", "description": "Immediate JavaScript that adds objects to AICamera.scene and optionally registers AICamera.onFrame; do not create a renderer, canvas, DOM load handler, or requestAnimationFrame loop"],
                "ttlSeconds": ["type": "number", "minimum": 1, "maximum": profile.overlays.script.maximumTTLSeconds]
            ],
            "required": ["script"],
            "additionalProperties": false
        ]
        let clearParameters: [String: Any] = [
            "type": "object",
            "properties": [:],
            "additionalProperties": false
        ]
        return [
            "type": "realtime",
            "model": endpoint.model ?? "",
            "instructions": instructions,
            "audio": ["output": ["voice": endpoint.options["voice"]?.stringValue ?? ""]],
            "tool_choice": "auto",
            "tools": [
                [
                    "type": "function",
                    "name": "render_overlay",
                    "description": "Replace the live transparent camera overlay with bounded three.js JavaScript. Canvas is \(width)x\(height) and transparent.",
                    "parameters": renderParameters
                ],
                [
                    "type": "function",
                    "name": "clear_overlay",
                    "description": "Remove the current generated camera overlay.",
                    "parameters": clearParameters
                ]
            ]
        ]
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
