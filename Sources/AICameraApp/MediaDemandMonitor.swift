import Combine
import Foundation

struct MediaDemandSnapshot: Equatable, Sendable {
    let cameraRequested: Bool
    let microphoneRequested: Bool

    static let idle = Self(cameraRequested: false, microphoneRequested: false)
}

@MainActor
final class MediaDemandMonitor: ObservableObject {
    @Published private(set) var snapshot: MediaDemandSnapshot = .idle

    var cameraRequested: Bool { snapshot.cameraRequested }
    var microphoneRequested: Bool { snapshot.microphoneRequested }

    private var timerCancellable: AnyCancellable?

    init() {
        refresh()
        timerCancellable = Timer.publish(every: 0.25, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.refresh() }
    }

    func refresh() {
        let cameraSnapshot = DeviceDiscovery.aiCameraCameraDemandSnapshot()
        let cameraSnapshotAge = cameraSnapshot.map {
            Date().timeIntervalSince($0.updatedAt)
        }
        let cameraSnapshotIsFresh = cameraSnapshotAge.map {
            $0 >= 0 && $0 <= 2
        } ?? false
        let cameraCount = cameraSnapshotIsFresh ? (cameraSnapshot?.sourceClientCount ?? 0) : 0
        let next = MediaDemandSnapshot(
            cameraRequested: cameraCount > 0,
            microphoneRequested: DeviceDiscovery.aiCameraAudioConsumerCount() > 0
        )
        if snapshot != next { snapshot = next }
    }
}
