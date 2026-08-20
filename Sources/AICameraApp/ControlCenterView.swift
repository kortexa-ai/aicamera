import AppKit
import AVFoundation
import SwiftUI

struct ControlCenterView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("AI Camera", systemImage: "camera.aperture")
                    .font(.headline)
                Spacer()
                Circle()
                    .fill(statusColor)
                    .frame(width: 9, height: 9)
                Text(model.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ZStack {
                Color.black
                if let image = model.previewImage {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: model.cameraIsActive ? "camera.fill" : "camera")
                            .font(.largeTitle)
                        Text(previewMessage)
                            .font(.caption)
                    }
                    .foregroundStyle(.white.opacity(0.6))
                }
            }
            // The popup has a fixed 420-point width and 14-point padding.
            // Keep an explicit 16:9 height so flexible preview images cannot
            // collapse this view during the transition from the placeholder.
            .frame(maxWidth: .infinity)
            .frame(height: 220.5)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            HStack(spacing: 8) {
                Button(action: model.toggleCameraTest) {
                    Label(
                        model.cameraTestActive ? "Stop testing" : "Test camera",
                        systemImage: model.cameraTestActive ? "stop.fill" : "video.fill"
                    )
                    .frame(maxWidth: .infinity)
                }
                .disabled(!model.cameraTestActive && !model.canStartCameraTest)
                .tint(model.cameraTestActive ? .red : .accentColor)
                .help("Test the resolved camera while both virtual devices are idle.")
                .accessibilityLabel(
                    model.cameraTestActive ? "Stop camera testing" : "Test camera"
                )

                Button(action: model.toggleMicrophoneTest) {
                    Label(
                        model.microphoneTestActive ? "Stop testing" : "Test microphone",
                        systemImage: model.microphoneTestActive ? "stop.fill" : "mic.fill"
                    )
                    .frame(maxWidth: .infinity)
                }
                .disabled(!model.microphoneTestActive && !model.canStartMicrophoneTest)
                .tint(model.microphoneTestActive ? .red : .accentColor)
                .help("Test the resolved microphone while both virtual devices are idle.")
                .accessibilityLabel(
                    model.microphoneTestActive ? "Stop microphone testing" : "Test microphone"
                )
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            if model.cameraTestActive, model.scriptOverlayEnabled {
                GroupBox("Overlay script") {
                    VStack(alignment: .leading, spacing: 6) {
                        TextField(
                            "three.js script — try: AICamera.onFrame(dt => { AICamera.scene.rotation.y += dt })",
                            text: $model.overlayScriptDraft,
                            axis: .vertical
                        )
                        .font(.system(.caption2, design: .monospaced))
                        .lineLimit(3...8)
                        HStack {
                            Button("Render") { model.loadOverlayScript(model.overlayScriptDraft) }
                                .controlSize(.small)
                            Button("Clear") { model.clearOverlayScript() }
                                .controlSize(.small)
                            Spacer()
                        }
                        if let log = model.overlayScriptLog {
                            Text(log)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                }
            }

            if model.microphoneTestActive {
                InputLevelMeter(level: model.microphoneInputLevel)
            }

            GroupBox("Virtual devices") {
                VStack(spacing: 8) {
                    DeviceSetupRow(
                        title: "Camera",
                        status: model.cameraVirtualDeviceStatusText,
                        source: "Input: \(model.cameraSourceText)",
                        warning: model.cameraSourceWarning,
                        settingsHelp: "Camera settings",
                        settingsAction: model.cameraSourceAvailable
                            ? { presentSettings(.general, lane: .camera) }
                            : nil,
                        ready: model.cameraVirtualDeviceIsReady,
                        actionTitle: cameraActionTitle,
                        busy: model.deviceOperationInProgress
                            && model.cameraExtensionManager.status != .needsApproval,
                        action: cameraAction
                    )
                    DeviceSetupRow(
                        title: "Microphone",
                        status: model.audioDriverManager.status.label,
                        source: "Input: \(model.microphoneSourceText)",
                        warning: model.microphoneSourceWarning,
                        settingsHelp: "Microphone settings",
                        settingsAction: model.microphoneSourceAvailable
                            ? { presentSettings(.general, lane: .microphone) }
                            : nil,
                        ready: model.audioDriverManager.status == .installed,
                        actionTitle: audioActionTitle,
                        busy: model.deviceOperationInProgress,
                        action: model.installAudioDriver
                    )
                    if model.cameraExtensionManager.status == .needsApproval {
                        Text("Enable AI Camera in System Settings → General → Login Items & Extensions → Media Extensions. Settings should open automatically.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else if model.cameraExtensionManager.status == .pendingReboot {
                        Text("Restart Mac to complete the camera extension change.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else if model.cameraExtensionManager.status == .active,
                              !model.cameraVirtualDeviceAvailable {
                        Text("The extension is active, but macOS is not publishing AI Camera. Restart Mac to finish extension cleanup, then check again.")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
            }

            if model.cameraExtensionManager.status.isInstalled,
               model.cameraAuthorization != .authorized {
                PermissionRow(
                    title: "Camera access",
                    status: permissionLabel(model.cameraAuthorization),
                    actionTitle: permissionActionTitle(model.cameraAuthorization),
                    action: model.cameraAuthorization == .denied
                        ? model.openCameraPrivacySettings
                        : model.requestCameraAccess
                )
            }
            if model.audioDriverManager.status.isInstalled,
               model.microphoneAuthorization != .authorized {
                PermissionRow(
                    title: "Microphone access",
                    status: permissionLabel(model.microphoneAuthorization),
                    actionTitle: permissionActionTitle(model.microphoneAuthorization),
                    action: model.microphoneAuthorization == .denied
                        ? model.openMicrophonePrivacySettings
                        : model.requestMicrophoneAccess
                )
            }

            Divider()

            HStack {
                Label(processingLabel, systemImage: processingIcon)
                .font(.caption)
                .foregroundStyle(.secondary)
                Spacer()
                Button(action: { presentSettings() }) {
                    Label("Settings", systemImage: "gearshape")
                }
                .controlSize(.small)
                .accessibilityIdentifier("open-settings")
            }

            if let error = panelError {
                VStack(alignment: .leading, spacing: 6) {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                    HStack {
                        if !model.configurationController.isConfigurationUsable {
                            Button("Repair Profile") { presentSettings(.advanced) }
                        }
                        if model.currentError != nil {
                            Button("Retry") { model.retryDemand() }
                        }
                    }
                    .controlSize(.small)
                }
            }

            Divider()
            HStack {
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .controlSize(.small)
            }
        }
        .padding(14)
        .frame(width: 420)
        .task { model.refreshDevicesAndDrivers() }
    }

    private var panelError: String? {
        model.currentError
            ?? model.configurationController.validationMessage
    }

    private var statusColor: Color {
        if model.currentError != nil || !model.configurationController.isConfigurationUsable {
            return .red
        }
        if model.isRunning { return .green }
        if setupNeedsAttention
            || model.cameraSourceWarning != nil
            || model.microphoneSourceWarning != nil
            || (model.cameraExtensionManager.status.isInstalled && model.cameraAuthorization == .denied)
            || (model.audioDriverManager.status.isInstalled && model.microphoneAuthorization == .denied) {
            return .orange
        }
        return .secondary
    }

    private var previewMessage: String {
        if model.cameraTestActive { return "Starting camera test…" }
        if model.demandMonitor.cameraRequested { return "Starting camera…" }
        if !model.cameraExtensionManager.status.isInstalled { return "Install the virtual camera to begin" }
        return "Waiting for a camera client"
    }

    private var setupNeedsAttention: Bool {
        (!model.cameraExtensionManager.status.isInstalled && !model.audioDriverManager.status.isInstalled)
            || model.cameraExtensionManager.status == .needsApproval
            || model.cameraExtensionManager.status == .pendingReboot
            || model.cameraExtensionManager.status == .updateAvailable
            || model.audioDriverManager.status == .updateAvailable
            || model.audioDriverManager.status == .installedNeedsReload
    }

    private var cameraActionTitle: String? {
        switch model.cameraExtensionManager.status {
        case .inactive, .failed(_): return "Install"
        case .updateAvailable: return "Update"
        case .needsApproval: return "Open Settings"
        default: return nil
        }
    }

    private var cameraAction: () -> Void {
        if model.cameraExtensionManager.status == .needsApproval {
            return model.cameraExtensionManager.openApprovalSettings
        }
        return model.activateCameraExtension
    }

    private var audioActionTitle: String? {
        switch model.audioDriverManager.status {
        case .notInstalled, .failed(_): return "Install"
        case .updateAvailable: return "Update"
        case .installedNeedsReload: return "Repair"
        default: return nil
        }
    }

    private var processingLabel: String {
        if model.hasConfiguredAIFeatures { return "AI processing configured" }
        return model.isPurePassthrough ? "Pure passthrough" : "AI off — local effects configured"
    }

    private var processingIcon: String {
        model.hasConfiguredAIFeatures ? "sparkles" : "arrow.left.arrow.right"
    }

    private func permissionActionTitle(_ status: AVAuthorizationStatus) -> String? {
        switch status {
        case .notDetermined: return "Allow"
        case .denied: return "Open Settings"
        default: return nil
        }
    }

    private func permissionLabel(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "Not requested"
        case .denied: return "Denied"
        case .restricted: return "Restricted"
        case .authorized: return "Allowed"
        @unknown default: return "Unknown"
        }
    }

    private func presentSettings(
        _ page: AICameraSettingsPage? = nil,
        lane: AICameraSettingsLane? = nil
    ) {
        if let page { model.selectSettings(page: page, lane: lane) }
        NSApp.activate(ignoringOtherApps: true)
        openSettings()
    }

}

private struct DeviceSetupRow: View {
    let title: String
    let status: String
    let source: String
    let warning: String?
    let settingsHelp: String
    let settingsAction: (() -> Void)?
    let ready: Bool
    let actionTitle: String?
    let busy: Bool
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            Circle()
                .fill(ready ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(title).font(.caption).fontWeight(.medium)
                    Text(status).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                HStack(spacing: 4) {
                    Text(source)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .help(source)
                    if let settingsAction {
                        Button(action: settingsAction) {
                            Image(systemName: "gearshape")
                                .font(.caption2)
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.mini)
                        .help(settingsHelp)
                        .accessibilityLabel(settingsHelp)
                    }
                }
                if let warning {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            if let actionTitle {
                Button(actionTitle, action: action)
                    .controlSize(.small)
                    .disabled(busy)
            }
        }
    }
}

private struct InputLevelMeter: View {
    let level: Float

    var body: some View {
        HStack(spacing: 8) {
            Label("Input level", systemImage: "waveform")
                .font(.caption)
                .foregroundStyle(.secondary)
            ProgressView(value: Double(min(1, max(0, level))))
                .progressViewStyle(.linear)
                .accessibilityValue("\(Int(min(1, max(0, level)) * 100)) percent")
        }
    }
}

private struct PermissionRow: View {
    let title: String
    let status: String
    let actionTitle: String?
    let action: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption).fontWeight(.medium)
                Text(status).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            if let actionTitle {
                Button(actionTitle, action: action).controlSize(.small)
            }
        }
    }
}

struct DeviceStatusRow: View {
    let title: String
    let status: String
    let ready: Bool
    let busy: Bool
    let actionTitle: String?
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            Circle()
                .fill(ready ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption).fontWeight(.medium)
                Text(status).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if let actionTitle {
                Button(actionTitle, action: action)
                    .controlSize(.small)
                    .disabled(busy)
            }
        }
    }
}
