import AICameraCore
import AppKit
import AudioToolbox
import AVFoundation
import Combine
import Foundation
import OSLog

// The producer relinquishes the preview after invoking its callback; only the main actor uses it.
private struct SendableImage: @unchecked Sendable {
    let value: NSImage
}

enum RealtimeConversationState: String, Sendable {
    case idle = "Agent off"
    case connecting = "Connecting…"
    case listening = "Listening…"
    case paused = "Agent is not listening"
    case responding = "Responding…"
    case speaking = "Speaking…"
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
    private static let privacyMuteKey = "privacyMicrophoneMuted"
    private let runtimeFeatures = RuntimeFeatureState()
    private var appliedConfiguration: AICameraConfiguration?
    private var currentSnapshotFeatures = RuntimeFeatureState().snapshot
    @Published private(set) var transcriptionRequested = UserDefaults.standard.object(forKey: "quickTranscription") as? Bool ?? true
    @Published private(set) var translationRequested = UserDefaults.standard.object(forKey: "quickTranslation") as? Bool ?? true
    @Published private(set) var gesturesRequested = UserDefaults.standard.object(forKey: "quickGestures") as? Bool ?? true
    @Published private(set) var shortcutError: String?
    private var globalShortcuts: GlobalShortcuts?
    private let privacyMute: PrivacyMuteState
    @Published private(set) var privacyMuted: Bool
    private var privacyTransitionPending = false
    private var isTerminating = false
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
    @Published private(set) var realtimeConversationState: RealtimeConversationState = .idle {
        didSet {
            if oldValue != realtimeConversationState {
                realtimeLog.info("Agent state: \(self.realtimeConversationState.rawValue, privacy: .public)")
            }
            publishAgentStatus()
        }
    }
    private let realtimeLog = Logger(subsystem: "ai.kortexa.aicamera", category: "AgentActivation")

    let configurationController = ConfigurationController()
    let cameraExtensionManager = CameraExtensionManager()
    let audioDriverManager = AudioDriverManager()
    let demandMonitor = MediaDemandMonitor()
    let loginItemController = LoginItemController()
    let builtinVisionModelController = BuiltinVisionModelController()
    let builtinTranslationModelController = BuiltinTranslationModelController()
    let builtinWhisperModelController = BuiltinWhisperModelController()
    let codexAuthController = CodexAuthController()
    let agentNotes = AgentNotesController()
    private let agentPresentation = AgentPresentationState()
    @Published private(set) var cameraInsetRequested = false
    private var cameraLayoutID: UUID?
    private var cameraLayoutTask: Task<Void, Never>?

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
    private var cameraStartedAt: TimeInterval = 0
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
    @Published private(set) var agentListening = AgentListeningPolicy()
    private let realtimeInputGate = AgentInputGate()
    private var realtimeListeningTask: Task<Void, Never>?
    private var realtimeListeningRevision: UInt64 = 0
    private var realtimeEventTask: Task<Void, Never>?
    private var realtimeConnectTask: Task<Void, Never>?
    private var realtimeFinishTask: Task<Void, Never>?
    private var realtimeGeneration: UInt64 = 0
    private var realtimeMicrophoneRequested = false
    private var microphonePublishesToClient = false
    private var realtimeSpeechID: UUID?
    private var realtimeAudioQueue: [Data] = []
    private var realtimeAudioQueueBytes = 0
    private var realtimeAudioSending = false
    private var realtimeAudioFinishRequested = false
    private var realtimeAcceptingAudio = false
    private var realtimeAudioSampleRate: Int?
    private var realtimeToolTurn = AgentToolTurn()
    private var realtimeToolTask: Task<Void, Never>?
    private var realtimeQuietTurn = false

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
        isTerminating || isStopping || pipelineStopTask != nil
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
        !privacyMuted && !privacyTransitionPending && !externalClientIsUsingMedia && !deviceOperationInProgress
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

    var transcriptionConfigured: Bool { configurationController.configuration.pipeline.conversation.transcriptionEnabled }
    var translationConfigured: Bool {
        configurationController.configuration.pipeline.translation.enabled
            && (transcriptionConfigured || realtimeConversationEnabled)
    }
    var gesturesConfigured: Bool {
        configurationController.configuration.pipeline.videoStages.contains { $0.enabled && $0.kind == .handGesture }
    }
    var transcriptionActive: Bool { transcriptionConfigured && transcriptionRequested }
    var translationActive: Bool { translationConfigured && translationRequested }
    var translationTargetName: String {
        TranslationLanguageCatalog.name(for: configurationController.configuration.pipeline.translation.targetLanguage)
    }
    var gesturesActive: Bool { gesturesConfigured && gesturesRequested }

    var readiness: CameraReadiness {
        let configuration = configurationController.configuration
        let whisperMissing = transcriptionConfigured && configuration.pipeline.conversation.transcriptionProvider == .whisper
            && !builtinWhisperModelController.isReady(configuration.pipeline.conversation.transcriptionWhisperModel)
        let attention = currentError != nil || shortcutError != nil || !configurationController.isConfigurationUsable
            || !cameraVirtualDeviceIsReady || audioDriverManager.status != .installed
            || cameraAuthorization != .authorized || microphoneAuthorization != .authorized
            || !cameraSourceAvailable || !microphoneSourceAvailable || whisperMissing
            || (translationConfigured && !builtinTranslationModelController.isReady)
        return .resolve(needsAttention: attention, isInUse: cameraIsActive || microphoneIsActive)
    }

    var readinessDescription: String {
        switch readiness {
        case .needsAttention: return "Needs attention — check device setup and Settings"
        case .ready: return "Ready"
        case .inUse: return privacyMuted ? "Camera in use · microphone muted" : statusText
        }
    }

    func toggleTranscription() {
        guard transcriptionConfigured else { return }
        transcriptionRequested.toggle()
        UserDefaults.standard.set(transcriptionRequested, forKey: "quickTranscription")
        synchronizeRuntimeFeatures()
    }

    func toggleTranslation() {
        guard translationConfigured else { return }
        translationRequested.toggle()
        UserDefaults.standard.set(translationRequested, forKey: "quickTranslation")
        synchronizeRuntimeFeatures()
    }

    func toggleGestures() {
        guard gesturesConfigured else { return }
        gesturesRequested.toggle()
        UserDefaults.standard.set(gesturesRequested, forKey: "quickGestures")
        synchronizeRuntimeFeatures()
    }

    private func synchronizeRuntimeFeatures() {
        let previous = runtimeFeatures.snapshot
        let translation = configurationController.configuration.pipeline.translation
        let features = runtimeFeatures.set(transcription: transcriptionActive,
                                           translation: translationActive, gestures: gesturesActive,
                                           translationSourceLanguage: translation.sourceLanguage,
                                           translationTargetLanguage: translation.targetLanguage)
        guard features != previous else { return }
        currentSnapshot = runtimeFeatures.filtered(currentSnapshot, from: currentSnapshotFeatures)
        previewImage = nil
        publishAgentStatus()
        pushSceneData(to: currentSnapshot)
        let coordinator = pipeline
        Task { await coordinator?.synchronizeRuntimeFeatures() }
    }

    func stopLocalTests() {
        guard cameraTestActive || microphoneTestActive else { return }
        cameraTestActive = false
        microphoneTestActive = false
        microphoneInputLevel = 0
        reconcileDemand()
    }

    var realtimeConversationEnabled: Bool {
        let conversation = configurationController.configuration.pipeline.conversation
        return conversation.enabled && conversation.realtimeEnabled && conversation.realtimeEndpointID != nil
    }

    var realtimeConversationActive: Bool {
        realtimeConversationState != .idle && realtimeConversationState != .failed
    }

    var canStartRealtimeConversation: Bool {
        realtimeConversationEnabled && !realtimeConversationActive
            && !privacyMuted && !privacyTransitionPending && !deviceOperationInProgress
            && configurationController.isConfigurationUsable
            && microphoneAuthorization == .authorized && microphoneSourceAvailable
            && realtimeConnectTask == nil
    }

    private var agentOverlayStatus: AgentOverlayStatus? {
        if privacyMuted { return .muted }
        guard realtimeConversationEnabled else { return nil }
        switch realtimeConversationState {
        case .idle: return .off
        case .connecting: return .connecting
        case .listening: return .listening
        case .paused: return .paused
        case .responding: return .thinking
        case .speaking: return .speaking
        case .failed: return .failed
        }
    }

    private func publishAgentStatus() {
        currentSnapshot.agentStatus = agentOverlayStatus
        videoController?.update(snapshot: currentSnapshot, privacy: privacyMute.snapshot, features: currentSnapshotFeatures)
    }

    var isPurePassthrough: Bool {
        !hasConfiguredAIFeatures
            && !configurationController.configuration.capture.mirrorVideo
            && !configurationController.configuration.overlays.enabled
    }

    init() {
        let muted = UserDefaults.standard.bool(forKey: Self.privacyMuteKey)
        privacyMuted = muted
        privacyMute = PrivacyMuteState(isMuted: muted)
        appliedConfiguration = configurationController.configuration
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

        builtinWhisperModelController.objectWillChange
            .merge(with: builtinTranslationModelController.objectWillChange)
            .merge(with: builtinVisionModelController.objectWillChange)
            .sink { [weak self] _ in self?.objectWillChange.send() }
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
            .sink { [weak self] next in
                guard let self else { return }
                let change = self.appliedConfiguration.map { ConfigurationChangePolicy.classify(from: $0, to: next) } ?? .restartMedia
                self.appliedConfiguration = next
                guard change != .unchanged else { return }
                self.synchronizeRuntimeFeatures()
                guard change == .restartMedia else { return }
                self.cameraLaneError = nil
                self.microphoneLaneError = nil
                self.refreshResolvedSources()
                self.beginStop()
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

        AppLifecycleCoordinator.shared.prepareForTermination = { [weak self] in
            await self?.prepareForTermination()
        }

        synchronizeRuntimeFeatures()
        let shortcuts = GlobalShortcuts { [weak self] action in
            guard let self, !self.isTerminating else { return }
            switch action {
            case .agent: self.toggleRealtimeConversation()
            case .mute: self.setPrivacyMuted(!self.privacyMuted)
            case .agentInput: self.toggleAgentListening()
            }
        }
        globalShortcuts = shortcuts
        shortcutError = shortcuts.register()
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

    /// Privacy is independent of configuration, client demand, and agent activation.
    func setPrivacyMuted(_ muted: Bool) {
        guard muted != privacyMuted else { return }
        let privacy = privacyMute.setMuted(muted)
        privacyMuted = muted
        privacyTransitionPending = true
        UserDefaults.standard.set(muted, forKey: Self.privacyMuteKey)
        microphoneRunGate?.cancel()
        audioController?.silenceForPrivacy()
        microphoneTestActive = false
        microphoneInputLevel = 0
        stopRealtimeConversation()
        currentSnapshot = privacyMute.filtered(currentSnapshot, from: privacy)
        // Unmute also starts with an empty speech scene.
        currentSnapshot.transcript = nil
        currentSnapshot.agentResponse = nil
        previewImage = nil
        videoController?.update(snapshot: currentSnapshot, privacy: privacy, features: currentSnapshotFeatures)
        clearOverlayScript()
        agentPresentation.clear()
        pushSceneData(to: currentSnapshot)
        reconcileDemand()
        let coordinator = pipeline
        Task { [weak self] in
            await coordinator?.synchronizePrivacy(privacy)
            guard let self, self.privacyMute.isCurrent(privacy) else { return }
            self.privacyTransitionPending = false
            self.reconcileDemand()
        }
    }

    private func reconcileDemand() {
        guard !isTerminating else { return }
        if MediaDemandDecision.agentRequiresRouteRestart(
            previousPublication: audioController == nil ? nil : microphonePublishesToClient,
            clientRequested: demandMonitor.microphoneRequested, agentRequested: realtimeMicrophoneRequested
        ) {
            // A change of call routing needs a fresh graph. Stop the agent explicitly while the
            // demand-driven lanes rebuild; never reuse local-test audio in a new call.
            beginStop()
            return
        }
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
            microphoneAvailable: audioDriverManager.status.isInstalled
                || (realtimeMicrophoneRequested && !demandMonitor.microphoneRequested),
            microphoneAuthorized: microphoneAuthorization == .authorized,
            agentMicrophoneRequested: realtimeMicrophoneRequested,
            microphoneMuted: privacyMuted || privacyTransitionPending
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
        let privacyGate = privacyMute
        Task { await coordinator.resetGestureControls() }
        let video = VideoPipelineController(
            configuration: configuration,
            privacyMute: privacyGate,
            runtimeFeatures: runtimeFeatures,
            onPreview: { [weak self] image, privacy, features in
                guard pipelineGate.isActive, laneGate.isActive else { return }
                let sendableImage = SendableImage(value: image)
                Task { @MainActor [weak model = self, sendableImage] in
                    guard pipelineGate.isActive, laneGate.isActive, privacyGate.isCurrent(privacy),
                          let model, model.runtimeFeatures.snapshot == features else { return }
                    model.previewImage = sendableImage.value
                }
            },
            onGestures: { observations, frameID, capturedAt in
                guard pipelineGate.isActive, laneGate.isActive else { return }
                Task {
                    guard pipelineGate.isActive, laneGate.isActive else { return }
                    await coordinator.submit(gestures: observations, frameID: frameID, capturedAt: capturedAt)
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
            scriptRenderer: scriptRenderer,
            agentPresentation: agentPresentation
        )

        do {
            cameraStartedAt = ProcessInfo.processInfo.systemUptime
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
            privacyMute: privacyMute,
            utteranceSeconds: configuration.pipeline.conversation.utteranceSeconds,
            transcriptionEnabled: configuration.pipeline.conversation.transcriptionEnabled
                && (configuration.pipeline.conversation.transcriptionProvider == .whisper
                    || configuration.pipeline.conversation.transcriptionEndpointID != nil),
            runtimeFeatures: runtimeFeatures,
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
            microphonePublishesToClient = demandMonitor.microphoneRequested
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
            privacyMute: privacyMute,
            runtimeFeatures: runtimeFeatures,
            onSnapshotWithFeatures: { [weak self] snapshot, privacy, features in
                guard gate.isActive else { return }
                Task { @MainActor [weak model = self] in
                    guard gate.isActive, let model, model.privacyMute.isCurrent(privacy) else { return }
                    model.currentSnapshot = model.runtimeFeatures.filtered(snapshot, from: features)
                    model.currentSnapshotFeatures = features
                    model.currentSnapshot.agentStatus = model.agentOverlayStatus
                    if model.cameraRunGate?.isActive == true {
                        model.videoController?.update(snapshot: model.currentSnapshot, privacy: privacy, features: features)
                        model.pushSceneData(to: model.currentSnapshot)
                    }
                }
            },
            onGestureControlWithTimestamp: { [weak self] action, capturedAt in
                Task { @MainActor [weak model = self] in
                    guard gate.isActive, let model, model.cameraRunGate?.isActive == true,
                          capturedAt >= model.cameraStartedAt, model.runtimeFeatures.permitsGesture(capturedAt: capturedAt),
                          ProcessInfo.processInfo.systemUptime - capturedAt <= 0.5 else { return }
                    switch action {
                    case .mute: model.setPrivacyMuted(true)
                    case .startAgent:
                        model.realtimeLog.info("Held victory admitted from camera stream")
                        guard !model.realtimeConversationActive else { return }
                        if model.privacyMuted {
                            model.lastError = "Unmute AI Camera before starting the agent."
                        } else { model.startRealtimeConversation() }
                    }
                }
            },
            builtinDetectionClient: builtinVisionModelController.makeDetectionClient(
                modelID: builtinDetectionModelID
            ),
            builtinTranslationClient: configuration.pipeline.translation.enabled
                ? builtinTranslationModelController.makeTranslationClient()
                : nil,
            builtinTranscriptionClient: configuration.pipeline.conversation.transcriptionProvider == .whisper
                ? builtinWhisperModelController.makeTranscriptionClient(model: configuration.pipeline.conversation.transcriptionWhisperModel)
                : nil,
            onSpeechWithPrivacy: { [weak self] event, privacy in
                guard gate.isActive else { return false }
                return await withCheckedContinuation { continuation in
                    Task { @MainActor [weak model = self] in
                        guard gate.isActive, let model, model.privacyMute.permitsSpeech(privacy),
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

    /// Checks a saved credential and model without opening capture or sending a user utterance.
    func testRealtimeConnection(authentication: RealtimeAuthentication, model: String, voice: String) async throws {
        let secret: String?
        if authentication == .codex { secret = try await codexAuthController.realtimeCredential() }
        else {
            secret = try await AppSecretResolver().resolve(.init(
                kind: .bearerKeychain, reference: ConfigurationController.openAICredentialAccount
            ))
        }
        try Task.checkCancellation()
        guard let secret, !secret.isEmpty else { throw RealtimeSessionFailure.invalidCredential }
        let endpoint = EndpointConfiguration(
            id: "connection-test", adapter: .openAIRealtime,
            baseURL: ConfigurationController.openAIRealtimeBaseURL,
            model: model, options: ["voice": .string(voice)]
        )
        let session = RealtimeConversationSession(signalingURL: endpoint.baseURL, credential: .init(value: "Bearer " + secret))
        let request = RealtimeSessionConfiguration.request(
            endpoint: endpoint, conversation: .init(), profile: .default, toolsAvailable: false
        )
        do {
            try await session.connect(session: request)
            await session.close()
        } catch {
            await session.close()
            throw error
        }
    }

    func toggleRealtimeConversation() {
        if realtimeConversationActive {
            stopRealtimeConversation()
        } else {
            startRealtimeConversation()
        }
    }

    /// Pause only agent input. The current reply and the microphone sent to a call keep working.
    func toggleAgentListening() {
        guard !privacyMuted, realtimeConversationActive,
              realtimeConversationState != .connecting, let session = realtimeSession else { return }
        agentListening.setRequested(!agentListening.requested)
        realtimeListeningRevision &+= 1
        let requested = agentListening.requested
        let generation = realtimeGeneration
        let previous = realtimeListeningTask
        if !agentListening.requested { realtimeInputGate.close() }
        realtimeListeningTask = Task { @MainActor [weak self, weak session] in
            await previous?.value
            guard let self, let session, !Task.isCancelled, generation == self.realtimeGeneration,
                  session === self.realtimeSession else { return }
            if requested {
                guard self.agentListening.requested else { return }
                if self.realtimeConversationState == .paused { self.rearmRealtimeConversation() }
            } else {
                do {
                    try await session.pauseInputAudio()
                    guard generation == self.realtimeGeneration else { return }
                    if self.realtimeConversationState == .listening || self.realtimeConversationState == .paused {
                        self.enterAgentListeningPause()
                    }
                } catch {
                    guard generation == self.realtimeGeneration else { return }
                    self.lastError = "Agent input could not pause. The agent has been stopped."
                    self.closeRealtimeTransport(state: .failed, stopSpeech: true)
                }
            }
        }
    }

    private func attachRealtimeInput(to session: any RealtimeConversationClient) {
        audioController?.setRealtimeAudioHandler { [weak session, inputGate = realtimeInputGate] data, capturedAt in
            guard inputGate.admits(capturedAt: capturedAt) else { return }
            session?.appendInputPCM(data, capturedAt: capturedAt)
        }
    }

    private func enterAgentListeningPause() {
        realtimeInputGate.close()
        realtimeFinishTask?.cancel()
        realtimeFinishTask = nil
        realtimeConversationState = .paused
        audioController?.setRealtimeAudioHandler(nil)
        let coordinator = pipeline
        let generation = realtimeGeneration
        Task { [weak self] in
            guard let self, generation == self.realtimeGeneration, !self.agentListening.requested else { return }
            await coordinator?.setRealtimeTranscriptionActive(false)
        }
    }

    func startRealtimeConversation() {
        guard canStartRealtimeConversation else {
            lastError = "Realtime conversation is not configured or the microphone is unavailable."
            if !realtimeConversationActive { realtimeConversationState = .failed }
            return
        }
        let profile = configurationController.configuration
        let conversation = profile.pipeline.conversation
        guard let endpointID = conversation.realtimeEndpointID,
              let endpoint = profile.endpoints.first(where: { $0.id == endpointID }),
              endpoint.adapter == .openAIRealtime else {
            lastError = "The Realtime endpoint is missing."
            realtimeConversationState = .failed
            return
        }
        do {
            var dataClasses: Set<MediaDataClass> = [.rawAudio, .transcript, .promptText]
            if conversation.includeSceneSummary { dataClasses.insert(.sceneMetadata) }
            try PrivacyGate(configuration: profile.privacy).authorize(endpoint: endpoint, data: dataClasses)
        } catch {
            lastError = "Realtime privacy gate: \(error.localizedDescription)"
            realtimeConversationState = .failed
            return
        }
        realtimeMicrophoneRequested = true
        realtimeConversationState = .connecting
        reconcileDemand()
        guard microphoneRunGate?.isActive == true, let audioController else {
            realtimeMicrophoneRequested = false
            realtimeConversationState = .failed
            lastError = "The microphone could not start for the agent."
            reconcileDemand()
            return
        }
        do { try audioController.enableLocalSpeechPlayback() }
        catch {
            lastError = error.localizedDescription
            closeRealtimeTransport(state: .failed, stopSpeech: true)
            return
        }
        let coordinator = pipeline

        agentListening.start(mode: conversation.agentListeningMode)
        realtimeInputGate.close()
        realtimeGeneration &+= 1
        let generation = realtimeGeneration
        realtimeConversationState = .connecting
        realtimeFinishTask?.cancel()
        realtimeFinishTask = nil
        realtimeToolTurn = AgentToolTurn()
        realtimeQuietTurn = false
        resetRealtimeAudio(stopPlayback: true)
        realtimeAcceptingAudio = true
        lastError = nil
        realtimeConnectTask = Task { [weak self] in
            guard let self else { return }
            do {
                await coordinator?.setRealtimeTranscriptionActive(true)
                try Task.checkCancellation()
                let signalingURL = try Self.realtimeSignalingURL(for: endpoint)
                let secret: String?
                if conversation.realtimeAuthentication == .codex {
                    secret = try await self.codexAuthController.realtimeCredential()
                } else {
                    secret = try await AppSecretResolver().resolve(endpoint.auth)
                }
                guard let secret, !secret.isEmpty else {
                    throw NSError(
                        domain: "AICamera.Realtime",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "The Realtime credential is missing from Keychain."]
                    )
                }
                guard !Task.isCancelled, generation == self.realtimeGeneration else { return }
                let session = RealtimeConversationSession(
                    signalingURL: signalingURL,
                    credential: conversation.realtimeAuthentication == .codex
                        ? .init(value: "Bearer " + secret)
                        : .init(field: endpoint.auth.header, value: endpoint.auth.prefix + secret)
                )
                self.attachRealtimeInput(to: session)
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
                    toolsAvailable: profile.overlays.script.enabled && self.cameraRunGate?.isActive == true,
                    agentTools: AgentToolCapabilities(
                        visuals: profile.overlays.script.enabled && self.cameraRunGate?.isActive == true,
                        notes: profile.overlays.script.enabled, conversationControls: true,
                        cameraState: profile.overlays.script.enabled,
                        translation: profile.overlays.script.enabled && self.translationConfigured
                    )
                )
                try await session.connect(session: request)
                guard !Task.isCancelled, generation == self.realtimeGeneration else {
                    await session.close()
                    return
                }
                try await session.armConversationAudio()
                guard !Task.isCancelled, generation == self.realtimeGeneration,
                      session === self.realtimeSession, !self.privacyMuted else {
                    await session.close()
                    return
                }
                self.realtimeConversationState = .listening
                self.realtimeInputGate.open()
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

    func stopRealtimeConversation(reconcileMedia: Bool = true) {
        closeRealtimeTransport(state: .idle, stopSpeech: true, reconcileMedia: reconcileMedia)
    }

    private func closeRealtimeTransport(
        state: RealtimeConversationState,
        stopSpeech: Bool,
        reconcileMedia: Bool = true
    ) {
        realtimeGeneration &+= 1
        realtimeListeningRevision &+= 1
        realtimeListeningTask?.cancel()
        realtimeListeningTask = nil
        agentListening.stop()
        realtimeInputGate.close()
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
        realtimeToolTask?.cancel()
        realtimeToolTask = nil
        realtimeToolTurn = AgentToolTurn()
        realtimeQuietTurn = false
        if stopSpeech {
            resetRealtimeAudio(stopPlayback: true)
        }
        // Close the transport before re-enabling independent transcription.
        // A new Talk invalidates this cleanup before it can unmute the fallback lane.
        let coordinator = pipeline
        let generation = realtimeGeneration
        Task { [weak self] in
            if stopSpeech, self?.realtimeGeneration == generation {
                await coordinator?.cancelRealtimeCaptions()
            }
            await session?.close()
            guard let self, self.realtimeGeneration == generation else { return }
            await coordinator?.setRealtimeTranscriptionActive(false)
        }
        audioController?.disableLocalSpeechPlayback()
        let hadAgentDemand = realtimeMicrophoneRequested
        realtimeMicrophoneRequested = false
        if hadAgentDemand && reconcileMedia { reconcileDemand() }
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
            if agentListening.requested { realtimeConversationState = .listening }
        case .speechStopped:
            realtimeInputGate.close()
            agentListening.utteranceEnded()
            realtimeConversationState = .responding
        case let .transcript(source, text, isFinal):
            if realtimeQuietTurn, case .remote = source { return }
            await pipeline?.submitRealtimeTranscript(source: source, text: text, isFinal: isFinal)
        case let .functionCall(call):
            guard realtimeToolTurn.admit(callID: call.callID) else {
                lastError = "The agent reached its tool limit. Start it again to continue."
                closeRealtimeTransport(state: .failed, stopSpeech: true)
                return
            }
            let previous = realtimeToolTask
            realtimeToolTask = Task { @MainActor [weak self, weak session] in
                await previous?.value
                guard let self, let session, !Task.isCancelled, generation == self.realtimeGeneration else { return }
                await self.executeRealtimeTool(call, session: session, generation: generation)
            }
        case .responseDone:
            realtimeToolTurn.endedResponse()
            await advanceRealtimeToolTurn(session: session, generation: generation)
        case let .error(failure):
            lastError = failure.localizedDescription
            closeRealtimeTransport(state: .failed, stopSpeech: true)
        case let .audio(chunk):
            guard !realtimeQuietTurn else { return }
            enqueueRealtimeAudio(chunk)
        }
    }

    private func advanceRealtimeToolTurn(session: any RealtimeConversationClient, generation: UInt64) async {
        guard generation == realtimeGeneration, session === realtimeSession else { return }
        switch realtimeToolTurn.takeNext() {
        case .waiting: break
        case .finish: finishRealtimeResponse(session: session, generation: generation)
        case let .continueResponse(allowTools):
            do { try await session.requestContinuation(["tool_choice": allowTools ? "auto" : "none"]) }
            catch {
                guard generation == realtimeGeneration else { return }
                lastError = error.localizedDescription
                closeRealtimeTransport(state: .failed, stopSpeech: true)
            }
        }
    }

    private func finishRealtimeResponse(
        session: any RealtimeConversationClient,
        generation: UInt64
    ) {
        guard generation == realtimeGeneration, session === realtimeSession else { return }
        realtimeAcceptingAudio = false
        if realtimeSpeechID == nil {
            rearmRealtimeConversation()
        } else {
            realtimeFinishTask?.cancel()
            realtimeFinishTask = Task { @MainActor [weak self, weak session] in
                try? await Task.sleep(for: .seconds(125))
                guard !Task.isCancelled, let self, let session, generation == self.realtimeGeneration,
                      session === self.realtimeSession, self.realtimeSpeechID != nil else { return }
                self.lastError = "Agent reply playback timed out."
                self.closeRealtimeTransport(state: .failed, stopSpeech: true)
            }
            realtimeAudioFinishRequested = true
            drainRealtimeAudioQueue()
        }
    }

    /// The same server conversation keeps context; input opens only after both reply outputs drain.
    private func rearmRealtimeConversation() {
        guard realtimeMicrophoneRequested, !privacyMuted, let session = realtimeSession else { return }
        guard agentListening.requested else { enterAgentListeningPause(); return }
        let generation = realtimeGeneration
        let revision = realtimeListeningRevision
        // Keep user controls accurate while the asynchronous input transition is pending.
        realtimeConversationState = .paused
        realtimeToolTurn = AgentToolTurn()
        realtimeQuietTurn = false
        realtimeFinishTask?.cancel()
        realtimeFinishTask = Task { @MainActor [weak self, weak session] in
            guard let self, let session, generation == self.realtimeGeneration,
                  session === self.realtimeSession else { return }
            self.resetRealtimeAudio(stopPlayback: false)
            do {
                await self.pipeline?.setRealtimeTranscriptionActive(true)
                guard !Task.isCancelled, generation == self.realtimeGeneration,
                      revision == self.realtimeListeningRevision, self.agentListening.requested else { return }
                self.attachRealtimeInput(to: session)
                try await session.armConversationAudio()
                guard !Task.isCancelled, generation == self.realtimeGeneration,
                      revision == self.realtimeListeningRevision, self.agentListening.requested,
                      self.realtimeMicrophoneRequested, !self.privacyMuted else { return }
                self.realtimeAcceptingAudio = true
                self.realtimeConversationState = .listening
                self.realtimeInputGate.open()
                self.realtimeFinishTask = nil
            } catch {
                guard generation == self.realtimeGeneration, revision == self.realtimeListeningRevision,
                      !Task.isCancelled else { return }
                self.lastError = "Realtime: \(error.localizedDescription)"
                self.closeRealtimeTransport(state: .failed, stopSpeech: true)
            }
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
        realtimeConversationState = .speaking
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
                        self.rearmRealtimeConversation()
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
        guard generation == realtimeGeneration, session === realtimeSession, !privacyMuted else { return }
        let result = await applyRealtimeTool(call)
        guard !Task.isCancelled, generation == realtimeGeneration, session === realtimeSession else { return }
        guard let outputData = try? JSONSerialization.data(withJSONObject: result),
              let output = String(data: outputData, encoding: .utf8) else { return }
        do {
            try await session.completeFunctionCall(
                callID: call.callID,
                output: output
            )
            guard generation == realtimeGeneration, session === realtimeSession else { return }
            if call.name == "sleep_agent", result["ok"] as? Bool == true {
                stopRealtimeConversation()
                return
            }
            realtimeToolTurn.completed(callID: call.callID, quiet: realtimeQuietTurn)
            await advanceRealtimeToolTurn(session: session, generation: generation)
        } catch {
            guard generation == realtimeGeneration, session === realtimeSession else { return }
            lastError = "Realtime tool result: \(error.localizedDescription)"
            closeRealtimeTransport(state: .failed, stopSpeech: true)
        }
    }

    private func applyRealtimeTool(_ call: RealtimeFunctionCall) async -> [String: Any] {
        let configuration = configurationController.configuration.overlays.script
        guard let command = AgentToolCommand.parse(name: call.name, arguments: call.arguments, script: configuration) else {
            return ["ok": false, "error": "Unknown tool or invalid arguments."]
        }
        switch command {
        case .resetView:
            guard configuration.enabled else { return ["ok": false, "error": "Tools are disabled in Settings."] }
            resetAgentView()
            return ["ok": true, "cameraLayout": "camera"]
        case let .cameraInset(request):
            guard configuration.enabled, cameraRunGate?.isActive == true, let renderer = scriptRenderer else {
                return ["ok": false, "error": "Presentation requires enabled Tools and an active camera."]
            }
            let capture = configurationController.configuration.capture
            guard let insetFrame = request.frame(in: CGSize(width: capture.width, height: capture.height)) else {
                return ["ok": false, "error": "The camera output is too small for an inset with readable captions."]
            }
            // Tool work can wait for the renderer; capture keeps publishing the normal camera.
            let generation = realtimeGeneration
            let deadline = ProcessInfo.processInfo.systemUptime + 3
            while renderer.latestFreshOverlay() == nil, !Task.isCancelled, generation == realtimeGeneration,
                  ProcessInfo.processInfo.systemUptime < deadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard !Task.isCancelled, generation == realtimeGeneration, !privacyMuted,
                  cameraRunGate?.isActive == true, renderer === scriptRenderer,
                  configurationController.configuration.overlays.script.enabled else {
                return ["ok": false, "error": "The presentation request was cancelled."]
            }
            guard renderer.latestFreshOverlay() != nil, let inset = agentPresentation.showCameraInset(request) else {
                return ["ok": false, "error": "Render a scene first, then request the camera inset."]
            }
            cameraLayoutTask?.cancel()
            cameraLayoutID = inset.id
            cameraInsetRequested = true
            cameraLayoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(request.ttlSeconds))
                guard !Task.isCancelled, let self, self.cameraLayoutID == inset.id else { return }
                self.clearOverlayScript()
            }
            return ["ok": true, "cameraLayout": "inset", "position": request.position.rawValue,
                    "widthFraction": insetFrame.width / CGFloat(capture.width), "ttlSeconds": request.ttlSeconds]
        case .cameraState:
            guard configuration.enabled else { return ["ok": false, "error": "Tools are disabled in Settings."] }
            return cameraToolState()
        case let .setTranslation(request):
            guard configuration.enabled, translationConfigured else {
                return ["ok": false, "error": "Enable caption translation and Tools in Settings first."]
            }
            guard request.enabled != true || builtinTranslationModelController.isReady else {
                return ["ok": false, "error": "The translation model is not ready. Download it in Settings first."]
            }
            if let target = request.targetLanguage {
                configurationController.update { $0.pipeline.translation.targetLanguage = target }
                guard configurationController.configuration.pipeline.translation.targetLanguage == target else {
                    return ["ok": false, "error": configurationController.validationMessage ?? "The language could not be saved."]
                }
            }
            if let enabled = request.enabled {
                translationRequested = enabled
                UserDefaults.standard.set(enabled, forKey: "quickTranslation")
            }
            synchronizeRuntimeFeatures()
            return cameraToolState()
        case .waitForUser, .sleep:
            realtimeQuietTurn = true
            resetRealtimeAudio(stopPlayback: true)
            return ["ok": true]
        case let .saveNote(text, id):
            guard configuration.enabled else { return ["ok": false, "error": "Notes tools are disabled in Settings."] }
            do {
                let note = try await agentNotes.save(text: text, id: id)
                return ["ok": true, "id": note.id.uuidString, "visibility": "local notebook"]
            } catch { return ["ok": false, "error": error.localizedDescription] }
        case let .listNotes(query):
            guard configuration.enabled else { return ["ok": false, "error": "Notes tools are disabled in Settings."] }
            do {
                let notes = try await agentNotes.store.all().filter { query.isEmpty || $0.text.localizedCaseInsensitiveContains(query) }
                let formatter = ISO8601DateFormatter()
                let values = notes.prefix(5).map { ["id": $0.id.uuidString, "text": $0.text, "updatedAt": formatter.string(from: $0.updatedAt)] }
                return ["ok": true, "notes": values, "hasMore": notes.count > 5]
            } catch { return ["ok": false, "error": error.localizedDescription] }
        case let .deleteNote(id):
            guard configuration.enabled else { return ["ok": false, "error": "Notes tools are disabled in Settings."] }
            do { try await agentNotes.delete(id: id); return ["ok": true] }
            catch { return ["ok": false, "error": error.localizedDescription] }
        case let .showCard(request):
            guard configuration.enabled, cameraRunGate?.isActive == true else {
                return ["ok": false, "error": "Visual tools require enabled Tools and an active camera."]
            }
            guard let card = agentPresentation.show(request) else { return ["ok": false, "error": "The card exceeds display limits."] }
            return ["ok": true, "id": card.id.uuidString, "ttlSeconds": request.ttlSeconds, "visibility": "outgoing camera"]
        case .clearCards:
            guard configuration.enabled else { return ["ok": false, "error": "Visual tools are disabled in Settings."] }
            agentPresentation.clear()
            return ["ok": true]
        case let .overlay(command):
            return applyRealtimeOverlay(command)
        }
    }

    private func cameraToolState() -> [String: Any] {
        let translation = configurationController.configuration.pipeline.translation
        return ["ok": true, "translation": [
            "configured": translationConfigured, "enabled": translationActive,
            "modelReady": builtinTranslationModelController.isReady,
            "sourceLanguage": translation.sourceLanguage, "targetLanguage": translation.targetLanguage,
            "output": "captions"
        ], "privacyMuted": privacyMuted, "agentListeningRequested": agentListening.requested,
            "cameraLayout": agentPresentation.cameraInset() != nil && scriptRenderer?.latestFreshOverlay() != nil ? "inset" : "camera"]
    }

    private func applyRealtimeOverlay(_ command: RealtimeOverlayCommand) -> [String: Any] {
        guard configurationController.configuration.overlays.script.enabled,
              let renderer = scriptRenderer, cameraRunGate?.isActive == true else {
            return ["ok": false, "error": "Overlay tools require enabled Tools and an active camera lane."]
        }
        switch command {
        case let .render(script, ttl):
            guard renderer.load(script: script, ttlSeconds: ttl) else {
                return ["ok": false, "error": "Script rejected by host limits."]
            }
            overlayScriptLog = "Realtime overlay active"
            return ["ok": true, "width": 640, "height": 360, "ttlSeconds": ttl]
        case .clear:
            clearOverlayScript()
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
        resetCameraLayout()
        agentPresentation.clear()
    }

    /// Dev/acceptance entry point: run a pasted overlay script on the live
    /// camera test. Realtime invokes the same renderer through validated tools.
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
        resetCameraLayout()
        overlayScriptLog = "Overlay cleared."
    }

    func resetAgentView() {
        clearOverlayScript()
        agentPresentation.reset()
    }

    private func resetCameraLayout() {
        cameraLayoutTask?.cancel()
        cameraLayoutTask = nil
        cameraLayoutID = nil
        agentPresentation.clearCameraInset()
        cameraInsetRequested = false
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
        if realtimeConversationActive { stopRealtimeConversation(reconcileMedia: false) }
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
        stopRealtimeConversation(reconcileMedia: false)
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

    func prepareForTermination() async {
        globalShortcuts?.unregister()
        guard !isTerminating else { return }
        isTerminating = true
        // Close admission immediately without changing the saved user mute preference.
        privacyMute.setMuted(true)
        lifecycleCancellables.removeAll()
        managerCancellables.removeAll()
        audioController?.silenceForPrivacy()
        stopRealtimeConversation()
        codexAuthController.stop()
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
        let coordinator = pipeline
        pipeline = nil
        await coordinator?.stop()
        // A configuration/client transition can already own the retiring pipeline.
        await stopTask?.value
        await pipelineStopTask?.value
        await builtinWhisperModelController.shutdown()
        await builtinTranslationModelController.shutdown()
        builtinVisionModelController.shutdown()
    }

    private func updateStatus() {
        publishAgentStatus()
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
