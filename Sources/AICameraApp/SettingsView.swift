import AICameraCore
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var configuration: ConfigurationController
    @ObservedObject private var loginItem: LoginItemController
    @State private var keychainAccount = ""
    @State private var keychainSecret = ""
    @State private var keychainMessage: String?
    @State private var realtimeProvider = "openai"
    @State private var realtimeBaseURL = "https://api.openai.com"
    @State private var realtimeModel = "gpt-realtime"
    @State private var realtimeVoice = "marin"
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
    }

    private var generalSettings: some View {
        ScrollViewReader { proxy in
            Form {
                if !configuration.isConfigurationUsable {
                    Section("Profile repair required") {
                        Text(configuration.validationMessage ?? "The saved profile is invalid.")
                            .foregroundStyle(.red)
                        Text("Open AI & Advanced, repair the preserved JSON, then select Validate & Save. Automatic camera and microphone capture is blocked until the profile is valid.")
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
        VStack(alignment: .leading, spacing: 10) {
            GroupBox("Conversation") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 18) {
                        Toggle("Enabled", isOn: conversationBoolBinding(\.enabled))
                        Toggle("Transcribe microphone", isOn: conversationBoolBinding(\.transcriptionEnabled))
                            .disabled(!configuration.configuration.pipeline.conversation.enabled)
                        Toggle("Agent replies", isOn: conversationBoolBinding(\.respondToFinalTranscripts))
                            .disabled(!configuration.configuration.pipeline.conversation.enabled)
                        Spacer()
                    }
                    HStack(spacing: 18) {
                        Picker("Activation", selection: conversationActivationBinding) {
                            Text("Wake phrase").tag(ConversationActivationMode.wakePhrase)
                            Text("Always listening").tag(ConversationActivationMode.alwaysListening)
                        }
                        .pickerStyle(.segmented)
                        Stepper(
                            "Wake window: \(Int(configuration.configuration.pipeline.conversation.wakeWindowSeconds)) seconds",
                            value: conversationDoubleBinding(\.wakeWindowSeconds),
                            in: 1...30,
                            step: 1
                        )
                        .disabled(
                            !configuration.configuration.pipeline.conversation.enabled
                                || configuration.configuration.pipeline.conversation.activationMode != .wakePhrase
                        )
                    }
                    .disabled(!configuration.configuration.pipeline.conversation.enabled)
                    HStack {
                        Text("Wake phrase")
                        TextField("Hey Kortexa", text: $wakePhraseDraft)
                            .onSubmit { applyWakePhrase() }
                        Button("Apply") { applyWakePhrase() }
                            .disabled(
                                wakePhraseDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    || wakePhraseDraft == configuration.configuration.pipeline.conversation.wakePhrase
                            )
                    }
                    .disabled(
                        !configuration.configuration.pipeline.conversation.enabled
                            || configuration.configuration.pipeline.conversation.activationMode != .wakePhrase
                    )
                }
            }

            GroupBox("OpenAI Realtime") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(
                        "Use Realtime conversation (legacy ASR, agent, and TTS remain fallback)",
                        isOn: conversationBoolBinding(\.realtimeEnabled)
                    )
                    Picker("Provider", selection: $realtimeProvider) {
                        Text("OpenAI API").tag("openai")
                        Text("Compatible endpoint").tag("compatible")
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: realtimeProvider) { _, provider in
                        if provider == "openai" {
                            realtimeBaseURL = "https://api.openai.com"
                            if realtimeModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                realtimeModel = "gpt-realtime"
                            }
                        }
                    }
                    HStack {
                        TextField("Base URL", text: $realtimeBaseURL)
                        TextField("Model", text: $realtimeModel)
                        TextField("Voice", text: $realtimeVoice)
                    }
                    SecureField("API key or compatible bearer token (leave blank to keep saved value)", text: $realtimeCredential)
                    HStack {
                        Button("Save Realtime Configuration") { saveRealtimeConfiguration() }
                            .buttonStyle(.borderedProminent)
                        Spacer()
                        Text("Credential: macOS Keychain")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text("Saving explicitly permits this endpoint to receive microphone audio, transcripts, prompts, and bounded scene metadata. Raw camera frames are not granted.")
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

            HStack {
                Text("Profile JSON").font(.headline)
                Spacer()
#if DEBUG
                Button("Kortexa Local Preset") {
                    configuration.applyKortexaLocalPreset()
                    syncWakePhraseDraft()
                }
#endif
                Button("Import…") { importProfile() }
                Button("Export…") { exportProfile() }
                Button("Reload") {
                    configuration.reload()
                    syncWakePhraseDraft()
                }
                Button("Validate & Save") {
                    configuration.applyJSON()
                    syncWakePhraseDraft()
                }
                .buttonStyle(.borderedProminent)
            }
            TextEditor(text: $configuration.jsonText)
                .font(.system(.body, design: .monospaced))
                .border(Color.secondary.opacity(0.3))
            if let message = configuration.validationMessage {
                Text(message).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            } else if let message = configuration.profileTransferMessage {
                Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            } else {
                Text(configuration.fileURL.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding()
        .onAppear {
            syncWakePhraseDraft()
            syncRealtimeDraft()
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
            Text("Endpoint Keychain secret").font(.headline)
            HStack {
                TextField("Account name used by auth.reference", text: $keychainAccount)
                SecureField("Secret value", text: $keychainSecret)
                Button("Save") { saveKeychainSecret() }
                    .disabled(keychainAccount.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || keychainSecret.isEmpty)
                Button("Remove") { removeKeychainSecret() }
                    .disabled(keychainAccount.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let keychainMessage {
                Text(keychainMessage).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }

            Divider()
            Text("Camera and microphone buffers stay in memory. The default profile performs pure passthrough and permits only loopback endpoints. Remote endpoints require HTTPS, an allowed host, and explicit data grants.")
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

    private func saveKeychainSecret() {
        let account = keychainAccount.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try AppSecretResolver().store(keychainSecret, account: account)
            keychainSecret = ""
            keychainMessage = "Saved Keychain account '\(account)'."
        } catch {
            keychainMessage = "Keychain save failed: \(error.localizedDescription)"
        }
    }

    private func removeKeychainSecret() {
        let account = keychainAccount.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try AppSecretResolver().remove(account: account)
            keychainSecret = ""
            keychainMessage = "Removed Keychain account '\(account)'."
        } catch {
            keychainMessage = "Keychain removal failed: \(error.localizedDescription)"
        }
    }

    private func syncRealtimeDraft() {
        let conversation = configuration.configuration.pipeline.conversation
        guard let endpointID = conversation.realtimeEndpointID,
              let endpoint = configuration.configuration.endpoints.first(where: { $0.id == endpointID }) else {
            return
        }
        realtimeBaseURL = endpoint.baseURL.absoluteString
        realtimeModel = endpoint.model ?? ""
        realtimeVoice = endpoint.options["voice"]?.stringValue ?? ""
        realtimeProvider = endpoint.baseURL.host?.lowercased() == "api.openai.com" ? "openai" : "compatible"
    }

    private func importProfile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        configuration.importProfile(from: url)
        syncWakePhraseDraft()
        syncRealtimeDraft()
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
        let rawURL = realtimeBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let baseURL = URL(string: rawURL), baseURL.host != nil else {
            realtimeMessage = "Enter a valid Realtime base URL."
            return
        }
        let endpointID = "openai-realtime"
        let keychainAccount = "openai-realtime"
        do {
            if !realtimeCredential.isEmpty {
                try AppSecretResolver().store(realtimeCredential, account: keychainAccount)
                realtimeCredential = ""
            }
            let endpoint = EndpointConfiguration(
                id: endpointID,
                adapter: .openAIRealtime,
                baseURL: baseURL,
                model: realtimeModel.trimmingCharacters(in: .whitespacesAndNewlines),
                auth: .init(kind: .bearerKeychain, reference: keychainAccount),
                timeoutSeconds: 30,
                options: ["voice": .string(realtimeVoice.trimmingCharacters(in: .whitespacesAndNewlines))]
            )
            configuration.update { profile in
                profile.endpoints.removeAll(where: { $0.id == endpointID })
                profile.endpoints.append(endpoint)
                profile.pipeline.conversation.enabled = true
                profile.pipeline.conversation.realtimeEnabled = true
                profile.pipeline.conversation.realtimeEndpointID = endpointID
                if !EndpointLocation.isLoopback(baseURL), let host = baseURL.host?.lowercased() {
                    profile.privacy.networkMode = .allowListed
                    if !profile.privacy.allowedHosts.map({ $0.lowercased() }).contains(host) {
                        profile.privacy.allowedHosts.append(host)
                    }
                    profile.privacy.grants.removeAll(where: { $0.endpointID == endpointID })
                    profile.privacy.grants.append(.init(
                        endpointID: endpointID,
                        allowedData: [.rawAudio, .transcript, .promptText, .sceneMetadata]
                    ))
                }
            }
            if configuration.validationMessage == nil {
                realtimeMessage = "Realtime configuration saved."
            } else {
                realtimeMessage = configuration.validationMessage
            }
        } catch {
            realtimeMessage = "Realtime credential save failed: \(error.localizedDescription)"
        }
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
