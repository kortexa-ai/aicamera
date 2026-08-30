import AICameraCore
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var configuration: ConfigurationController
    @ObservedObject private var loginItem: LoginItemController
    @State private var smartyAPIKey = ""
    @State private var smartyMessage: String?
    @State private var selectedAgentModel = ConfigurationController.smartyAgentModels[0]
    @State private var voicePipelineMode = VoicePipelineMode.separateModels
    @State private var realtimeBaseURL = ConfigurationController.openAIRealtimeBaseURL.absoluteString
    @State private var realtimeModel = ConfigurationController.defaultRealtimeModel
    @State private var realtimeVoice = ConfigurationController.defaultRealtimeVoice
    @State private var realtimeCredential = ""
    @State private var realtimeMessage: String?
    @State private var wakePhraseDraft: String

    init(model: AppModel) {
        self.model = model
        self.configuration = model.configurationController
        self.loginItem = model.loginItemController
        self._wakePhraseDraft = State(
            initialValue: model.configurationController.configuration.pipeline.conversation.wakePhrase
        )
    }

    var body: some View {
        TabView(selection: $model.selectedSettingsPage) {
            generalSettings
                .tabItem { Label("General", systemImage: "switch.2") }
                .tag(AICameraSettingsPage.general)

            advancedSettings
                .tabItem { Label("AI & Advanced", systemImage: "sparkles") }
                .tag(AICameraSettingsPage.advanced)

            maintenanceSettings
                .tabItem { Label("Privacy & Maintenance", systemImage: "hand.raised") }
                .tag(AICameraSettingsPage.maintenance)
        }
        .frame(width: 740, height: 540)
        .background(SettingsWindowLifecycle())
    }

    private var generalSettings: some View {
        ScrollViewReader { proxy in
            Form {
                if !configuration.isConfigurationUsable {
                    Section("Profile repair required") {
                        Text(configuration.validationMessage ?? "The saved profile is invalid.")
                            .foregroundStyle(.red)
                        Text("Open AI & Advanced, then import a valid profile or reset to defaults. Automatic camera and microphone capture is blocked until the profile is valid.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    Text("Only direct local hardware inputs are listed. Software, aggregate, network, unknown-transport, and Continuity devices are excluded.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Camera") {
                    Picker("Source", selection: optionalBinding(\.videoDeviceID)) {
                        Text("System Default").tag(String?.none)
                        ForEach(model.videoDevices) { device in
                            Text(device.name).tag(String?.some(device.id))
                        }
                    }
                    LabeledContent("Resolved input", value: model.cameraSourceText)
                    HStack(spacing: 16) {
                        Picker("Size", selection: resolutionBinding) {
                            Text("640 × 480").tag("640x480")
                            Text("1280 × 720").tag("1280x720")
                            Text("1920 × 1080").tag("1920x1080")
                        }
                        Picker("Frame rate", selection: intBinding(\.framesPerSecond)) {
                            Text("15 fps").tag(15)
                            Text("30 fps").tag(30)
                            Text("60 fps").tag(60)
                        }
                        Toggle("Mirror", isOn: boolBinding(\.mirrorVideo))
                    }
                    if let warning = model.cameraSourceWarning {
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                .id(AICameraSettingsLane.camera)
                .disabled(!configuration.isConfigurationUsable)

                Section("Microphone") {
                    Picker("Source", selection: optionalBinding(\.audioDeviceID)) {
                        Text("System Default").tag(String?.none)
                        ForEach(model.audioInputDevices) { device in
                            Text(device.name).tag(String?.some(device.id))
                        }
                    }
                    LabeledContent("Resolved input", value: model.microphoneSourceText)
                    LabeledContent("Proxy gain") {
                        HStack {
                            Slider(
                                value: doubleBinding(\.microphoneGain),
                                in: 0...2,
                                step: 0.05
                            )
                            .frame(width: 180)
                            Text(String(format: "%.2f×", configuration.configuration.capture.microphoneGain))
                                .monospacedDigit()
                                .frame(width: 48, alignment: .trailing)
                        }
                    }
                    if let warning = model.microphoneSourceWarning {
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                .id(AICameraSettingsLane.microphone)
                .disabled(!configuration.isConfigurationUsable)

                Section("Background operation") {
                    Toggle("Open AI Camera at login", isOn: Binding(
                        get: { loginItem.isEnabled },
                        set: { model.setOpenAtLogin($0) }
                    ))
                    if loginItem.requiresApproval {
                        HStack {
                            Text("macOS requires approval for this login item.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Open Login Items Settings") { loginItem.openSystemSettings() }
                        }
                    }
                }

                Section("Processing") {
                    LabeledContent("Mode") {
                        Label(
                            model.hasConfiguredAIFeatures
                                ? "AI features configured"
                                : (model.isPurePassthrough ? "Pure passthrough" : "AI off — local effects configured"),
                            systemImage: model.hasConfiguredAIFeatures ? "sparkles" : "arrow.left.arrow.right"
                        )
                    }
                    Text("Capture starts while another app uses the matching virtual device or while you run its local test. Valid changes apply automatically.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
        }
            .formStyle(.grouped)
            .padding()
            .onAppear {
                model.refreshDevicesAndDrivers()
                if let lane = model.selectedSettingsLane {
                    proxy.scrollTo(lane, anchor: .top)
                }
            }
            .onChange(of: model.settingsNavigationGeneration) { _, _ in
                guard model.selectedSettingsPage == .general,
                      let lane = model.selectedSettingsLane else { return }
                withAnimation { proxy.scrollTo(lane, anchor: .top) }
            }
        }
    }

    private var advancedSettings: some View {
        Form {
            Section("Profile") {
                if !configuration.isConfigurationUsable {
                    Text("The saved profile is invalid. Its original file was preserved.")
                        .foregroundStyle(.red)
                    Button("Reset to Pure Passthrough Defaults") {
                        configuration.resetToDefaults()
                        syncDrafts()
                    }
                }
                TextField("Name", text: profileNameBinding)
                HStack {
#if DEBUG
                    Button("Smarty Preset") {
                        configuration.applySmartyPreset()
                        syncDrafts()
                    }
#endif
                    Button("Import…") { importProfile() }
                    Button("Export…") { exportProfile() }
                    Button("Reload") {
                        configuration.reload()
                        syncDrafts()
                    }
                    Spacer()
                }
                Text(configuration.fileURL.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Section("Models on Smarty") {
                Picker("Conversation model", selection: $selectedAgentModel) {
                    ForEach(ConfigurationController.smartyAgentModels, id: \.self) { Text($0).tag($0) }
                }
                .disabled(usesRealtimeVoicePipeline)
                LabeledContent("Scene understanding", value: ConfigurationController.smartyVisionModel)
                LabeledContent("Object detection", value: ConfigurationController.smartyDetectionModel)
                LabeledContent("Speech recognition", value: ConfigurationController.smartyASRModel)
                    .disabled(usesRealtimeVoicePipeline)
                LabeledContent("Speech synthesis", value: ConfigurationController.smartySpeechModel)
                    .disabled(usesRealtimeVoicePipeline)
                SecureField("Kortexa API key (leave blank to keep the saved key)", text: $smartyAPIKey)
                HStack {
                    Button("Use Current Smarty Models") { saveSmartyConfiguration() }
                        .buttonStyle(.borderedProminent)
                    Spacer()
                    Text("Credential: macOS Keychain")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("These are the services verified as running on Smarty. The API key is needed only to authenticate AI requests through api.kortexa.ai; it is not used by passthrough, device installation, or maintenance.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let smartyMessage {
                    Text(smartyMessage).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }

            Section("Vision") {
                Toggle("Detect hand gestures locally", isOn: videoStageBinding(kind: .handGesture))
                Toggle("Detect objects with \(ConfigurationController.smartyDetectionModel)", isOn: videoStageBinding(kind: .objectDetection))
                    .disabled(!smartyModelsConfigured)
                Toggle("Describe scenes with \(ConfigurationController.smartyVisionModel)", isOn: videoStageBinding(kind: .visionLanguage))
                    .disabled(!smartyModelsConfigured)
                Toggle("Show gesture labels", isOn: overlayBoolBinding(\.showGestureLabels))
                Toggle("Show detection boxes", isOn: overlayBoolBinding(\.showDetectionBoxes))
            }

            Section("Conversation") {
                Picker("Voice pipeline", selection: $voicePipelineMode) {
                    ForEach(VoicePipelineMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .onChange(of: voicePipelineMode) { _, mode in
                    handleVoicePipelineSelection(mode)
                }
                Toggle("Enabled", isOn: conversationBoolBinding(\.enabled))
                    .disabled(!selectedVoicePipelineIsConfigured)
                Toggle("Transcribe microphone", isOn: conversationBoolBinding(\.transcriptionEnabled))
                    .disabled(separateVoiceControlsDisabled)
                Toggle("Agent replies", isOn: conversationBoolBinding(\.respondToFinalTranscripts))
                    .disabled(separateVoiceControlsDisabled)
                Toggle("Respond to gestures", isOn: conversationBoolBinding(\.respondToGestures))
                    .disabled(separateVoiceControlsDisabled || !videoStageIsEnabled(.handGesture))
                Picker("Voice", selection: speechVoiceBinding) {
                    Text("Adrian").tag("adrian")
                    Text("Archibald").tag("archibald")
                    Text("Avery").tag("avery")
                    Text("Mira").tag("mira")
                }
                .disabled(separateVoiceControlsDisabled)
                Picker("Activation", selection: conversationActivationBinding) {
                    Text("Wake phrase").tag(ConversationActivationMode.wakePhrase)
                    Text("Always listening").tag(ConversationActivationMode.alwaysListening)
                }
                .pickerStyle(.segmented)
                .disabled(separateVoiceControlsDisabled)
                HStack {
                    TextField("Wake phrase", text: $wakePhraseDraft)
                        .onSubmit { applyWakePhrase() }
                    Button("Apply") { applyWakePhrase() }
                        .disabled(wakePhraseDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .disabled(
                    separateVoiceControlsDisabled
                        || configuration.configuration.pipeline.conversation.activationMode != .wakePhrase
                )
                Stepper(
                    "Wake window: \(Int(configuration.configuration.pipeline.conversation.wakeWindowSeconds)) seconds",
                    value: conversationDoubleBinding(\.wakeWindowSeconds),
                    in: 1...30,
                    step: 1
                )
                .disabled(
                    separateVoiceControlsDisabled
                        || configuration.configuration.pipeline.conversation.activationMode != .wakePhrase
                )
                if usesRealtimeVoicePipeline {
                    Text("Realtime handles microphone input, response generation, and speech as one bounded session. The separate ASR, agent, and TTS controls are disabled.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if usesRealtimeVoicePipeline {
                Section("Realtime Voice") {
                    if voicePipelineMode == .openAIRealtime {
                        LabeledContent("Endpoint", value: ConfigurationController.openAIRealtimeBaseURL.absoluteString)
                    } else {
                        TextField("Compatible base URL", text: $realtimeBaseURL)
                    }
                    TextField("Model", text: $realtimeModel)
                    TextField("Voice", text: $realtimeVoice)
                    SecureField(
                        "API key or compatible bearer token (leave blank to keep the saved key)",
                        text: $realtimeCredential
                    )
                    HStack {
                        Button("Save Realtime Configuration") { saveRealtimeConfiguration() }
                            .buttonStyle(.borderedProminent)
                        Spacer()
                        Text("Credential: macOS Keychain")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text("Saving explicitly permits microphone audio, transcripts, prompts, and bounded scene metadata for this endpoint. Raw camera frames are not granted.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let realtimeMessage {
                        Text(realtimeMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }

            Section("Overlays") {
                Toggle("Enabled", isOn: overlayBoolBinding(\.enabled))
                Toggle("Show transcript", isOn: overlayBoolBinding(\.showTranscript))
                Toggle("Show agent response", isOn: overlayBoolBinding(\.showAgentResponse))
                Toggle("Show status", isOn: overlayBoolBinding(\.showStatus))
            }

            if let message = configuration.validationMessage {
                Section("Configuration error") {
                    Text(message).foregroundStyle(.red).textSelection(.enabled)
                }
            } else if let message = configuration.profileTransferMessage {
                Section { Text(message).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            syncDrafts()
        }
    }

    private var maintenanceSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Installed virtual devices").font(.headline)
            DeviceStatusRow(
                title: "AI Camera",
                status: model.cameraExtensionManager.status.label,
                ready: model.cameraExtensionManager.status == .active,
                busy: model.deviceOperationInProgress,
                actionTitle: cameraMaintenanceActionTitle,
                action: model.cameraExtensionManager.status == .active
                    ? model.deactivateCameraExtension
                    : model.activateCameraExtension
            )
            DeviceStatusRow(
                title: "AI Camera Microphone",
                status: model.audioDriverManager.status.label,
                ready: model.audioDriverManager.status == .installed,
                busy: model.deviceOperationInProgress,
                actionTitle: audioMaintenanceActionTitle,
                action: model.audioDriverManager.status == .installed
                    ? model.uninstallAudioDriver
                    : model.installAudioDriver
            )
            if model.cameraExtensionManager.status == .needsApproval {
                Button("Open Extension Settings") {
                    model.cameraExtensionManager.openApprovalSettings()
                }
                .controlSize(.small)
            }

            Divider()
            Text("Camera and microphone buffers stay in memory. The default profile performs pure passthrough and permits only loopback endpoints. Remote endpoints require HTTPS, an allowed host, and explicit data grants.")
                .foregroundStyle(.secondary)
            Text("AI credentials are managed beside the AI features that use them in AI & Advanced. Device maintenance does not need an endpoint secret.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding()
    }

    private var cameraMaintenanceActionTitle: String? {
        switch model.cameraExtensionManager.status {
        case .active: return "Remove"
        case .updateAvailable: return "Update"
        case .inactive, .failed(_): return "Install"
        default: return nil
        }
    }

    private var audioMaintenanceActionTitle: String? {
        switch model.audioDriverManager.status {
        case .installed: return "Remove"
        case .updateAvailable: return "Update"
        case .installedNeedsReload: return "Repair"
        case .notInstalled, .failed(_): return "Install"
        default: return nil
        }
    }

    private func saveSmartyConfiguration() {
        do {
            if !smartyAPIKey.isEmpty {
                try AppSecretResolver().store(
                    smartyAPIKey,
                    account: ConfigurationController.smartyCredentialAccount
                )
                smartyAPIKey = ""
            }
            configuration.configureSmartyModels(agentModel: selectedAgentModel)
            smartyMessage = configuration.validationMessage ?? "Smarty model configuration saved."
        } catch {
            smartyMessage = "Kortexa API credential save failed: \(error.localizedDescription)"
        }
    }

    private func syncSmartyDraft() {
        if let model = configuration.configuration.endpoints
            .first(where: { $0.id == "smarty-agent" })?.model,
           ConfigurationController.smartyAgentModels.contains(model) {
            selectedAgentModel = model
        }
    }

    private func syncRealtimeDraft() {
        let conversation = configuration.configuration.pipeline.conversation
        guard conversation.realtimeEnabled,
              let endpointID = conversation.realtimeEndpointID,
              let endpoint = configuration.configuration.endpoints.first(where: { $0.id == endpointID }) else {
            voicePipelineMode = .separateModels
            return
        }
        realtimeBaseURL = endpoint.baseURL.absoluteString
        realtimeModel = endpoint.model ?? ConfigurationController.defaultRealtimeModel
        realtimeVoice = endpoint.options["voice"]?.stringValue ?? ConfigurationController.defaultRealtimeVoice
        voicePipelineMode = endpoint.baseURL.host?.lowercased() == "api.openai.com"
            ? .openAIRealtime
            : .compatibleRealtime
    }

    private func handleVoicePipelineSelection(_ mode: VoicePipelineMode) {
        realtimeMessage = nil
        if mode == .openAIRealtime {
            realtimeBaseURL = ConfigurationController.openAIRealtimeBaseURL.absoluteString
            if realtimeModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                realtimeModel = ConfigurationController.defaultRealtimeModel
            }
        } else if mode == .separateModels,
                  configuration.configuration.pipeline.conversation.realtimeEnabled {
            configuration.update { $0.pipeline.conversation.realtimeEnabled = false }
        }
    }

    private func importProfile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        configuration.importProfile(from: url)
        syncDrafts()
    }

    private func exportProfile() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "AI Camera Profile.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        configuration.exportProfile(to: url)
    }

    private func saveRealtimeConfiguration() {
        let rawURL = voicePipelineMode == .openAIRealtime
            ? ConfigurationController.openAIRealtimeBaseURL.absoluteString
            : realtimeBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let baseURL = URL(string: rawURL), baseURL.host != nil else {
            realtimeMessage = "Enter a valid Realtime base URL."
            return
        }
        let model = realtimeModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let voice = realtimeVoice.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty, !voice.isEmpty else {
            realtimeMessage = "Enter both a Realtime model and voice."
            return
        }
        let endpointID = "openai-realtime"
        let credentialAccount = ConfigurationController.realtimeCredentialAccount(for: baseURL)
        do {
            if !realtimeCredential.isEmpty {
                try AppSecretResolver().store(
                    realtimeCredential,
                    account: credentialAccount
                )
                realtimeCredential = ""
            }
            let endpoint = EndpointConfiguration(
                id: endpointID,
                adapter: .openAIRealtime,
                baseURL: baseURL,
                model: model,
                auth: .init(
                    kind: .bearerKeychain,
                    reference: credentialAccount
                ),
                timeoutSeconds: 30,
                options: ["voice": .string(voice)]
            )
            configuration.update { profile in
                profile.endpoints.removeAll(where: { $0.id == endpointID })
                profile.endpoints.append(endpoint)
                profile.pipeline.conversation.enabled = true
                profile.pipeline.conversation.realtimeEnabled = true
                profile.pipeline.conversation.realtimeEndpointID = endpointID
                profile.pipeline.conversation.transcriptionEnabled = false
                profile.pipeline.conversation.respondToFinalTranscripts = false
                profile.pipeline.conversation.respondToGestures = false
                profile.privacy.grants.removeAll(where: { $0.endpointID == endpointID })
                if !EndpointLocation.isLoopback(baseURL), let host = baseURL.host?.lowercased() {
                    profile.privacy.networkMode = .allowListed
                    if !profile.privacy.allowedHosts.map({ $0.lowercased() }).contains(host) {
                        profile.privacy.allowedHosts.append(host)
                    }
                    profile.privacy.grants.append(.init(
                        endpointID: endpointID,
                        allowedData: [.rawAudio, .transcript, .promptText, .sceneMetadata]
                    ))
                }
            }
            realtimeMessage = configuration.validationMessage ?? "Realtime configuration saved."
        } catch {
            realtimeMessage = "Realtime credential save failed: \(error.localizedDescription)"
        }
    }

    private var profileNameBinding: Binding<String> {
        Binding(
            get: { configuration.configuration.profileName },
            set: { value in configuration.update { $0.profileName = value } }
        )
    }

    private var smartyModelsConfigured: Bool {
        let ids = Set(configuration.configuration.endpoints.map(\.id))
        return ["smarty-objects", "smarty-asr", "smarty-agent", "smarty-vision", "smarty-speech", "smarty-realtime"]
            .allSatisfy(ids.contains)
    }

    private var conversationEnabled: Bool {
        configuration.configuration.pipeline.conversation.enabled
    }

    private var usesRealtimeVoicePipeline: Bool {
        voicePipelineMode != .separateModels
    }

    private var selectedVoicePipelineIsConfigured: Bool {
        if voicePipelineMode == .separateModels { return smartyModelsConfigured }
        return configuration.configuration.pipeline.conversation.realtimeEndpointID != nil
    }

    private var separateVoiceControlsDisabled: Bool {
        !conversationEnabled || usesRealtimeVoicePipeline
    }

    private func videoStageIsEnabled(_ kind: VideoStageKind) -> Bool {
        configuration.configuration.pipeline.videoStages.first(where: { $0.kind == kind })?.enabled == true
    }

    private func videoStageBinding(kind: VideoStageKind) -> Binding<Bool> {
        Binding(
            get: { videoStageIsEnabled(kind) },
            set: { enabled in
                configuration.update { profile in
                    if let index = profile.pipeline.videoStages.firstIndex(where: { $0.kind == kind }) {
                        profile.pipeline.videoStages[index].enabled = enabled
                        return
                    }
                    let stage: VideoStageConfiguration
                    switch kind {
                    case .handGesture:
                        stage = .init(
                            id: "hands",
                            kind: .handGesture,
                            enabled: enabled,
                            maximumRateHz: 8,
                            maximumFrameAgeMilliseconds: 250
                        )
                    case .objectDetection:
                        stage = .init(
                            id: "objects",
                            kind: .objectDetection,
                            enabled: enabled,
                            endpointID: "smarty-objects",
                            maximumRateHz: 2,
                            maximumFrameAgeMilliseconds: 1_000,
                            options: ["confidence": .number(0.35)]
                        )
                    case .visionLanguage:
                        stage = .init(
                            id: "vision",
                            kind: .visionLanguage,
                            enabled: enabled,
                            endpointID: "smarty-vision",
                            maximumRateHz: 0.2,
                            maximumFrameAgeMilliseconds: 2_000,
                            prompt: "Describe only visual facts useful to a conversational camera assistant."
                        )
                    }
                    profile.pipeline.videoStages.append(stage)
                }
            }
        )
    }

    private func overlayBoolBinding(_ keyPath: WritableKeyPath<OverlayConfiguration, Bool>) -> Binding<Bool> {
        Binding(
            get: { configuration.configuration.overlays[keyPath: keyPath] },
            set: { value in configuration.update { $0.overlays[keyPath: keyPath] = value } }
        )
    }

    private var speechVoiceBinding: Binding<String> {
        Binding(
            get: { configuration.configuration.pipeline.conversation.speechVoice },
            set: { value in
                configuration.update { profile in
                    profile.pipeline.conversation.speechVoice = value
                    if let index = profile.endpoints.firstIndex(where: { $0.id == "smarty-realtime" }) {
                        profile.endpoints[index].options["voice"] = .string(value)
                    }
                }
            }
        )
    }

    private func optionalBinding(_ keyPath: WritableKeyPath<CaptureConfiguration, String?>) -> Binding<String?> {
        Binding(
            get: { configuration.configuration.capture[keyPath: keyPath] },
            set: { value in configuration.update { $0.capture[keyPath: keyPath] = value } }
        )
    }

    private func boolBinding(_ keyPath: WritableKeyPath<CaptureConfiguration, Bool>) -> Binding<Bool> {
        Binding(
            get: { configuration.configuration.capture[keyPath: keyPath] },
            set: { value in configuration.update { $0.capture[keyPath: keyPath] = value } }
        )
    }

    private func intBinding(_ keyPath: WritableKeyPath<CaptureConfiguration, Int>) -> Binding<Int> {
        Binding(
            get: { configuration.configuration.capture[keyPath: keyPath] },
            set: { value in configuration.update { $0.capture[keyPath: keyPath] = value } }
        )
    }

    private func doubleBinding(_ keyPath: WritableKeyPath<CaptureConfiguration, Double>) -> Binding<Double> {
        Binding(
            get: { configuration.configuration.capture[keyPath: keyPath] },
            set: { value in configuration.update { $0.capture[keyPath: keyPath] = value } }
        )
    }

    private func conversationBoolBinding(
        _ keyPath: WritableKeyPath<ConversationConfiguration, Bool>
    ) -> Binding<Bool> {
        Binding(
            get: { configuration.configuration.pipeline.conversation[keyPath: keyPath] },
            set: { value in
                configuration.update { $0.pipeline.conversation[keyPath: keyPath] = value }
            }
        )
    }

    private var conversationActivationBinding: Binding<ConversationActivationMode> {
        Binding(
            get: { configuration.configuration.pipeline.conversation.activationMode },
            set: { value in
                configuration.update { $0.pipeline.conversation.activationMode = value }
            }
        )
    }

    private func conversationDoubleBinding(
        _ keyPath: WritableKeyPath<ConversationConfiguration, Double>
    ) -> Binding<Double> {
        Binding(
            get: { configuration.configuration.pipeline.conversation[keyPath: keyPath] },
            set: { value in
                configuration.update { $0.pipeline.conversation[keyPath: keyPath] = value }
            }
        )
    }

    private func applyWakePhrase() {
        let phrase = wakePhraseDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phrase.isEmpty else { return }
        configuration.update { $0.pipeline.conversation.wakePhrase = phrase }
        syncWakePhraseDraft()
    }

    private func syncWakePhraseDraft() {
        wakePhraseDraft = configuration.configuration.pipeline.conversation.wakePhrase
    }

    private func syncDrafts() {
        syncWakePhraseDraft()
        syncSmartyDraft()
        syncRealtimeDraft()
    }

    private var resolutionBinding: Binding<String> {
        Binding(
            get: { "\(configuration.configuration.capture.width)x\(configuration.configuration.capture.height)" },
            set: { value in
                let parts = value.split(separator: "x").compactMap { Int($0) }
                guard parts.count == 2 else { return }
                configuration.update { $0.capture.width = parts[0]; $0.capture.height = parts[1] }
            }
        )
    }
}

private enum VoicePipelineMode: String, CaseIterable, Identifiable {
    case separateModels
    case openAIRealtime
    case compatibleRealtime

    var id: Self { self }

    var title: String {
        switch self {
        case .separateModels: return "Separate ASR + agent + TTS"
        case .openAIRealtime: return "OpenAI Realtime"
        case .compatibleRealtime: return "Compatible Realtime"
        }
    }
}

private struct SettingsWindowLifecycle: NSViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WindowTrackingView {
        let view = WindowTrackingView()
        view.onWindowChange = { window in context.coordinator.attach(to: window) }
        return view
    }

    func updateNSView(_ nsView: WindowTrackingView, context: Context) {}

    static func dismantleNSView(_ nsView: WindowTrackingView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator {
        private weak var window: NSWindow?
        private var closeObserver: NSObjectProtocol?

        func attach(to window: NSWindow?) {
            guard let window, self.window !== window else { return }
            detach(hideDock: false)
            self.window = window
            AppLifecycleCoordinator.shared.settingsDidOpen(window)
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            closeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                self?.detach()
            }
        }

        func detach(hideDock: Bool = true) {
            if let closeObserver {
                NotificationCenter.default.removeObserver(closeObserver)
                self.closeObserver = nil
            }
            if let window {
                AppLifecycleCoordinator.shared.settingsDidClose(window)
            }
            window = nil
            if hideDock {
                DispatchQueue.main.async { NSApp.setActivationPolicy(.accessory) }
            }
        }
    }
}

private final class WindowTrackingView: NSView {
    var onWindowChange: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?(window)
    }
}
