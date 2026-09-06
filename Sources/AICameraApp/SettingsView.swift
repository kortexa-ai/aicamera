import AICameraCore
import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var configuration: ConfigurationController
    @ObservedObject private var loginItem: LoginItemController
    @ObservedObject private var builtinVision: BuiltinVisionModelController
    @ObservedObject private var builtinTranslation: BuiltinTranslationModelController
    @ObservedObject private var builtinWhisper: BuiltinWhisperModelController
    @ObservedObject private var codexAuth: CodexAuthController
    @State private var realtimeAuthentication = RealtimeAuthentication.apiKey
    @State private var transcriptionProvider = TranscriptionProvider.openAI
    @State private var transcriptionWhisperModel = BuiltinWhisperModel.base
    @State private var didLoadDrafts = false
    @State private var realtimeModel = ConfigurationController.defaultRealtimeModel
    @State private var realtimeVoice = ConfigurationController.defaultRealtimeVoice
    @State private var realtimeCredential = ""
    @State private var realtimeCredentialSummary: String?
    @State private var realtimeMessage: String?
    @State private var realtimeConnectionTest: Task<Void, Never>?
    @State private var realtimeConnectionTestID = UUID()
    @State private var transcriptionModel = ConfigurationController.defaultTranscriptionModel
    @State private var transcriptionLanguage = "auto"
    @State private var transcriptionCredential = ""
    @State private var transcriptionCredentialSummary: String?
    @State private var transcriptionMessage: String?

    init(model: AppModel) {
        self.model = model
        self.configuration = model.configurationController
        self.loginItem = model.loginItemController
        self.builtinVision = model.builtinVisionModelController
        self.builtinTranslation = model.builtinTranslationModelController
        self.builtinWhisper = model.builtinWhisperModelController
        self.codexAuth = model.codexAuthController
    }

    var body: some View {
        TabView(selection: $model.selectedSettingsPage) {
            generalSettings
                .tabItem { Label("General", systemImage: "switch.2") }
                .tag(AICameraSettingsPage.general)

            aiSettings
                .tabItem { Label("AI", systemImage: "sparkles") }
                .tag(AICameraSettingsPage.advanced)

            privacySettings
                .tabItem { Label("Privacy", systemImage: "hand.raised") }
                .tag(AICameraSettingsPage.maintenance)
        }
        .frame(width: 740, height: 540)
        .background(SettingsWindowLifecycle())
        .onDisappear { cancelConnectionTest() }
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

    private var aiSettings: some View {
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

            settingsSection(
                "Conversation",
                enabled: conversationEnabledBinding,
                disabledText: "Conversational features are disabled.",
                showsSetupWhenDisabled: true
            ) {
                Group {
                    LabeledContent("Service", value: "OpenAI Realtime")
                    Text(configuration.configuration.pipeline.conversation.enabled
                         ? "Active: \(configuration.configuration.pipeline.conversation.realtimeAuthentication == .codex ? "Codex login" : "API key")"
                         : "Conversation is off. Configure sign-in and save to enable it.")
                        .font(.caption).foregroundStyle(.secondary)
                    Picker("Sign in with", selection: $realtimeAuthentication) {
                        Text("API key").tag(RealtimeAuthentication.apiKey)
                        Text("Codex login").tag(RealtimeAuthentication.codex)
                    }
                    .onChange(of: realtimeAuthentication) { _, choice in
                        cancelConnectionTest()
                        realtimeMessage = nil
                        if choice == .codex { codexAuth.loadStatus() }
                    }
                    Picker("Model", selection: $realtimeModel) {
                        ForEach(realtimeModelChoices, id: \.self) { Text($0).tag($0) }
                    }
                    .onChange(of: realtimeModel) { _, _ in cancelConnectionTest(); realtimeMessage = nil }
                    Picker("Voice", selection: $realtimeVoice) {
                        ForEach(realtimeVoiceChoices, id: \.self) { Text($0.capitalized).tag($0) }
                    }
                    .onChange(of: realtimeVoice) { _, _ in cancelConnectionTest(); realtimeMessage = nil }
                    if realtimeAuthentication == .codex {
                        codexLoginControls
                    } else {
                        if let realtimeCredentialSummary {
                            LabeledContent("API key") {
                                HStack(spacing: 8) {
                                    Text(realtimeCredentialSummary).monospaced()
                                    Button(role: .destructive) { removeOpenAICredential() } label: {
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
                    }
                    HStack {
                        Button(configuration.configuration.pipeline.conversation.enabled ? "Save Changes" : "Save & Enable") {
                            saveRealtimeConfiguration()
                        }
                            .buttonStyle(.borderedProminent)
                            .disabled(realtimeAuthentication == .codex && (!codexAuth.isSignedIn || codexAuth.isBusy))
                        if realtimeConnectionTest != nil {
                            Button("Cancel Test") { cancelConnectionTest() }
                        } else {
                            Button("Test Connection") { testRealtimeConnection() }
                                .disabled(model.realtimeConversationActive || codexAuth.isBusy
                                    || (realtimeAuthentication == .codex ? !codexAuth.isSignedIn : realtimeCredentialSummary == nil))
                        }
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
            }

            transcriptionSettings

            settingsSection(
                "Tools",
                enabled: toolsEnabledBinding,
                disabledText: "Realtime tools are disabled."
            ) {
                if toolsEnabled {
                    Text("Ask Realtime to draw or clear an animated overlay while the camera is active. Each overlay expires automatically.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            settingsSection(
                "Vision & Gestures",
                enabled: visionEnabledBinding,
                disabledText: "Vision and gesture processing are disabled.",
                showsSetupWhenDisabled: true
            ) {
                Group {
                    builtinVisionControls
                    Toggle("Gestures", isOn: gesturesEnabledBinding)
                }
            }

            settingsSection(
                "Overlays",
                enabled: overlayBoolBinding(\.enabled),
                disabledText: "Camera overlays are disabled."
            ) {
                if overlaysEnabled {
                    Toggle("Show transcript", isOn: overlayBoolBinding(\.showTranscript))
                    Toggle("Show agent response", isOn: overlayBoolBinding(\.showAgentResponse))
                    Toggle("Show status", isOn: overlayBoolBinding(\.showStatus))
                    Toggle("Show detection boxes", isOn: overlayBoolBinding(\.showDetectionBoxes))
                    Toggle("Show gesture labels", isOn: overlayBoolBinding(\.showGestureLabels))
                }
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
            if !didLoadDrafts { syncDrafts(); didLoadDrafts = true }
        }
    }

    @ViewBuilder private var codexLoginControls: some View {
        if let account = codexAuth.accountLabel {
            LabeledContent("Account", value: account)
            HStack {
                Button("Refresh Login") { codexAuth.refreshLogin() }
                Button("Sign Out") {
                    cancelConnectionTest()
                    model.stopRealtimeConversation()
                    if configuration.configuration.pipeline.conversation.realtimeAuthentication == .codex {
                        configuration.update { $0.pipeline.conversation.enabled = false }
                    }
                    codexAuth.signOut()
                }
            }.disabled(codexAuth.isBusy)
        } else if let code = codexAuth.deviceCode {
            LabeledContent("Sign-in code") { Text(code).monospaced().textSelection(.enabled) }
            HStack {
                Button("Open Sign-in Page") { codexAuth.openSignInPage() }
                Button("Cancel Sign-in") { codexAuth.cancelSignIn() }
            }
        } else {
            Button("Sign In to Codex") { codexAuth.signIn() }.disabled(codexAuth.isBusy)
        }
        if codexAuth.isBusy { ProgressView().controlSize(.small) }
        if let message = codexAuth.message { Text(message).font(.caption).foregroundStyle(.secondary) }
        Text("Uses the installed Codex CLI with a separate login for AI Camera. Realtime access depends on your account; subscription coverage of this audio usage is not verified.")
            .font(.caption).foregroundStyle(.secondary)
    }

    private var transcriptionSettings: some View {
        settingsSection("Transcription", enabled: transcriptionEnabledBinding,
                        disabledText: "Transcription is off.", showsSetupWhenDisabled: true) {
            Text(transcriptionEnabled
                 ? "Active: \(configuration.configuration.pipeline.conversation.transcriptionProvider == .whisper ? "Whisper" : "OpenAI")"
                 : "Transcription is off. Choose a provider and save to enable it.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Provider", selection: $transcriptionProvider) {
                Text("OpenAI").tag(TranscriptionProvider.openAI)
                Text("Whisper").tag(TranscriptionProvider.whisper)
            }
            if transcriptionProvider == .whisper {
                Picker("Size", selection: $transcriptionWhisperModel) {
                    ForEach(builtinWhisper.availableModels) { Text($0.sizeName).tag($0) }
                }
                .pickerStyle(.segmented)
                .disabled(builtinWhisper.hasActiveDownload)
                Text("\(transcriptionWhisperModel.summary) \(transcriptionWhisperModel.downloadSize) download.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                whisperModelControls
                Text("Whisper transcribes audio in this app on your Mac. No API key or external transcription service is used.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Picker("Model", selection: $transcriptionModel) {
                    ForEach(transcriptionModelChoices, id: \.self) { Text($0).tag($0) }
                }
                transcriptionCredentialControls
                Text("OpenAI receives audio windows while its transcription provider is active. Realtime supplies its own transcript during Talk.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Picker("Language", selection: $transcriptionLanguage) {
                ForEach(Self.transcriptionLanguages, id: \.code) { Text($0.name).tag($0.code) }
            }
            Button(transcriptionEnabled ? "Save Changes" : "Save & Enable") { saveTranscriptionConfiguration() }
                .buttonStyle(.borderedProminent)
                .disabled(transcriptionProvider == .whisper && !builtinWhisper.isReady(transcriptionWhisperModel))
            if let transcriptionMessage {
                Text(transcriptionMessage).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Toggle("Translate", isOn: translationEnabledBinding)
                .disabled(!transcriptionEnabled || !builtinTranslation.isReady)
            builtinTranslationControls
            if translationEnabled {
                Picker("From", selection: translationStringBinding(\.sourceLanguage)) {
                    ForEach(Self.sourceLanguages, id: \.code) { Text($0.name).tag($0.code) }
                }
                Picker("To", selection: translationStringBinding(\.targetLanguage)) {
                    ForEach(Self.targetLanguages, id: \.code) { Text($0.name).tag($0.code) }
                }
                Text("Translation runs on finalized transcript text and never blocks the live audio path.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var transcriptionCredentialControls: some View {
        if let transcriptionCredentialSummary {
            LabeledContent("API key") {
                HStack(spacing: 8) {
                    Text(transcriptionCredentialSummary).monospaced()
                    Button(role: .destructive) { removeOpenAICredential() } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless).help("Remove the shared OpenAI API key")
                }
            }
        }
        SecureField(transcriptionCredentialSummary == nil ? "Add API key" : "Replace API key", text: $transcriptionCredential)
        Text("Shared with OpenAI Realtime · Stored in Keychain").font(.caption).foregroundStyle(.secondary)
    }

    @ViewBuilder private var whisperModelControls: some View {
        switch builtinWhisper.state(for: transcriptionWhisperModel) {
        case .notDownloaded:
            LabeledContent("Model") {
                Button("Download \(transcriptionWhisperModel.name) · \(transcriptionWhisperModel.downloadSize)") {
                    builtinWhisper.download(transcriptionWhisperModel)
                }.disabled(builtinWhisper.hasActiveDownload)
            }
        case .downloading:
            LabeledContent("Model") {
                HStack(spacing: 8) {
                    ProgressView(value: builtinWhisper.progress?.fraction).frame(width: 100)
                    if let fraction = builtinWhisper.progress?.fraction {
                        Text(fraction, format: .percent.precision(.fractionLength(0)))
                    } else { Text("Starting download…").foregroundStyle(.secondary) }
                    Button("Cancel") { builtinWhisper.cancelDownload(transcriptionWhisperModel) }
                        .controlSize(.small)
                }
            }
        case .ready:
            LabeledContent("Model") {
                HStack(spacing: 8) {
                    Label(transcriptionWhisperModel.name, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Button(role: .destructive) {
                        if configuration.configuration.pipeline.conversation.transcriptionProvider == .whisper,
                           configuration.configuration.pipeline.conversation.transcriptionWhisperModel == transcriptionWhisperModel {
                            configuration.update { profile in
                                profile.pipeline.conversation.transcriptionEnabled = false
                                profile.pipeline.translation.enabled = false
                                profile.overlays.showTranscript = false
                            }
                        }
                        builtinWhisper.remove(transcriptionWhisperModel)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove downloaded model")
                    .accessibilityLabel("Remove \(transcriptionWhisperModel.name)")
                }
            }
        case let .failed(message):
            LabeledContent("Model") {
                Button("Try Download Again") { builtinWhisper.download(transcriptionWhisperModel) }
                    .disabled(builtinWhisper.hasActiveDownload)
            }
            Text(message).font(.caption).foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var builtinVisionControls: some View {
        Toggle("Object detection", isOn: builtinObjectDetectionBinding)
            .disabled(!builtinVision.isReady(selectedBuiltinVisionModel))

        Picker("Size", selection: builtinVisionModelBinding) {
            ForEach(BuiltinVisionModel.allCases) { visionModel in
                Text(visionModel.sizeName).tag(visionModel)
            }
        }
        .pickerStyle(.segmented)
        .disabled(builtinVision.hasActiveDownload)
        Text("\(selectedBuiltinVisionModel.name) · \(selectedBuiltinVisionModel.downloadSize) download. \(selectedBuiltinVisionModel.detail)")
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        switch builtinVision.state(for: selectedBuiltinVisionModel) {
        case .notDownloaded:
            LabeledContent("Model") {
                Button("Download \(selectedBuiltinVisionModel.name) · \(selectedBuiltinVisionModel.downloadSize)") {
                    builtinVision.download(selectedBuiltinVisionModel)
                }
            }
        case .downloading:
            LabeledContent("Model") {
                HStack(spacing: 8) {
                    ProgressView(value: builtinVision.downloadProgress).frame(width: 100)
                    if builtinVision.isCancellingDownload {
                        Text("Finishing cancellation…").foregroundStyle(.secondary)
                    } else if builtinVision.downloadProgress == 1 {
                        Text("Preparing model…").foregroundStyle(.secondary)
                    } else if let fraction = builtinVision.downloadProgress {
                        Text(fraction, format: .percent.precision(.fractionLength(0)))
                    } else { Text("Starting download…").foregroundStyle(.secondary) }
                    Button("Cancel") { builtinVision.cancelDownload(selectedBuiltinVisionModel) }
                        .controlSize(.small)
                        .disabled(builtinVision.isCancellingDownload)
                }
            }
        case .ready:
            LabeledContent("Model") {
                HStack(spacing: 8) {
                    Label(selectedBuiltinVisionModel.name, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Button(role: .destructive) { removeBuiltinVisionModel(selectedBuiltinVisionModel) } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove downloaded model")
                }
            }
        case .failed(let message):
            LabeledContent("Model") {
                Button("Try Download Again") { builtinVision.download(selectedBuiltinVisionModel) }
            }
            Text(message).font(.caption).foregroundStyle(.red)
        }
        if selectedBuiltinVisionModel != .yoloV3Tiny {
            Text("RF-DETR by Roboflow · Apache 2.0")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        Text("Detection runs entirely in this app's memory; camera frames are not uploaded.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var builtinTranslationControls: some View {
        switch builtinTranslation.state {
        case .notDownloaded:
            LabeledContent("Model") {
                Button("Download \(BuiltinTranslationModelController.modelName) · \(BuiltinTranslationModelController.downloadSize)") {
                    builtinTranslation.download()
                }
            }
            Text("The model weights are downloaded only when requested. Tencent HY-MT2 is Apache 2.0 licensed, supports multilingual translation, and runs locally.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .downloading:
            LabeledContent("Model") {
                HStack(spacing: 8) {
                    ProgressView(value: builtinTranslation.progress?.fraction).frame(width: 100)
                    if let fraction = builtinTranslation.progress?.fraction {
                        Text(fraction, format: .percent.precision(.fractionLength(0)))
                    } else { Text("Starting download…").foregroundStyle(.secondary) }
                    Button("Cancel") { builtinTranslation.cancelDownload() }
                        .controlSize(.small)
                }
            }
        case .ready:
            LabeledContent("Model") {
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
            LabeledContent("Model") {
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
        Button("Open Camera Extensions") {
            model.cameraExtensionManager.openApprovalSettings()
        }
        .controlSize(.small)
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

    private var privacySettings: some View {
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
        realtimeAuthentication = conversation.realtimeAuthentication
        if realtimeAuthentication == .codex { codexAuth.loadStatus() }
        let remote = endpoint(withID: conversation.realtimeEndpointID)
        let supported = remote.flatMap { SupportedConfigurationPolicy.isPublicRealtime($0) ? $0 : nil }
        realtimeModel = supported?.model ?? ConfigurationController.defaultRealtimeModel
        realtimeVoice = supported?.options["voice"]?.stringValue ?? ConfigurationController.defaultRealtimeVoice
        realtimeCredentialSummary = AppSecretResolver().maskedSecret(
            account: ConfigurationController.openAICredentialAccount
        )
        realtimeMessage = nil
    }

    private func syncTranscriptionDraft() {
        let conversation = configuration.configuration.pipeline.conversation
        transcriptionProvider = conversation.transcriptionProvider
        transcriptionWhisperModel = builtinWhisper.availableModels.contains(conversation.transcriptionWhisperModel)
            ? conversation.transcriptionWhisperModel : .base
        transcriptionCredentialSummary = AppSecretResolver().maskedSecret(account: ConfigurationController.openAICredentialAccount)
        let remote = transcriptionEndpoint ?? endpoint(withID: ConfigurationController.openAITranscriptionEndpointID)
        transcriptionModel = remote?.model ?? ConfigurationController.defaultTranscriptionModel
        let language = conversation.transcriptionProvider == .whisper
            ? conversation.transcriptionLanguage : remote?.options["language"]?.stringValue ?? "auto"
        transcriptionLanguage = Self.transcriptionLanguages.contains(where: { $0.code == language }) ? language : "auto"
        transcriptionMessage = nil
    }

    private func testRealtimeConnection() {
        let authentication = realtimeAuthentication, selectedModel = realtimeModel, voice = realtimeVoice
        let id = UUID()
        realtimeConnectionTestID = id
        realtimeMessage = "Checking the saved credential and selected model…"
        realtimeConnectionTest = Task { @MainActor in
            defer { if realtimeConnectionTestID == id { realtimeConnectionTest = nil } }
            do {
                try await model.testRealtimeConnection(authentication: authentication, model: selectedModel, voice: voice)
                try Task.checkCancellation()
                guard realtimeConnectionTestID == id else { return }
                realtimeMessage = "Connected to public OpenAI Realtime. No microphone audio was sent; use Talk to test speech."
            } catch {
                guard realtimeConnectionTestID == id else { return }
                realtimeMessage = Task.isCancelled ? "Connection test cancelled." : error.localizedDescription
            }
        }
    }

    private func cancelConnectionTest() {
        guard realtimeConnectionTest != nil else { return }
        realtimeConnectionTestID = UUID()
        realtimeConnectionTest?.cancel(); realtimeConnectionTest = nil
        realtimeMessage = "Connection test cancelled."
    }

    private func saveRealtimeConfiguration() {
        guard realtimeAuthentication != .codex || (codexAuth.isSignedIn && !codexAuth.isBusy) else {
            realtimeMessage = "Complete Codex sign-in before enabling this conversation option."
            return
        }
        let baseURL = ConfigurationController.openAIRealtimeBaseURL
        let model = realtimeModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let voice = realtimeVoice.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty, !voice.isEmpty else {
            realtimeMessage = "Enter both a Realtime model and voice."
            return
        }
        let endpointID = "openai-realtime"
        let credentialAccount = ConfigurationController.openAICredentialAccount
        guard realtimeAuthentication == .codex || realtimeCredentialSummary != nil || !realtimeCredential.isEmpty else {
            realtimeMessage = "Add an API key to enable Realtime."
            return
        }
        do {
            if realtimeAuthentication == .apiKey, !realtimeCredential.isEmpty {
                try AppSecretResolver().store(
                    realtimeCredential,
                    account: credentialAccount
                )
                realtimeCredential = ""
            }
            let options: [String: JSONValue] = ["voice": .string(voice)]
            let endpoint = EndpointConfiguration(
                id: endpointID,
                adapter: .openAIRealtime,
                baseURL: baseURL,
                model: model,
                auth: realtimeAuthentication == .codex ? .init() : .init(
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
                profile.pipeline.conversation.realtimeAuthentication = realtimeAuthentication
                profile.pipeline.conversation.realtimeEndpointID = endpointID
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
            transcriptionCredentialSummary = realtimeCredentialSummary
            realtimeMessage = configuration.validationMessage ?? "Realtime configuration saved."
        } catch {
            realtimeMessage = "Realtime credential save failed: \(error.localizedDescription)"
        }
    }

    private func saveTranscriptionConfiguration() {
        if transcriptionProvider == .whisper {
            guard builtinWhisper.isReady(transcriptionWhisperModel) else {
                transcriptionMessage = "Download the selected Whisper model before enabling local transcription."
                return
            }
            configuration.update { profile in
                ConfigurationController.installWhisperTranscriptionConfiguration(
                    in: &profile, model: transcriptionWhisperModel, language: transcriptionLanguage
                )
                profile.overlays.enabled = true
                profile.overlays.showTranscript = true
            }
            transcriptionMessage = configuration.validationMessage ?? "Whisper transcription enabled."
            return
        }
        let model = transcriptionModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else {
            transcriptionMessage = "Choose a transcription model."
            return
        }
        guard Self.transcriptionLanguages.contains(where: { $0.code == transcriptionLanguage }) else {
            transcriptionMessage = "Choose a supported transcription language."
            return
        }
        guard transcriptionCredentialSummary != nil || !transcriptionCredential.isEmpty else {
            transcriptionMessage = "Add an OpenAI API key to enable Transcription."
            return
        }
        do {
            if !transcriptionCredential.isEmpty {
                try AppSecretResolver().store(
                    transcriptionCredential,
                    account: ConfigurationController.openAICredentialAccount
                )
                transcriptionCredential = ""
            }
            configuration.update { profile in
                ConfigurationController.installOpenAITranscriptionConfiguration(
                    in: &profile,
                    model: model,
                    language: transcriptionLanguage
                )
                profile.overlays.enabled = true
                profile.overlays.showTranscript = true
            }
            let summary = AppSecretResolver().maskedSecret(
                account: ConfigurationController.openAICredentialAccount
            )
            transcriptionCredentialSummary = summary
            realtimeCredentialSummary = summary
            transcriptionMessage = configuration.validationMessage ?? "OpenAI transcription configuration saved."
        } catch {
            transcriptionMessage = "OpenAI credential save failed: \(error.localizedDescription)"
        }
    }

    private var transcriptionEndpoint: EndpointConfiguration? {
        endpoint(withID: configuration.configuration.pipeline.conversation.transcriptionEndpointID)
    }

    private var transcriptionModelChoices: [String] {
        ([transcriptionModel] + ConfigurationController.transcriptionModels).reduce(into: []) {
            if !$0.contains($1) { $0.append($1) }
        }
    }

    private var conversationEnabled: Bool { configuration.configuration.pipeline.conversation.enabled }


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
    private var transcriptionEnabled: Bool {
        configuration.configuration.pipeline.conversation.transcriptionEnabled
    }
    private var translationEnabled: Bool { configuration.configuration.pipeline.translation.enabled }
    private var visionEnabled: Bool {
        configuration.configuration.pipeline.videoStages.contains(where: \.enabled)
    }

    private var transcriptionEnabledBinding: Binding<Bool> {
        Binding(get: { transcriptionEnabled }, set: { enabled in
            if enabled { saveTranscriptionConfiguration() }
            else {
                configuration.update { profile in
                    profile.pipeline.conversation.transcriptionEnabled = false
                    profile.pipeline.translation.enabled = false
                    profile.overlays.showTranscript = false
                }
                transcriptionMessage = nil
            }
        })
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
            get: { conversationEnabled },
            set: { enabled in
                if enabled { saveRealtimeConfiguration() }
                else {
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

    private func settingsSection<Content: View>(
        _ title: String,
        enabled: Binding<Bool>,
        disabledText: String,
        showsSetupWhenDisabled: Bool = false,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Section {
            settingsHeader(title, enabled: enabled)
                .font(.headline)
                .listRowInsets(EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            if enabled.wrappedValue || showsSetupWhenDisabled {
                content()
            } else {
                Text(disabledText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func removeOpenAICredential() {
        cancelConnectionTest()
        do {
            try AppSecretResolver().remove(account: ConfigurationController.openAICredentialAccount)
            realtimeCredentialSummary = nil
            transcriptionCredentialSummary = nil
            configuration.update { profile in
                if let endpoint = profile.endpoints.first(where: {
                    $0.id == profile.pipeline.conversation.transcriptionEndpointID
                }),
                   endpoint.auth.reference == ConfigurationController.openAICredentialAccount {
                    profile.pipeline.conversation.transcriptionEnabled = false
                    profile.pipeline.translation.enabled = false
                    profile.overlays.showTranscript = false
                }
                if let endpoint = profile.endpoints.first(where: {
                    $0.id == profile.pipeline.conversation.realtimeEndpointID
                }),
                   endpoint.auth.reference == ConfigurationController.openAICredentialAccount {
                    profile.pipeline.conversation.enabled = false
                }
            }
            realtimeMessage = "Shared API key removed. Features using that key were disabled."
            transcriptionMessage = realtimeMessage
        } catch {
            realtimeMessage = "API key removal failed: \(error.localizedDescription)"
            transcriptionMessage = realtimeMessage
        }
    }

    private var builtinObjectDetectionBinding: Binding<Bool> {
        Binding(
            get: {
                configuration.configuration.pipeline.videoStages.contains {
                        $0.kind == .objectDetection
                            && $0.options["provider"]?.stringValue == "builtin"
                            && ($0.options["model"]?.stringValue ?? BuiltinVisionModel.yoloV3Tiny.rawValue)
                                == selectedBuiltinVisionModel.rawValue
                            && $0.enabled
                }
            },
            set: { enabled in
                configuration.update { profile in
                    if let index = profile.pipeline.videoStages.firstIndex(where: {
                        $0.kind == .objectDetection && $0.options["provider"]?.stringValue == "builtin"
                    }) {
                        profile.pipeline.videoStages[index].enabled = enabled
                        profile.pipeline.videoStages[index].options["model"] = .string(selectedBuiltinVisionModel.rawValue)
                    } else {
                        profile.pipeline.videoStages.append(.init(
                            id: "builtin-objects",
                            kind: .objectDetection,
                            enabled: enabled,
                            maximumRateHz: 5,
                            maximumFrameAgeMilliseconds: 500,
                            options: [
                                "provider": .string("builtin"),
                                "model": .string(selectedBuiltinVisionModel.rawValue),
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

    private var selectedBuiltinVisionModel: BuiltinVisionModel {
        if let rawValue = configuration.configuration.pipeline.videoStages.first(where: {
            $0.kind == .objectDetection && $0.options["provider"]?.stringValue == "builtin"
        })?.options["model"]?.stringValue,
           let selected = BuiltinVisionModel(rawValue: rawValue) {
            return selected
        }
        return builtinVision.isReady(.yoloV3Tiny) ? .yoloV3Tiny : BuiltinVisionModelController.defaultModel
    }

    private var builtinVisionModelBinding: Binding<BuiltinVisionModel> {
        Binding(
            get: { selectedBuiltinVisionModel },
            set: { selected in
                configuration.update { profile in
                    if let index = profile.pipeline.videoStages.firstIndex(where: {
                        $0.kind == .objectDetection && $0.options["provider"]?.stringValue == "builtin"
                    }) {
                        profile.pipeline.videoStages[index].options["model"] = .string(selected.rawValue)
                        if !builtinVision.isReady(selected) {
                            profile.pipeline.videoStages[index].enabled = false
                        }
                    } else {
                        profile.pipeline.videoStages.append(.init(
                            id: "builtin-objects",
                            kind: .objectDetection,
                            enabled: false,
                            maximumRateHz: 5,
                            maximumFrameAgeMilliseconds: 500,
                            options: [
                                "provider": .string("builtin"),
                                "model": .string(selected.rawValue),
                                "confidence": .number(0.35),
                            ]
                        ))
                    }
                }
            }
        )
    }

    private func removeBuiltinVisionModel(_ visionModel: BuiltinVisionModel) {
        if builtinObjectDetectionBinding.wrappedValue {
            builtinObjectDetectionBinding.wrappedValue = false
        }
        builtinVision.remove(visionModel)
    }

    private func removeBuiltinTranslationModel() {
        if translationEnabled {
            translationEnabledBinding.wrappedValue = false
        }
        builtinTranslation.remove()
    }

    private var gesturesEnabled: Bool {
        configuration.configuration.pipeline.videoStages.contains { $0.kind == .handGesture && $0.enabled }
    }

    private var gesturesEnabledBinding: Binding<Bool> {
        Binding(get: { gesturesEnabled }, set: { enabled in
            configuration.update { profile in
                if let index = profile.pipeline.videoStages.firstIndex(where: { $0.kind == .handGesture }) {
                    profile.pipeline.videoStages[index].enabled = enabled
                } else {
                    profile.pipeline.videoStages.append(.init(
                        id: "hands", kind: .handGesture, enabled: enabled,
                        maximumRateHz: 8, maximumFrameAgeMilliseconds: 250
                    ))
                }
            }
        })
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
        if transcriptionEnabled, configuration.configuration.pipeline.conversation.transcriptionProvider == .whisper {
            descriptions.append("Whisper transcribes microphone audio in app memory. Audio is not sent to a transcription service.")
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
                ? (conversation.realtimeAuthentication == .codex
                   ? "Conversation sends microphone audio to public OpenAI Realtime using AI Camera's separate Codex login. Account access and subscription coverage of this audio usage are not guaranteed."
                   : "Conversation sends microphone audio to OpenAI Realtime. OpenAI processes it under the API data controls for the organization and project associated with your API key.")
                : "Conversation sends microphone audio to \(destination), using the service configured in AI."
            routes.append(.init(
                feature: "Conversation",
                destination: destination,
                description: description,
                host: endpoint.baseURL.host?.lowercased(),
                isLoopback: EndpointLocation.isLoopback(endpoint.baseURL)
            ))
        }
        if conversation.transcriptionEnabled, conversation.transcriptionProvider == .openAI,
           let endpoint = endpoint(withID: conversation.transcriptionEndpointID) {
            let description = endpoint.baseURL.host?.lowercased() == "api.openai.com"
                ? "Transcription sends microphone audio to OpenAI. OpenAI processes it under the API data controls for the organization and project associated with your API key."
                : "Transcription sends microphone audio to \(endpoint.hostDisplayName)."
            routes.append(.init(
                feature: "Transcription",
                destination: endpoint.hostDisplayName,
                description: description,
                host: endpoint.baseURL.host?.lowercased(),
                isLoopback: EndpointLocation.isLoopback(endpoint.baseURL)
            ))
        }
        if conversation.enabled, !conversation.realtimeEnabled, let endpoint = endpoint(withID: conversation.agentEndpointID) {
            routes.append(.init(
                feature: "Advanced conversation agent",
                destination: endpoint.hostDisplayName,
                description: "The advanced conversation agent sends transcript text and enabled scene context to \(endpoint.hostDisplayName).",
                host: endpoint.baseURL.host?.lowercased(),
                isLoopback: EndpointLocation.isLoopback(endpoint.baseURL)
            ))
        }
        if conversation.enabled, !conversation.realtimeEnabled, let endpoint = endpoint(withID: conversation.speechEndpointID) {
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
        cancelConnectionTest()
        realtimeCredential = ""
        transcriptionCredential = ""
        syncRealtimeDraft()
        syncTranscriptionDraft()
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
    private static let transcriptionLanguages = [LanguageChoice(code: "auto", name: "Auto-detect")]
        + modelLanguages.filter { $0.code.count == 2 }
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
