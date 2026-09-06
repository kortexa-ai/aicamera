import AppKit
import AVFoundation
import SwiftUI

struct ControlCenterView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(nsImage: AppIconArtwork.image)
                    .resizable()
                    .frame(width: 28, height: 28)
                    .accessibilityHidden(true)
                Text("AI Camera")
                    .font(.headline)
                Spacer()
                Circle()
                    .fill(statusColor)
                    .frame(width: 9, height: 9)
                    .help(model.readinessDescription)
                    .accessibilityLabel(model.readinessDescription)
                Button(action: { presentSettings() }) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 14))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Settings")
                .accessibilityLabel("Settings")
                .accessibilityIdentifier("open-settings")
            }

            FeatureToolbar(model: model)

            if model.realtimeConversationActive {
                HStack {
                    Text(model.agentListening.requested ? "Agent listening enabled" : "Agent input paused")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(model.agentListening.requested ? "Pause listening" : "Ask again") {
                        model.toggleAgentListening()
                    }
                    .controlSize(.small)
                    .disabled(model.realtimeConversationState == .connecting)
                    .help("Control–Option–L. Pauses only agent input; your call microphone stays live. An unfinished question is discarded. A current answer keeps playing.")
                    .accessibilityIdentifier("toggle-agent-listening")
                }
            }

            GroupBox {
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
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .foregroundStyle(.secondary)
                    } else if model.cameraExtensionManager.status == .pendingReboot {
                        Text("Restart Mac to complete the camera extension change.")
                            .font(.caption2)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .foregroundStyle(.secondary)
                    } else if model.cameraExtensionManager.status == .active,
                              !model.cameraVirtualDeviceAvailable {
                        Text("The extension is enabled, but its camera is unavailable. Open Media Extensions in System Settings to turn AI Camera off and on, then reopen your camera app.")
                            .font(.caption2)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
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
            HStack(spacing: 4) {
                Button("Preview") { presentWindow("preview") }
                Text("·").foregroundStyle(.tertiary).accessibilityHidden(true)
                Button("Notes") { presentWindow("notes") }
                if model.canResetAgentView {
                    Text("·").foregroundStyle(.tertiary).accessibilityHidden(true)
                    Button("Reset view", action: model.resetAgentView)
                        .help("Return to the full camera and clear generated graphics. Saved notes are kept.")
                }
                Spacer()
                Button("About") { presentWindow("about") }
                Text("·").foregroundStyle(.tertiary).accessibilityHidden(true)
                Button("Quit") { AppLifecycleCoordinator.shared.quit() }
            }
            .buttonStyle(FooterActionStyle())
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
        switch model.readiness {
        case .needsAttention: return .yellow
        case .ready: return .green
        case .inUse: return .red
        }
    }

    private func presentWindow(_ id: String) {
        dismiss()
        openWindow(id: id)
        NSApp.activate(ignoringOtherApps: true)
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
        dismiss()
        NSApp.setActivationPolicy(.regular)
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

struct InputLevelMeter: View {
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

private struct FooterActionStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        FooterActionLabel(configuration: configuration)
    }

    private struct FooterActionLabel: View {
        let configuration: ButtonStyle.Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.caption)
                .foregroundStyle(hovering ? .primary : .secondary)
                .padding(.horizontal, 4)
                .padding(.vertical, 3)
                .contentShape(Rectangle())
                .opacity(configuration.isPressed ? 0.6 : 1)
                .onHover { hovering = $0 }
        }
    }
}
