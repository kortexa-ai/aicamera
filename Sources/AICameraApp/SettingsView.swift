import AICameraCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var configuration: ConfigurationController
    @State private var keychainAccount = ""
    @State private var keychainSecret = ""
    @State private var keychainMessage: String?

    init(model: AppModel) {
        self.model = model
        self.configuration = model.configurationController
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
                HStack {
                    Text("Profile JSON").font(.headline)
                    Spacer()
                    Button("Kortexa Local Preset") { configuration.applyKortexaLocalPreset() }
                    Button("Reload") { configuration.reload() }
                    Button("Validate & Save") { configuration.applyJSON() }
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
            .tabItem { Label("Pipeline", systemImage: "point.3.connected.trianglepath.dotted") }

            VStack(alignment: .leading, spacing: 12) {
                Text("System devices").font(.headline)
                HStack {
                    Text("Camera extension")
                    Spacer()
                    Text(model.cameraExtensionManager.status.label).foregroundStyle(.secondary)
                    Button("Install") { model.activateCameraExtension() }
                        .disabled(model.deviceOperationInProgress)
                    Button("Remove") { model.deactivateCameraExtension() }
                        .disabled(model.deviceOperationInProgress)
                }
                HStack {
                    Text("Audio driver")
                    Spacer()
                    Text(model.audioDriverManager.status.label).foregroundStyle(.secondary)
                    Button("Install") { model.installAudioDriver() }
                        .disabled(model.deviceOperationInProgress)
                    Button("Remove") { model.uninstallAudioDriver() }
                        .disabled(model.deviceOperationInProgress)
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
