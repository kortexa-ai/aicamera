import CoreMediaIO
import Foundation

struct AICameraCameraDemandSnapshot: Codable, Equatable, Sendable {
    let extensionRunID: UUID
    let generation: UInt64
    // CoreMediaIO starts a source stream for its first client and stops it after the last,
    // so this is aggregate stream demand (normally 0 or 1), not client cardinality.
    let sourceClientCount: Int
    let updatedAt: Date
}

enum AICameraMediaDemandState {
    static let cameraDemandProperty = CMIOExtensionProperty(
        rawValue: "4cc_aicd_glob_0000"
    )
    static let cameraDemandSelector = CMIOObjectPropertySelector(0x61696364) // 'aicd'
    static let maximumCameraSnapshotBytes = 4_096

    static func encodeCameraSnapshot(_ snapshot: AICameraCameraDemandSnapshot) -> Data? {
        guard snapshot.sourceClientCount >= 0,
              snapshot.updatedAt.timeIntervalSinceReferenceDate.isFinite,
              let data = try? JSONEncoder().encode(snapshot),
              !data.isEmpty,
              data.count <= maximumCameraSnapshotBytes else { return nil }
        return data
    }

    static func decodeCameraSnapshot(_ data: Data) -> AICameraCameraDemandSnapshot? {
        guard !data.isEmpty,
              data.count <= maximumCameraSnapshotBytes,
              let snapshot = try? JSONDecoder().decode(
                  AICameraCameraDemandSnapshot.self,
                  from: data
              ),
              snapshot.sourceClientCount >= 0,
              snapshot.updatedAt.timeIntervalSinceReferenceDate.isFinite else { return nil }
        return snapshot
    }
}
