import AppKit
import SwiftUI

struct ControlCenterView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("AI Camera", systemImage: "camera.aperture")
                    .font(.headline)
                Spacer()
                Circle()
                    .fill(model.isRunning ? Color.green : Color.secondary)
                    .frame(width: 9, height: 9)
                Text(model.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.black)
                    .aspectRatio(16 / 9, contentMode: .fit)
                if let image = model.previewImage {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: "camera.fill")
                            .font(.largeTitle)
                        Text("Preview is off")
                            .font(.caption)
                    }
                    .foregroundStyle(.white.opacity(0.55))
                }
            }

            HStack(spacing: 8) {
                Button(model.isRunning ? "Stop Proxy" : "Start Proxy") {
                    model.isRunning ? model.stop() : model.start()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.space, modifiers: [])
                .disabled(model.isStopping)
                Spacer()
                Button {
                    openSettingsWindow()
                } label: {
                    Image(systemName: "gearshape")
                }
                .help("Settings")
                .accessibilityLabel("Open Settings")
                .accessibilityIdentifier("open-settings")
            }

            Divider()

            DeviceStatusRow(
                title: "Virtual camera",
                status: model.cameraExtensionManager.status.label,
                installed: model.cameraExtensionManager.status == .active,
                busy: model.deviceOperationInProgress,
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

            if let error = model.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            if model.cameraExtensionManager.status == .needsApproval {
                Button("Open Extension Settings") {
                    model.cameraExtensionManager.openApprovalSettings()
                }
                .controlSize(.small)
            }

            Divider()
            HStack {
                Text(model.configurationController.configuration.profileName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .controlSize(.small)
            }
        }
        .padding(14)
        .frame(width: 420)
        .task { model.refreshDevicesAndDrivers() }
    }

    private func openSettingsWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if !NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) {
            _ = NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }
}

struct DeviceStatusRow: View {
    let title: String
    let status: String
    let installed: Bool
    let busy: Bool
    let install: () -> Void
    let uninstall: () -> Void

    var body: some View {
        HStack {
            Circle()
                .fill(installed ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption).fontWeight(.medium)
                Text(status).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button(installed ? "Remove" : "Install", action: installed ? uninstall : install)
                .controlSize(.small)
                .disabled(busy)
        }
    }
}
