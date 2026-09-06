import XCTest
@testable import AICameraCore

final class DemandLifecycleTests: XCTestCase {
    func testAgentCanUseTheMicrophoneDuringACameraOnlyCallAndReleaseOnlyItsDemand() {
        func decision(agent: Bool, callMicrophone: Bool) -> MediaDemandDecision {
            MediaDemandDecision.resolve(configurationUsable: true,
                cameraRequested: true, cameraAvailable: true, cameraAuthorized: true,
                microphoneRequested: callMicrophone, microphoneAvailable: true, microphoneAuthorized: true,
                agentMicrophoneRequested: agent)
        }
        XCTAssertEqual(decision(agent: true, callMicrophone: false),
                       .init(cameraShouldRun: true, microphoneShouldRun: true))
        XCTAssertEqual(decision(agent: false, callMicrophone: false),
                       .init(cameraShouldRun: true, microphoneShouldRun: false))
        XCTAssertEqual(decision(agent: false, callMicrophone: true),
                       .init(cameraShouldRun: true, microphoneShouldRun: true))
    }

    func testPrivacyMuteOverridesBothAgentAndCallDemandWithoutStoppingVideo() {
        let decision = MediaDemandDecision.resolve(configurationUsable: true,
            cameraRequested: true, cameraAvailable: true, cameraAuthorized: true,
            microphoneRequested: true, microphoneAvailable: true, microphoneAuthorized: true,
            agentMicrophoneRequested: true, microphoneMuted: true)
        XCTAssertEqual(decision, .init(cameraShouldRun: true, microphoneShouldRun: false))
    }

    func testAgentStillRequiresMicrophoneAuthorizationAndAUsableConfiguration() {
        for (configuration, authorized) in [(false, true), (true, false)] {
            let decision = MediaDemandDecision.resolve(configurationUsable: configuration,
                cameraRequested: false, cameraAvailable: true, cameraAuthorized: true,
                microphoneRequested: false, microphoneAvailable: true, microphoneAuthorized: authorized,
                agentMicrophoneRequested: true)
            XCTAssertFalse(decision.microphoneShouldRun)
        }
    }

    func testCallRoutingChangesRequireAnExplicitAgentRestart() {
        XCTAssertTrue(MediaDemandDecision.agentRequiresRouteRestart(previousPublication: false, clientRequested: true, agentRequested: true))
        XCTAssertTrue(MediaDemandDecision.agentRequiresRouteRestart(previousPublication: true, clientRequested: false, agentRequested: true))
        XCTAssertFalse(MediaDemandDecision.agentRequiresRouteRestart(previousPublication: true, clientRequested: true, agentRequested: true))
        XCTAssertFalse(MediaDemandDecision.agentRequiresRouteRestart(previousPublication: nil, clientRequested: true, agentRequested: true))
        XCTAssertFalse(MediaDemandDecision.agentRequiresRouteRestart(previousPublication: false, clientRequested: true, agentRequested: false))
    }

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
