import XCTest
@testable import AICameraCore

final class AgentListeningPolicyTests: XCTestCase {
    func testOneQuestionRequiresExplicitRearmAndConversationKeepsExistingBehavior() {
        var policy = AgentListeningPolicy()
        XCTAssertFalse(policy.requested)
        policy.start(mode: .oneQuestion)
        XCTAssertTrue(policy.requested)
        policy.utteranceEnded()
        XCTAssertFalse(policy.requested)
        policy.setRequested(true)
        XCTAssertTrue(policy.requested)
        policy.utteranceEnded()
        XCTAssertFalse(policy.requested)
        policy.start(mode: .conversation)
        policy.utteranceEnded()
        XCTAssertTrue(policy.requested)
        policy.setRequested(false)
        policy.utteranceEnded()
        XCTAssertFalse(policy.requested, "Response completion must not override the user's pause")
        policy.stop()
        XCTAssertFalse(policy.requested)
    }

    func testInputGateClosesImmediatelyAndRejectsAudioCapturedBeforeResume() {
        let gate = AgentInputGate()
        XCTAssertFalse(gate.admits(capturedAt: 10))
        gate.open(at: 10)
        XCTAssertTrue(gate.admits(capturedAt: 10))
        gate.close()
        XCTAssertFalse(gate.admits(capturedAt: 11))
        gate.open(at: 20)
        XCTAssertFalse(gate.admits(capturedAt: 19.999))
        XCTAssertTrue(gate.admits(capturedAt: 20))
        XCTAssertFalse(gate.admits(capturedAt: .nan))
        gate.open(at: .infinity)
        XCTAssertFalse(gate.admits(capturedAt: 21))
    }

    func testPauseRetiresAnUnfinishedUtteranceWithoutTimeoutOrLateVADReopeningIt() {
        var gate = RealtimeTurnGate()
        XCTAssertTrue(gate.arm(at: 1, continuous: true))
        gate.speechStarted(at: 2)
        XCTAssertTrue(gate.pauseInput())
        gate.speechStarted(at: 3)
        gate.speechStopped(at: 4)
        XCTAssertEqual(gate.phase, .paused)
        XCTAssertFalse(gate.isOpen)
        XCTAssertNil(gate.expire(at: 1_000))
        XCTAssertTrue(gate.arm(at: 1_001, continuous: true))
    }

    func testPausingWhileWorkingKeepsReplyAndToolDeadlineButInputClosed() {
        var gate = RealtimeTurnGate()
        XCTAssertTrue(gate.arm(at: 1, continuous: true))
        gate.speechStopped(at: 3)
        XCTAssertFalse(gate.pauseInput())
        XCTAssertEqual(gate.phase, .responding)
        XCTAssertEqual(gate.deadline, 123)
        XCTAssertFalse(gate.isOpen)
        XCTAssertTrue(gate.responseCompleted())
        XCTAssertTrue(gate.continueResponse(at: 5))
        XCTAssertFalse(gate.pauseInput())
        XCTAssertEqual(gate.deadline, 125)
        gate.close()
        XCTAssertFalse(gate.pauseInput())
        XCTAssertFalse(gate.arm(at: 6))
    }

    func testExistingConfigurationKeepsConversationModeAndNewSelectionRoundTrips() throws {
        var configuration = ConversationConfiguration()
        configuration.agentListeningMode = .oneQuestion
        let data = try JSONEncoder().encode(configuration)
        XCTAssertEqual(try JSONDecoder().decode(ConversationConfiguration.self, from: data).agentListeningMode, .oneQuestion)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "agentListeningMode")
        let migrated = try JSONDecoder().decode(ConversationConfiguration.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(migrated.agentListeningMode, .conversation)
    }
}
