import AICameraCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var configuration: ConfigurationController
    @State private var keychainAccount = ""
    @State private var keychainSecret = ""
    @State private var keychainMessage: String?
    @State private var wakePhraseDraft: String

    init(model: AppModel) {
        self.model = model
        self.configuration = model.configurationController
        self._wakePhraseDraft = State(
            initialValue: model.configurationController.configuration.pipeline.conversation.wakePhrase
        )
    }

    var body: some View {
        TabView {
            Form {
                Picker("Camera", selection: optionalBinding(\.videoDeviceID)) {
                    Text("Automatic").tag(String?.none)
                    ForEach(model.videoDevices) { device in
                        Text(device.name).tag(String?.some(device.id))
                    }
                }
                Picker("Microphone", selection: optionalBinding(\.audioDeviceID)) {
                    Text("Automatic").tag(String?.none)
                    ForEach(model.audioInputDevices) { device in
                        Text(device.name).tag(String?.some(device.id))
                    }
                }
                Picker("Mixed audio destination", selection: optionalBinding(\.virtualAudioOutputDeviceID)) {
                    Text("No virtual microphone output").tag(String?.none)
                    ForEach(model.audioOutputDevices) { device in
                        Text(device.name).tag(String?.some(device.id))
                    }
                }
                Picker("Video size", selection: resolutionBinding) {
                    Text("640 × 480").tag("640x480")
                    Text("1280 × 720").tag("1280x720")
                    Text("1920 × 1080").tag("1920x1080")
                }
                Picker("Frame rate", selection: intBinding(\.framesPerSecond)) {
                    Text("15 fps").tag(15)
                    Text("30 fps").tag(30)
                    Text("60 fps").tag(60)
                }
                Toggle("Mirror video", isOn: boolBinding(\.mirrorVideo))
                HStack {
                    Button("Refresh devices") { model.refreshDevicesAndDrivers() }
                    Spacer()
                    Text("Changes apply when the proxy restarts.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
            .tabItem { Label("Devices", systemImage: "video") }

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
                        .disabled(!configuration.configuration.pipeline.conversation.enabled)
                        if configuration.configuration.pipeline.conversation.activationMode == .alwaysListening {
                            Text("Legacy always-listening mode is active. A Settings control is planned; use Profile JSON to select wakePhrase now.")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                        Text("Audio changes apply when the proxy restarts.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack {
                    Text("Profile JSON").font(.headline)
                    Spacer()
                    Button("Kortexa Local Preset") {
                        configuration.applyKortexaLocalPreset()
                        syncWakePhraseDraft()
                    }
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
                } else {
                    Text(configuration.fileURL.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .padding()
            .onAppear { syncWakePhraseDraft() }
            .tabItem { Label("Pipeline", systemImage: "point.3.connected.trianglepath.dotted") }

            VStack(alignment: .leading, spacing: 12) {
                Text("System devices").font(.headline)
                DeviceStatusRow(
                    title: "Virtual camera",
                    status: model.cameraExtensionManager.status.label,
                    installed: model.cameraExtensionManager.status == .active,
                    busy: model.deviceOperationInProgress,
                    update: model.cameraExtensionManager.status == .updateAvailable,
                    install: model.activateCameraExtension,
                    uninstall: model.deactivateCameraExtension
                )
                DeviceStatusRow(
                    title: "Virtual microphone",
                    status: model.audioDriverManager.status.label,
                    installed: model.audioDriverManager.status.isInstalled,
                    busy: model.deviceOperationInProgress,
                    install: model.installAudioDriver,
                    uninstall: model.uninstallAudioDriver
                )
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
                Text("Camera and microphone frames stay in memory. The default profile permits only loopback endpoints. Remote endpoints require HTTPS, an allowed host, and explicit data grants. Secrets are stored in Keychain service ai.kortexa.aicamera, not in the profile.")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding()
            .tabItem { Label("Privacy & Install", systemImage: "hand.raised") }
        }
        .frame(width: 720, height: 520)
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
