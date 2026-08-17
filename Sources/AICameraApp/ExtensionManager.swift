import AppKit
import Foundation
import SystemExtensions

enum CameraExtensionStatus: Equatable {
    case unknown
    case activating
    case active
    case updateAvailable
    case deactivating
    case inactive
    case needsApproval
    case pendingReboot
    case failed(String)

    var isBusy: Bool {
        self == .activating || self == .deactivating
    }

    var isInstalled: Bool {
        self == .active || self == .updateAvailable
    }

    var label: String {
        switch self {
        case .unknown: return "Unknown"
        case .activating: return "Activating…"
        case .active: return "Ready"
        case .updateAvailable: return "Update available"
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
    private var pendingActions: [ObjectIdentifier: PendingAction] = [:]

    var hasPendingRequest: Bool {
        status.isBusy || pendingActions.values.contains(where: { $0 != .query })
    }

    func refresh() {
        guard !pendingActions.values.contains(.query) else { return }
        let request = OSSystemExtensionRequest.propertiesRequest(
            forExtensionWithIdentifier: Self.bundleIdentifier,
            queue: .main
        )
        pendingActions[ObjectIdentifier(request)] = .query
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func activate() {
        guard !hasPendingRequest else { return }
        guard installedApplication else {
            status = .failed("Copy the signed app to /Applications before activating its camera extension")
            return
        }
        guard bundledExtensionExists else {
            status = .failed("The camera extension is missing from this app bundle")
            return
        }
        status = .activating
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: Self.bundleIdentifier,
            queue: .main
        )
        pendingActions[ObjectIdentifier(request)] = .activate
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func deactivate() {
        guard !hasPendingRequest else { return }
        status = .deactivating
        let request = OSSystemExtensionRequest.deactivationRequest(
            forExtensionWithIdentifier: Self.bundleIdentifier,
            queue: .main
        )
        pendingActions[ObjectIdentifier(request)] = .deactivate
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

    private var bundledExtensionURL: URL {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/SystemExtensions")
            .appendingPathComponent("\(Self.bundleIdentifier).systemextension")
    }

    private var bundledExtensionExists: Bool {
        FileManager.default.fileExists(atPath: bundledExtensionURL.path)
    }

    private var bundledExtensionVersion: String? {
        Bundle(url: bundledExtensionURL)?
            .object(forInfoDictionaryKey: kCFBundleVersionKey as String) as? String
    }

    private func bundledExtensionIsNewer(than installedVersion: String) -> Bool {
        guard let bundledExtensionVersion else { return false }
        return installedVersion.compare(bundledExtensionVersion, options: .numeric) == .orderedAscending
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
        Task { @MainActor in
            guard self.pendingActions[ObjectIdentifier(request)] == .activate else { return }
            self.status = .needsApproval
            self.openApprovalSettings()
        }
    }

    nonisolated func request(
        _ request: OSSystemExtensionRequest,
        didFinishWithResult result: OSSystemExtensionRequest.Result
    ) {
        Task { @MainActor in
            guard let action = self.pendingActions.removeValue(
                forKey: ObjectIdentifier(request)
            ) else { return }
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
            guard self.pendingActions.removeValue(
                forKey: ObjectIdentifier(request)
            ) != nil else { return }
            self.status = .failed(error.localizedDescription)
        }
    }

    nonisolated func request(
        _ request: OSSystemExtensionRequest,
        foundProperties properties: [OSSystemExtensionProperties]
    ) {
        Task { @MainActor in
            self.pendingActions.removeValue(forKey: ObjectIdentifier(request))
            guard !properties.isEmpty else {
                if self.pendingActions.values.contains(.deactivate) {
                    self.pendingActions = self.pendingActions.filter { $0.value != .deactivate }
                }
                self.status = .inactive
                return
            }
            if properties.contains(where: \.isAwaitingUserApproval) {
                self.status = .needsApproval
                return
            }
            guard let property = properties
                .filter(\.isEnabled)
                .max(by: {
                    $0.bundleVersion.compare($1.bundleVersion, options: .numeric) == .orderedAscending
                }) else {
                self.status = .inactive
                return
            }
            if self.bundledExtensionIsNewer(than: property.bundleVersion) {
                self.status = .updateAvailable
            } else {
                self.pendingActions = self.pendingActions.filter { $0.value != .activate }
                self.status = .active
            }
        }
    }
}
