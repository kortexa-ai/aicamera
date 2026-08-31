import AICameraCore
import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var configuration: ConfigurationController
    @ObservedObject private var loginItem: LoginItemController
    @ObservedObject private var builtinVision: BuiltinVisionModelController
    @ObservedObject private var builtinTranslation: BuiltinTranslationModelController
    @State private var voicePipelineMode = VoicePipelineMode.openAIRealtime
    @State private var realtimeBaseURL = ConfigurationController.openAIRealtimeBaseURL.absoluteString
    @State private var realtimeModel = ConfigurationController.defaultRealtimeModel
    @State private var realtimeVoice = ConfigurationController.defaultRealtimeVoice
    @State private var realtimeCredential = ""
    @State private var realtimeCredentialSummary: String?
    @State private var realtimeMessage: String?
    @State private var useHermes = false
    @State private var conversationDraftEnabled: Bool

    init(model: AppModel) {
        self.model = model
        self.configuration = model.configurationController
        self.loginItem = model.loginItemController
        self.builtinVision = model.builtinVisionModelController
        self.builtinTranslation = model.builtinTranslationModelController
        self._conversationDraftEnabled = State(
            initialValue: model.configurationController.configuration.pipeline.conversation.enabled
        )
    }

    var body: some View {
        TabView(selection: $model.selectedSettingsPage) {
            generalSettings
                .tabItem { Label("General", systemImage: "switch.2") }
                .tag(AICameraSettingsPage.general)

            advancedSettings
                .tabItem { Label("AI", systemImage: "sparkles") }
                .tag(AICameraSettingsPage.advanced)

            maintenanceSettings
                .tabItem { Label("Privacy", systemImage: "hand.raised") }
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
                        Text("Open AI, then reset to safe defaults. Automatic camera and microphone capture is blocked until the profile is valid.")
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

                Section("Virtual Devices") {
                    virtualDeviceControls
                }
        }
            .formStyle(.grouped)
            .toggleStyle(.switch)
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
            if !configuration.isConfigurationUsable {
                Section("Configuration repair") {
                    Text("The saved configuration is invalid. Its original file was preserved.")
                        .foregroundStyle(.red)
                    Button("Reset to Safe Defaults") {
                        configuration.resetToDefaults()
                        syncDrafts()
                    }
                }
            }

            Section {
                if conversationEnabled {
                    Picker("Setup", selection: $voicePipelineMode) {
                        Text("Realtime").tag(VoicePipelineMode.openAIRealtime)
                        Text("Advanced").tag(VoicePipelineMode.compatibleRealtime)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: voicePipelineMode) { _, mode in handleVoicePipelineSelection(mode) }

                    if voicePipelineMode == .openAIRealtime {
                        LabeledContent("Service", value: "OpenAI Realtime")
                    } else {
                        TextField("Compatible base URL", text: $realtimeBaseURL)
                        Toggle("Use Hermes", isOn: $useHermes)
                            .onChange(of: useHermes) { _, enabled in
                                if enabled { realtimeModel = ConfigurationController.hermesRealtimeModel }
                            }
                    }
                    Picker("Model", selection: $realtimeModel) {
                        ForEach(realtimeModelChoices, id: \.self) { Text($0).tag($0) }
                    }
                    Picker("Voice", selection: $realtimeVoice) {
                        ForEach(realtimeVoiceChoices, id: \.self) { Text($0.capitalized).tag($0) }
                    }
                    if let realtimeCredentialSummary {
                        LabeledContent("API key") {
                            HStack(spacing: 8) {
                                Text(realtimeCredentialSummary).monospaced()
                                Button(role: .destructive) { removeRealtimeCredential() } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                                .help("Remove saved API key")
                            }
                        }
                    }
                    SecureField(
                        realtimeCredentialSummary == nil ? "Add API key" : "Replace API key",
                        text: $realtimeCredential
                    )
                    HStack {
                        Button(realtimeCredentialSummary == nil ? "Save & Enable" : "Save Changes") {
                            saveRealtimeConfiguration()
                        }
                            .buttonStyle(.borderedProminent)
                        Spacer()
                        Text("Stored in macOS Keychain")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text("Realtime handles listening and spoken replies in one low-latency session. Raw camera frames are never sent by this configuration.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let realtimeMessage {
                        Text(realtimeMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            } header: {
                settingsHeader("Conversation", enabled: conversationEnabledBinding)
            }

            Section {
                if transcriptionDisplayEnabled {
                    Toggle("Translate", isOn: translationEnabledBinding)
                        .disabled(!builtinTranslation.isReady)
                    builtinTranslationControls
                    if translationEnabled {
                        Picker("From", selection: translationStringBinding(\.sourceLanguage)) {
                            ForEach(Self.sourceLanguages, id: \.code) { language in
                                Text(language.name).tag(language.code)
                            }
                        }
                        Picker("To", selection: translationStringBinding(\.targetLanguage)) {
                            ForEach(Self.targetLanguages, id: \.code) { language in
                                Text(language.name).tag(language.code)
                            }
                        }
                        Text("Translation runs on finalized transcript text and never blocks the live audio path.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                settingsHeader("Transcription", enabled: transcriptionDisplayEnabledBinding)
            }

            Section {
                if toolsEnabled {
                    Text("Realtime can currently draw and clear bounded overlays. Screenshot and camera controls will appear here as they become available.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                settingsHeader("Tools", enabled: toolsEnabledBinding)
            }

            Section {
                if visionEnabled {
                    builtinVisionControls
                    Toggle("Gestures", isOn: videoStageBinding(kind: .handGesture))
                    if videoStageIsEnabled(.handGesture) {
                        Toggle("Show gesture labels", isOn: overlayBoolBinding(\.showGestureLabels))
                    }
                    DisclosureGroup("Advanced endpoint") {
                        Text("Custom vision endpoint, model, and Keychain credential settings are coming in a later update.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                settingsHeader("Vision & Gestures", enabled: visionEnabledBinding)
            }

            Section {
                if overlaysEnabled {
                    Toggle("Show transcript", isOn: overlayBoolBinding(\.showTranscript))
                    Toggle("Show agent response", isOn: overlayBoolBinding(\.showAgentResponse))
                    Toggle("Show status", isOn: overlayBoolBinding(\.showStatus))
                    Toggle("Show detection boxes", isOn: overlayBoolBinding(\.showDetectionBoxes))
                    Toggle("Show gesture labels", isOn: overlayBoolBinding(\.showGestureLabels))
                }
            } header: {
                settingsHeader("Overlays", enabled: overlayBoolBinding(\.enabled))
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
        .toggleStyle(.switch)
        .onAppear {
            syncDrafts()
        }
    }

    @ViewBuilder
    private var builtinVisionControls: some View {
        switch builtinVision.state {
        case .notDownloaded:
            LabeledContent("Built-in object detection") {
                Button("Download \(BuiltinVisionModelController.modelName) · 9 MB") {
                    builtinVision.download()
                }
            }
        case .downloading:
            LabeledContent("Built-in object detection") {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Downloading…").foregroundStyle(.secondary)
                }
            }
        case .ready:
            HStack {
                Toggle(
                    "Built-in object detection · \(BuiltinVisionModelController.modelName)",
                    isOn: builtinObjectDetectionBinding
                )
                Spacer()
                Button(role: .destructive) { removeBuiltinVisionModel() } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Remove downloaded model")
            }
        case .failed(let message):
            LabeledContent("Built-in object detection") {
                Button("Try Download Again") { builtinVision.download() }
            }
            Text(message).font(.caption).foregroundStyle(.red)
        }
        Text("Apple's compact YOLOv3 Tiny model runs entirely on this Mac; camera frames are not uploaded.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var builtinTranslationControls: some View {
        switch builtinTranslation.state {
        case .notDownloaded:
            LabeledContent("Local model") {
                Button("Download \(BuiltinTranslationModelController.modelName) · \(BuiltinTranslationModelController.downloadSize)") {
                    builtinTranslation.download()
                }
            }
            Text("The model weights are downloaded only when requested. Tencent HY-MT2 is Apache 2.0 licensed, supports multilingual translation, and runs locally.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .downloading:
            LabeledContent("Local model") {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Downloading \(BuiltinTranslationModelController.downloadSize)…")
                        .foregroundStyle(.secondary)
                    Button("Cancel") { builtinTranslation.cancelDownload() }
                        .controlSize(.small)
                }
            }
        case .ready:
            LabeledContent("Local model") {
                HStack(spacing: 8) {
                    Label(BuiltinTranslationModelController.modelName, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Button(role: .destructive) { removeBuiltinTranslationModel() } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove downloaded model")
                }
            }
        case .failed(let message):
            LabeledContent("Local model") {
                Button("Try Download Again") { builtinTranslation.download() }
            }
            Text(message).font(.caption).foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var virtualDeviceControls: some View {
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
    }

    @ViewBuilder
    private var privacyContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Data processing").font(.headline)
            Text("AI Camera keeps camera and microphone data in memory while it is in use. It passes media from your selected hardware devices to the AI Camera virtual devices and does not save recordings.")
            if activeLocalProcessingDescriptions.isEmpty && configuredDataRoutes.isEmpty {
                Text("No AI features are currently processing camera or microphone data.")
            } else {
                ForEach(activeLocalProcessingDescriptions, id: \.self) { description in
                    Label(description, systemImage: "desktopcomputer")
                }
                ForEach(activeLoopbackRoutes, id: \.description) { route in
                    Label(route.description, systemImage: "desktopcomputer")
                }
                ForEach(activeExternalRoutes, id: \.description) { route in
                    Label(route.description, systemImage: "network")
                }
            }
        }

        Divider()

        VStack(alignment: .leading, spacing: 8) {
            Text("Data collection and AI training").font(.headline)
            Text("AI Camera does not collect analytics or user data. Camera frames, microphone audio, transcripts, AI prompts and responses, and API keys are not collected by AI Camera or used for AI training.")
            Text("External services configured in AI may have their own data collection, retention, and AI training policies.")
        }

        if !advancedExternalRoutes.isEmpty {
            DisclosureGroup("Advanced data routes") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(advancedExternalRoutes, id: \.description) { route in
                        LabeledContent(route.feature, value: route.destination)
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    private var maintenanceSettings: some View {
        Form {
            Section {
                privacyContent
            }
        }
        .formStyle(.grouped)
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

    private func syncRealtimeDraft() {
        let conversation = configuration.configuration.pipeline.conversation
        guard conversation.realtimeEnabled,
              let endpointID = conversation.realtimeEndpointID,
              let endpoint = configuration.configuration.endpoints.first(where: { $0.id == endpointID }) else {
            voicePipelineMode = .openAIRealtime
            realtimeBaseURL = ConfigurationController.openAIRealtimeBaseURL.absoluteString
            realtimeCredentialSummary = AppSecretResolver().maskedSecret(
                account: ConfigurationController.realtimeCredentialAccount
            )
            conversationDraftEnabled = conversation.enabled
            return
        }
        realtimeBaseURL = endpoint.baseURL.absoluteString
        realtimeModel = endpoint.model ?? ConfigurationController.defaultRealtimeModel
        realtimeVoice = endpoint.options["voice"]?.stringValue ?? ConfigurationController.defaultRealtimeVoice
        useHermes = endpoint.options["kortexaAgent"]?.stringValue == "hermes"
        voicePipelineMode = endpoint.baseURL.host?.lowercased() == "api.openai.com"
            ? .openAIRealtime
            : .compatibleRealtime
        realtimeCredentialSummary = AppSecretResolver().maskedSecret(
            account: ConfigurationController.realtimeCredentialAccount(for: endpoint.baseURL)
        )
        conversationDraftEnabled = conversation.enabled
    }

    private func handleVoicePipelineSelection(_ mode: VoicePipelineMode) {
        realtimeMessage = nil
        if mode == .openAIRealtime {
            realtimeBaseURL = ConfigurationController.openAIRealtimeBaseURL.absoluteString
            if realtimeModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                realtimeModel = ConfigurationController.defaultRealtimeModel
            }
            useHermes = false
        } else if realtimeBaseURL == ConfigurationController.openAIRealtimeBaseURL.absoluteString {
            realtimeBaseURL = ConfigurationController.kortexaRealtimeURL.absoluteString
            realtimeModel = ConfigurationController.hermesRealtimeModel
        }
        refreshRealtimeCredentialSummary()
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
        guard realtimeCredentialSummary != nil || !realtimeCredential.isEmpty else {
            realtimeMessage = "Add an API key to enable Realtime."
            return
        }
        do {
            if !realtimeCredential.isEmpty {
                try AppSecretResolver().store(
                    realtimeCredential,
                    account: credentialAccount
                )
                realtimeCredential = ""
            }
            var options: [String: JSONValue] = ["voice": .string(voice)]
            if voicePipelineMode == .compatibleRealtime,
               baseURL.host?.lowercased() == "api.kortexa.ai" {
                options["kortexaAgent"] = .string(useHermes ? "hermes" : "api")
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
                options: options
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
            realtimeCredentialSummary = AppSecretResolver().maskedSecret(account: credentialAccount)
            conversationDraftEnabled = true
            realtimeMessage = configuration.validationMessage ?? "Realtime configuration saved."
        } catch {
            realtimeMessage = "Realtime credential save failed: \(error.localizedDescription)"
        }
    }

    private var conversationEnabled: Bool { conversationDraftEnabled }


    private var realtimeModelChoices: [String] {
        ([realtimeModel] + ConfigurationController.realtimeModels).reduce(into: []) {
            if !$0.contains($1) { $0.append($1) }
        }
    }

    private var realtimeVoiceChoices: [String] {
        ([realtimeVoice] + ConfigurationController.realtimeVoices).reduce(into: []) {
            if !$0.contains($1) { $0.append($1) }
        }
    }

    private var overlaysEnabled: Bool { configuration.configuration.overlays.enabled }
    private var toolsEnabled: Bool { configuration.configuration.overlays.script.enabled }
    private var transcriptionDisplayEnabled: Bool {
        configuration.configuration.overlays.enabled
            && configuration.configuration.overlays.showTranscript
    }
    private var translationEnabled: Bool { configuration.configuration.pipeline.translation.enabled }
    private var visionEnabled: Bool {
        configuration.configuration.pipeline.videoStages.contains(where: \.enabled)
    }

    private var transcriptionDisplayEnabledBinding: Binding<Bool> {
        Binding(
            get: { transcriptionDisplayEnabled },
            set: { enabled in
                configuration.update { profile in
                    profile.overlays.showTranscript = enabled
                    if enabled {
                        profile.overlays.enabled = true
                    } else {
                        profile.pipeline.translation.enabled = false
                    }
                }
            }
        )
    }

    private var translationEnabledBinding: Binding<Bool> {
        Binding(
            get: { translationEnabled },
            set: { enabled in
                guard !enabled || builtinTranslation.isReady else { return }
                configuration.update { $0.pipeline.translation.enabled = enabled }
            }
        )
    }

    private var conversationEnabledBinding: Binding<Bool> {
        Binding(
            get: { conversationDraftEnabled },
            set: { enabled in
                conversationDraftEnabled = enabled
                if !enabled {
                    configuration.update { $0.pipeline.conversation.enabled = false }
                }
            }
        )
    }

    private var toolsEnabledBinding: Binding<Bool> {
        Binding(
            get: { toolsEnabled },
            set: { value in configuration.update { $0.overlays.script.enabled = value } }
        )
    }

    private var visionEnabledBinding: Binding<Bool> {
        Binding(
            get: { visionEnabled },
            set: { enabled in
                configuration.update { profile in
                    if enabled {
                        if let index = profile.pipeline.videoStages.firstIndex(where: { $0.kind == .handGesture }) {
                            profile.pipeline.videoStages[index].enabled = true
                        } else {
                            profile.pipeline.videoStages.append(.init(
                                id: "hands", kind: .handGesture, maximumRateHz: 8,
                                maximumFrameAgeMilliseconds: 250
                            ))
                        }
                    } else {
                        for index in profile.pipeline.videoStages.indices {
                            profile.pipeline.videoStages[index].enabled = false
                        }
                    }
                }
            }
        )
    }

    private func settingsHeader(_ title: String, enabled: Binding<Bool>) -> some View {
        HStack {
            Text(title)
            Spacer()
            Toggle("Enabled", isOn: enabled)
                .labelsHidden()
                .controlSize(.small)
                .toggleStyle(.switch)
        }
    }

    private func refreshRealtimeCredentialSummary() {
        let url = voicePipelineMode == .openAIRealtime
            ? ConfigurationController.openAIRealtimeBaseURL
            : URL(string: realtimeBaseURL)
        guard let url else {
            realtimeCredentialSummary = nil
            return
        }
        realtimeCredentialSummary = AppSecretResolver().maskedSecret(
            account: ConfigurationController.realtimeCredentialAccount(for: url)
        )
    }

    private func removeRealtimeCredential() {
        let url = voicePipelineMode == .openAIRealtime
            ? ConfigurationController.openAIRealtimeBaseURL
            : URL(string: realtimeBaseURL)
        guard let url else { return }
        do {
            try AppSecretResolver().remove(
                account: ConfigurationController.realtimeCredentialAccount(for: url)
            )
            realtimeCredentialSummary = nil
            configuration.update { $0.pipeline.conversation.enabled = false }
            conversationDraftEnabled = false
            realtimeMessage = "API key removed. Conversation was disabled."
        } catch {
            realtimeMessage = "API key removal failed: \(error.localizedDescription)"
        }
    }

    private var builtinObjectDetectionBinding: Binding<Bool> {
        Binding(
            get: {
                configuration.configuration.pipeline.videoStages.contains {
                    $0.kind == .objectDetection
                        && $0.options["provider"]?.stringValue == "builtin"
                        && $0.enabled
                }
            },
            set: { enabled in
                configuration.update { profile in
                    if let index = profile.pipeline.videoStages.firstIndex(where: {
                        $0.kind == .objectDetection && $0.options["provider"]?.stringValue == "builtin"
                    }) {
                        profile.pipeline.videoStages[index].enabled = enabled
                    } else {
                        profile.pipeline.videoStages.append(.init(
                            id: "builtin-objects",
                            kind: .objectDetection,
                            enabled: enabled,
                            maximumRateHz: 5,
                            maximumFrameAgeMilliseconds: 500,
                            options: [
                                "provider": .string("builtin"),
                                "confidence": .number(0.35),
                            ]
                        ))
                    }
                    if enabled {
                        profile.overlays.enabled = true
                        profile.overlays.showDetectionBoxes = true
                    }
                }
            }
        )
    }

    private func removeBuiltinVisionModel() {
        if builtinObjectDetectionBinding.wrappedValue {
            builtinObjectDetectionBinding.wrappedValue = false
        }
        builtinVision.remove()
    }

    private func removeBuiltinTranslationModel() {
        if translationEnabled {
            translationEnabledBinding.wrappedValue = false
        }
        builtinTranslation.remove()
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

    private func translationStringBinding(
        _ keyPath: WritableKeyPath<TranslationConfiguration, String>
    ) -> Binding<String> {
        Binding(
            get: { configuration.configuration.pipeline.translation[keyPath: keyPath] },
            set: { value in
                configuration.update { $0.pipeline.translation[keyPath: keyPath] = value }
            }
        )
    }

    private var activeLocalProcessingDescriptions: [String] {
        var descriptions: [String] = []
        let stages = configuration.configuration.pipeline.videoStages
        if stages.contains(where: {
            $0.enabled && $0.kind == .objectDetection && $0.options["provider"]?.stringValue == "builtin"
        }) {
            descriptions.append("Built-in vision processes video frames in app memory. Frames are not sent to an external service.")
        }
        if stages.contains(where: { $0.enabled && $0.kind == .handGesture }) {
            descriptions.append("Gesture recognition processes video frames in app memory. Frames are not sent to an external service.")
        }
        if translationEnabled {
            descriptions.append("Built-in translation processes finalized transcript text in app memory. Text is not sent to an external service.")
        }
        return descriptions
    }

    private var activeExternalRoutes: [PrivacyRoute] {
        configuredDataRoutes.filter { !$0.isLoopback }
    }

    private var activeLoopbackRoutes: [PrivacyRoute] {
        configuredDataRoutes.filter(\.isLoopback)
    }

    private var advancedExternalRoutes: [PrivacyRoute] {
        configuredDataRoutes.filter { $0.host != "api.openai.com" }
    }

    private var configuredDataRoutes: [PrivacyRoute] {
        let profile = configuration.configuration
        var routes: [PrivacyRoute] = []
        let conversation = profile.pipeline.conversation
        if conversation.enabled, conversation.realtimeEnabled,
           let endpoint = endpoint(withID: conversation.realtimeEndpointID) {
            let destination = endpoint.hostDisplayName
            let description = endpoint.baseURL.host?.lowercased() == "api.openai.com"
                ? "Conversation sends microphone audio to OpenAI Realtime. OpenAI processes it under the API data controls for the organization and project associated with your API key."
                : "Conversation sends microphone audio to \(destination), using the service configured in AI."
            routes.append(.init(
                feature: "Conversation",
                destination: destination,
                description: description,
                host: endpoint.baseURL.host?.lowercased(),
                isLoopback: EndpointLocation.isLoopback(endpoint.baseURL)
            ))
        }
        if conversation.enabled, conversation.transcriptionEnabled,
           let endpoint = endpoint(withID: conversation.transcriptionEndpointID) {
            routes.append(.init(
                feature: "Transcription",
                destination: endpoint.hostDisplayName,
                description: "Transcription sends microphone audio to \(endpoint.hostDisplayName).",
                host: endpoint.baseURL.host?.lowercased(),
                isLoopback: EndpointLocation.isLoopback(endpoint.baseURL)
            ))
        }
        if conversation.enabled, let endpoint = endpoint(withID: conversation.agentEndpointID) {
            routes.append(.init(
                feature: "Advanced conversation agent",
                destination: endpoint.hostDisplayName,
                description: "The advanced conversation agent sends transcript text and enabled scene context to \(endpoint.hostDisplayName).",
                host: endpoint.baseURL.host?.lowercased(),
                isLoopback: EndpointLocation.isLoopback(endpoint.baseURL)
            ))
        }
        if conversation.enabled, let endpoint = endpoint(withID: conversation.speechEndpointID) {
            routes.append(.init(
                feature: "Advanced speech",
                destination: endpoint.hostDisplayName,
                description: "Advanced speech sends agent response text to \(endpoint.hostDisplayName).",
                host: endpoint.baseURL.host?.lowercased(),
                isLoopback: EndpointLocation.isLoopback(endpoint.baseURL)
            ))
        }
        for stage in profile.pipeline.videoStages where stage.enabled && stage.endpointID != nil {
            guard stage.options["provider"]?.stringValue != "builtin",
                  let endpoint = endpoint(withID: stage.endpointID) else { continue }
            let feature = stage.kind == .visionLanguage ? "Vision" : "Object detection"
            routes.append(.init(
                feature: feature,
                destination: endpoint.hostDisplayName,
                description: "\(feature) sends video frames to \(endpoint.hostDisplayName).",
                host: endpoint.baseURL.host?.lowercased(),
                isLoopback: EndpointLocation.isLoopback(endpoint.baseURL)
            ))
        }
        var seen = Set<String>()
        return routes.filter { seen.insert("\($0.feature)|\($0.destination)").inserted }
    }

    private func endpoint(withID id: String?) -> EndpointConfiguration? {
        guard let id else { return nil }
        return configuration.configuration.endpoints.first(where: { $0.id == id })
    }

    private func syncDrafts() {
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

    private static let sourceLanguages = [LanguageChoice(code: "auto", name: "Auto-detect")] + modelLanguages
    private static let targetLanguages = [LanguageChoice(code: "system", name: "System Language")] + modelLanguages
    private static let modelLanguages = [
        LanguageChoice(code: "en", name: "English"), LanguageChoice(code: "zh", name: "Chinese"),
        LanguageChoice(code: "zh-Hant", name: "Traditional Chinese"), LanguageChoice(code: "es", name: "Spanish"),
        LanguageChoice(code: "fr", name: "French"), LanguageChoice(code: "de", name: "German"),
        LanguageChoice(code: "it", name: "Italian"), LanguageChoice(code: "pt", name: "Portuguese"),
        LanguageChoice(code: "ja", name: "Japanese"), LanguageChoice(code: "ko", name: "Korean"),
        LanguageChoice(code: "ar", name: "Arabic"), LanguageChoice(code: "ru", name: "Russian"),
        LanguageChoice(code: "uk", name: "Ukrainian"), LanguageChoice(code: "tr", name: "Turkish"),
        LanguageChoice(code: "hi", name: "Hindi"), LanguageChoice(code: "vi", name: "Vietnamese"),
        LanguageChoice(code: "th", name: "Thai"), LanguageChoice(code: "id", name: "Indonesian"),
        LanguageChoice(code: "ms", name: "Malay"), LanguageChoice(code: "tl", name: "Filipino"),
        LanguageChoice(code: "pl", name: "Polish"), LanguageChoice(code: "cs", name: "Czech"),
        LanguageChoice(code: "nl", name: "Dutch"), LanguageChoice(code: "he", name: "Hebrew"),
        LanguageChoice(code: "fa", name: "Persian"), LanguageChoice(code: "ur", name: "Urdu"),
        LanguageChoice(code: "bn", name: "Bengali"), LanguageChoice(code: "ta", name: "Tamil"),
        LanguageChoice(code: "te", name: "Telugu"), LanguageChoice(code: "mr", name: "Marathi"),
        LanguageChoice(code: "gu", name: "Gujarati"), LanguageChoice(code: "km", name: "Khmer"),
        LanguageChoice(code: "my", name: "Burmese"), LanguageChoice(code: "bo", name: "Tibetan"),
        LanguageChoice(code: "kk", name: "Kazakh"), LanguageChoice(code: "mn", name: "Mongolian"),
        LanguageChoice(code: "ug", name: "Uyghur"), LanguageChoice(code: "yue", name: "Cantonese"),
    ]
}

private struct LanguageChoice {
    let code: String
    let name: String
}

private struct PrivacyRoute {
    let feature: String
    let destination: String
    let description: String
    let host: String?
    let isLoopback: Bool
}

private extension EndpointConfiguration {
    var hostDisplayName: String {
        if EndpointLocation.isLoopback(baseURL) { return "a local service on this Mac" }
        return baseURL.host ?? baseURL.absoluteString
    }
}

private enum VoicePipelineMode: String, CaseIterable, Identifiable {
    case openAIRealtime
    case compatibleRealtime

    var id: Self { self }

    var title: String {
        switch self {
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
