import AppKit
import Foundation
import SystemExtensions

enum CameraExtensionStatus: Equatable {
    case unknown
    case activating
    case active
    case deactivating
    case inactive
    case needsApproval
    case pendingReboot
    case failed(String)

    var isBusy: Bool {
        self == .activating || self == .deactivating
    }

    var label: String {
        switch self {
        case .unknown: return "Unknown"
        case .activating: return "Activating…"
        case .active: return "Ready"
        case .deactivating: return "Deactivating…"
        case .inactive: return "Not installed"
        case .needsApproval: return "Approval required"
        case .pendingReboot: return "Pending reboot"
        case let .failed(message): return "Failed: \(message)"
        }
    }
}

@MainActor
final class CameraExtensionManager: NSObject, ObservableObject {
    static let bundleIdentifier = "ai.kortexa.aicamera.camera-extension"

    @Published private(set) var status: CameraExtensionStatus = .unknown
    private enum PendingAction: Equatable { case query, activate, deactivate }
    private var pendingAction: PendingAction?

    var hasPendingRequest: Bool { pendingAction != nil || status.isBusy }

    func refresh() {
        guard pendingAction == nil, !status.isBusy else { return }
        pendingAction = .query
        let request = OSSystemExtensionRequest.propertiesRequest(
            forExtensionWithIdentifier: Self.bundleIdentifier,
            queue: .main
        )
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func activate() {
        guard pendingAction == nil, !status.isBusy else { return }
        guard installedApplication else {
            status = .failed("Copy the signed app to /Applications before activating its camera extension")
            return
        }
        guard bundledExtensionExists else {
            status = .failed("The camera extension is missing from this app bundle")
            return
        }
        status = .activating
        pendingAction = .activate
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: Self.bundleIdentifier,
            queue: .main
        )
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func deactivate() {
        guard pendingAction == nil, !status.isBusy else { return }
        status = .deactivating
        pendingAction = .deactivate
        let request = OSSystemExtensionRequest.deactivationRequest(
            forExtensionWithIdentifier: Self.bundleIdentifier,
            queue: .main
        )
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func openApprovalSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    private var installedApplication: Bool {
        Bundle.main.bundleURL.standardizedFileURL.path.hasPrefix("/Applications/")
    }

    private var bundledExtensionExists: Bool {
        let url = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/SystemExtensions")
            .appendingPathComponent("\(Self.bundleIdentifier).systemextension")
        return FileManager.default.fileExists(atPath: url.path)
    }
}

extension CameraExtensionManager: OSSystemExtensionRequestDelegate {
    nonisolated func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension ext: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }

    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        Task { @MainActor in self.status = .needsApproval }
    }

    nonisolated func request(
        _ request: OSSystemExtensionRequest,
        didFinishWithResult result: OSSystemExtensionRequest.Result
    ) {
        Task { @MainActor in
            let action = self.pendingAction
            self.pendingAction = nil
            switch result {
            case .completed:
                if action == .activate || action == .deactivate {
                    self.refresh()
                }
            case .willCompleteAfterReboot:
                self.status = .pendingReboot
            @unknown default:
                self.status = .unknown
            }
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        Task { @MainActor in
            self.pendingAction = nil
            self.status = .failed(error.localizedDescription)
        }
    }

    nonisolated func request(
        _ request: OSSystemExtensionRequest,
        foundProperties properties: [OSSystemExtensionProperties]
    ) {
        Task { @MainActor in
            self.pendingAction = nil
            guard let property = properties.first else {
                self.status = .inactive
                return
            }
            if property.isAwaitingUserApproval {
                self.status = .needsApproval
            } else {
                self.status = property.isEnabled ? .active : .inactive
            }
        }
    }
}
