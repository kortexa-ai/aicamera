import XCTest
@testable import AICameraCore

final class DemandLifecycleTests: XCTestCase {
    func testCameraAndMicrophoneDemandAreIndependent() {
        XCTAssertEqual(
            MediaDemandDecision.resolve(
                configurationUsable: true,
                cameraRequested: true,
                cameraAvailable: true,
                cameraAuthorized: true,
                microphoneRequested: false,
                microphoneAvailable: true,
                microphoneAuthorized: true
            ),
            MediaDemandDecision(cameraShouldRun: true, microphoneShouldRun: false)
        )

        XCTAssertEqual(
            MediaDemandDecision.resolve(
                configurationUsable: true,
                cameraRequested: false,
                cameraAvailable: true,
                cameraAuthorized: true,
                microphoneRequested: true,
                microphoneAvailable: true,
                microphoneAuthorized: true
            ),
            MediaDemandDecision(cameraShouldRun: false, microphoneShouldRun: true)
        )
    }

    func testDemandRequiresInstalledDeviceAndAuthorization() {
        XCTAssertEqual(
            MediaDemandDecision.resolve(
                configurationUsable: true,
                cameraRequested: true,
                cameraAvailable: false,
                cameraAuthorized: true,
                microphoneRequested: true,
                microphoneAvailable: true,
                microphoneAuthorized: false
            ),
            MediaDemandDecision(cameraShouldRun: false, microphoneShouldRun: false)
        )
    }

    func testInvalidConfigurationBlocksBothLanes() {
        XCTAssertEqual(
            MediaDemandDecision.resolve(
                configurationUsable: false,
                cameraRequested: true,
                cameraAvailable: true,
                cameraAuthorized: true,
                microphoneRequested: true,
                microphoneAvailable: true,
                microphoneAuthorized: true
            ),
            MediaDemandDecision(cameraShouldRun: false, microphoneShouldRun: false)
        )
    }

    func testBothLanesCanRunAndDrainTogether() {
        XCTAssertEqual(
            MediaDemandDecision.resolve(
                configurationUsable: true,
                cameraRequested: true,
                cameraAvailable: true,
                cameraAuthorized: true,
                microphoneRequested: true,
                microphoneAvailable: true,
                microphoneAuthorized: true
            ),
            MediaDemandDecision(cameraShouldRun: true, microphoneShouldRun: true)
        )
        XCTAssertEqual(
            MediaDemandDecision.resolve(
                configurationUsable: true,
                cameraRequested: false,
                cameraAvailable: true,
                cameraAuthorized: true,
                microphoneRequested: false,
                microphoneAvailable: true,
                microphoneAuthorized: true
            ),
            MediaDemandDecision(cameraShouldRun: false, microphoneShouldRun: false)
        )
    }


    func testIdleCameraAndMicrophoneTestsBecomeLocalDemand() {
        XCTAssertEqual(
            MediaTestDemandDecision.resolve(
                cameraClientRequested: false,
                microphoneClientRequested: false,
                cameraTestRequested: true,
                microphoneTestRequested: true
            ),
            MediaTestDemandDecision(
                cameraRequested: true,
                microphoneRequested: true,
                cameraTestActive: true,
                microphoneTestActive: true
            )
        )
    }

    func testAnyExternalClientCancelsBothLocalTests() {
        XCTAssertEqual(
            MediaTestDemandDecision.resolve(
                cameraClientRequested: true,
                microphoneClientRequested: false,
                cameraTestRequested: true,
                microphoneTestRequested: true
            ),
            MediaTestDemandDecision(
                cameraRequested: true,
                microphoneRequested: false,
                cameraTestActive: false,
                microphoneTestActive: false
            )
        )
        XCTAssertEqual(
            MediaTestDemandDecision.resolve(
                cameraClientRequested: false,
                microphoneClientRequested: true,
                cameraTestRequested: true,
                microphoneTestRequested: false
            ),
            MediaTestDemandDecision(
                cameraRequested: false,
                microphoneRequested: true,
                cameraTestActive: false,
                microphoneTestActive: false
            )
        )
    }
}
