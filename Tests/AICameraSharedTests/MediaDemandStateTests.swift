import CoreMediaIO
import Foundation
import XCTest
@testable import AICameraShared

final class MediaDemandStateTests: XCTestCase {
    func testCustomPropertyAddressContract() {
        XCTAssertEqual(
            AICameraMediaDemandState.cameraDemandProperty.rawValue,
            "4cc_aicd_glob_0000"
        )
        XCTAssertEqual(
            AICameraMediaDemandState.cameraDemandSelector,
            CMIOObjectPropertySelector(0x61696364)
        )
    }

    func testCameraSnapshotRoundTrip() throws {
        let snapshot = AICameraCameraDemandSnapshot(
            extensionRunID: UUID(uuidString: "00000000-0000-0000-0000-000000000123")!,
            generation: 42,
            sourceClientCount: 2,
            updatedAt: Date(timeIntervalSinceReferenceDate: 123_456.25)
        )
        let data = try XCTUnwrap(AICameraMediaDemandState.encodeCameraSnapshot(snapshot))
        XCTAssertFalse(data.isEmpty)
        XCTAssertLessThanOrEqual(
            data.count,
            AICameraMediaDemandState.maximumCameraSnapshotBytes
        )
        XCTAssertEqual(AICameraMediaDemandState.decodeCameraSnapshot(data), snapshot)
    }

    func testCameraSnapshotRejectsInvalidData() throws {
        XCTAssertNil(AICameraMediaDemandState.decodeCameraSnapshot(Data()))
        XCTAssertNil(AICameraMediaDemandState.decodeCameraSnapshot(Data("not-json".utf8)))
        XCTAssertNil(AICameraMediaDemandState.decodeCameraSnapshot(
            Data(
                repeating: 0,
                count: AICameraMediaDemandState.maximumCameraSnapshotBytes + 1
            )
        ))

        let negative = AICameraCameraDemandSnapshot(
            extensionRunID: UUID(),
            generation: 0,
            sourceClientCount: -1,
            updatedAt: Date()
        )
        XCTAssertNil(AICameraMediaDemandState.encodeCameraSnapshot(negative))
        let negativeData = try JSONEncoder().encode(negative)
        XCTAssertNil(AICameraMediaDemandState.decodeCameraSnapshot(negativeData))
    }

    func testCameraSnapshotRejectsNonfiniteDate() {
        let snapshot = AICameraCameraDemandSnapshot(
            extensionRunID: UUID(),
            generation: 0,
            sourceClientCount: 0,
            updatedAt: Date(timeIntervalSinceReferenceDate: .infinity)
        )
        XCTAssertNil(AICameraMediaDemandState.encodeCameraSnapshot(snapshot))
    }
}
