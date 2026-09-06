import AppKit
import SwiftUI

/// Every standalone window participates in one Dock policy; closing one must not hide the others.
struct AppWindowLifecycle: NSViewRepresentable {
    var onClose: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(onClose: onClose) }
    func makeNSView(context: Context) -> WindowTrackingView {
        let view = WindowTrackingView()
        view.onWindowChange = { context.coordinator.attach(to: $0) }
        return view
    }
    func updateNSView(_ nsView: WindowTrackingView, context: Context) {}
    static func dismantleNSView(_ nsView: WindowTrackingView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator {
        private weak var window: NSWindow?
        private var observers: [NSObjectProtocol] = []
        private let onClose: () -> Void

        init(onClose: @escaping () -> Void) { self.onClose = onClose }

        func attach(to window: NSWindow?) {
            guard let window, self.window !== window else { return }
            detach()
            self.window = window
            AppLifecycleCoordinator.shared.windowDidOpen(window)
            observers.append(NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { [weak self, weak window] _ in
                guard let self, let window else { return }
                self.onClose()
                AppLifecycleCoordinator.shared.windowDidClose(window)
            })
            // SwiftUI can retain a Window's content after closing it. Track its next opening too.
            observers.append(NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
            ) { [weak window] _ in
                if let window { AppLifecycleCoordinator.shared.windowDidOpen(window) }
            })
        }

        func detach() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            if let window { AppLifecycleCoordinator.shared.windowDidClose(window) }
            window = nil
        }
    }
}

final class WindowTrackingView: NSView {
    var onWindowChange: ((NSWindow?) -> Void)?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?(window)
    }
}
