import AppKit
import SwiftUI

final class AppLifecycleCoordinator {
    static let shared = AppLifecycleCoordinator()

    private weak var settingsWindow: NSWindow?
    private var reminderDismissal: DispatchWorkItem?
    private lazy var reminderPanel = makeReminderPanel()

    private init() {}

    func settingsDidOpen(_ window: NSWindow) {
        settingsWindow = window
    }

    func settingsDidClose(_ window: NSWindow) {
        guard settingsWindow === window else { return }
        settingsWindow = nil
    }

    func quit() {
        reminderDismissal?.cancel()
        reminderPanel.orderOut(nil)
        NSApp.terminate(nil)
    }

    func handleSettingsQuitCommand() {
        guard let settingsWindow, settingsWindow.isVisible else {
            quit()
            return
        }

        let screen = settingsWindow.screen
        settingsWindow.performClose(nil)
        showQuitReminder(on: screen)
    }

    private func makeReminderPanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 92),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isOpaque = false
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.contentView = NSHostingView(
            rootView: QuitReminderView { [weak self] in self?.quit() }
        )
        return panel
    }

    private func showQuitReminder(on screen: NSScreen?) {
        reminderDismissal?.cancel()

        let visibleFrame = (screen ?? NSScreen.main)?.visibleFrame ?? .zero
        let panelFrame = reminderPanel.frame
        reminderPanel.setFrameOrigin(
            NSPoint(
                x: visibleFrame.maxX - panelFrame.width - 18,
                y: visibleFrame.maxY - panelFrame.height - 18
            )
        )
        reminderPanel.alphaValue = 0
        reminderPanel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            reminderPanel.animator().alphaValue = 1
        }

        let dismissal = DispatchWorkItem { [weak self] in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.2
                self.reminderPanel.animator().alphaValue = 0
            }, completionHandler: {
                self.reminderPanel.orderOut(nil)
            })
        }
        reminderDismissal = dismissal
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: dismissal)
    }
}

private struct QuitReminderView: View {
    let quit: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "camera.fill")
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 34, height: 34)
                .background(.tint.opacity(0.12), in: Circle())
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text("AI Camera is still running")
                    .font(.headline)
                Text("It remains available from the menu bar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            Button("Quit", action: quit)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityHint("Stops AI Camera and its active media processing.")
        }
        .padding(14)
        .frame(width: 360, height: 92)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(.primary.opacity(0.1), lineWidth: 1)
        )
    }
}
