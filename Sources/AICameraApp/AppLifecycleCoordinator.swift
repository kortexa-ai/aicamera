import AppKit
import SwiftUI

@MainActor
final class AICameraApplicationDelegate: NSObject, NSApplicationDelegate {
    private var terminationTask: Task<Void, Never>?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard terminationTask == nil else { return .terminateLater }
        // willTerminate is too late for async inference cancellation and native engine release.
        terminationTask = Task {
            await AppLifecycleCoordinator.shared.prepareForTermination?()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

final class AppLifecycleCoordinator {
    static let shared = AppLifecycleCoordinator()

    var prepareForTermination: (@MainActor () async -> Void)?

    private let windows = NSHashTable<NSWindow>.weakObjects()
    private var reminderDismissal: DispatchWorkItem?
    private lazy var reminderPanel = makeReminderPanel()

    private init() {}

    func windowDidOpen(_ window: NSWindow) {
        guard !windows.contains(window) else { return }
        windows.add(window)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowDidClose(_ window: NSWindow) {
        windows.remove(window)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.windows.allObjects.isEmpty else { return }
            NSApp.setActivationPolicy(.accessory)
        }
    }

    func quit() {
        reminderDismissal?.cancel()
        reminderPanel.orderOut(nil)
        // Enter AppKit termination from a run-loop event, after any Swift main-executor job
        // returns. Its modal termination loop must remain able to run async cleanup.
        NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0,
                      inModes: [.default])
    }

    func handleWindowQuitCommand() {
        let visible = windows.allObjects.filter { $0.isVisible || $0.isMiniaturized }
        guard let window = visible.first(where: { $0.isKeyWindow }) ?? visible.first else {
            quit()
            return
        }

        let screen = window.screen
        window.performClose(nil)
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
            Image(nsImage: AppIconArtwork.image)
                .resizable()
                .frame(width: 40, height: 40)
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
