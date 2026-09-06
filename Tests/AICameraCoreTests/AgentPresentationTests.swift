import XCTest
@testable import AICameraCore

final class AgentPresentationTests: XCTestCase {
    func testTimerUsesElapsedTimeAndStableIdentityThroughCompletion() throws {
        let state = AgentPresentationState()
        let request = try XCTUnwrap(AgentTimerRequest(durationSeconds: 120, label: "Discussion"))
        let first = try XCTUnwrap(state.startTimer(request, at: 100))
        XCTAssertEqual(first.content.body, "2:00")
        XCTAssertEqual(first.revision, 120)
        XCTAssertEqual(state.cards(at: 100.99), [first])
        let next = try XCTUnwrap(state.cards(at: 101).first)
        XCTAssertEqual(next.id, first.id)
        XCTAssertEqual(next.content.body, "1:59")
        XCTAssertEqual(next.revision, 119)
        XCTAssertEqual(next.positioned(.upperRight).revision, 119)
        XCTAssertEqual(state.cards(at: 219.999).first?.content.body, "0:01")
        let finished = try XCTUnwrap(state.cards(at: 220).first)
        XCTAssertEqual(finished.id, first.id)
        XCTAssertEqual(finished.content.body, "Time’s up")
        XCTAssertEqual(finished.revision, 0)
        XCTAssertEqual(state.cards(at: 224.99), [finished])
        XCTAssertTrue(state.cards(at: 225).isEmpty)
        XCTAssertTrue(state.cards(at: 99).isEmpty)
        XCTAssertTrue(state.cards(at: .nan).isEmpty)
        XCTAssertTrue(state.cards(at: .infinity).isEmpty)
    }

    func testTimerReplacementClearAndResetDoNotLeaveDormantCountdowns() throws {
        let state = AgentPresentationState()
        let request = try XCTUnwrap(AgentTimerRequest(durationSeconds: 3_600))
        let initialCard = try XCTUnwrap(state.show(.init(title: "Before", body: "Card"), at: 99))
        let first = try XCTUnwrap(state.startTimer(request, at: 100))
        XCTAssertNotEqual(initialCard.id, first.id)
        XCTAssertEqual(first.content.body, "60:00")
        let replacement = try XCTUnwrap(state.startTimer(request, at: 101))
        XCTAssertNotEqual(first.id, replacement.id)
        let card = try XCTUnwrap(state.show(.init(title: "After", body: "Card", ttlSeconds: 2), at: 102))
        XCTAssertEqual(state.cards(at: 103), [card])
        XCTAssertTrue(state.cards(at: 104).isEmpty, "Expired card must not reveal the replaced timer")
        state.startTimer(request, at: 105)
        state.clear()
        XCTAssertTrue(state.cards(at: 106).isEmpty)
        state.startTimer(request, at: 107)
        state.showCameraInset(try XCTUnwrap(AgentCameraInsetRequest()), at: 107)
        state.reset()
        XCTAssertTrue(state.cards(at: 108).isEmpty)
        XCTAssertNil(state.cameraInset(at: 108))
    }

    func testTimerRejectsInvalidInputsWithoutReplacingExistingContent() throws {
        for duration in [Int.min, -1, 0, 3_601, Int.max] {
            XCTAssertNil(AgentTimerRequest(durationSeconds: duration))
        }
        for label in ["", " \n", "Hidden\0label", String(repeating: "猫", count: 27)] {
            XCTAssertNil(AgentTimerRequest(durationSeconds: 1, label: label))
        }
        let request = try XCTUnwrap(AgentTimerRequest(durationSeconds: 1, label: String(repeating: "a", count: 80)))
        let state = AgentPresentationState()
        let original = try XCTUnwrap(state.startTimer(request, at: 10))
        for now in [-1, .nan, .infinity, -.infinity, .greatestFiniteMagnitude] as [TimeInterval] {
            XCTAssertNil(state.startTimer(request, at: now))
        }
        XCTAssertNil(state.show(.init(title: "Invalid", body: "", ttlSeconds: 30), at: 10))
        XCTAssertEqual(state.cards(at: 10), [original])
    }

    func testCardReplacementExpiryAndClearAreIndependentOfSavedNotes() throws {
        let state = AgentPresentationState()
        let first = try XCTUnwrap(state.show(.init(title: "First", body: "One", ttlSeconds: 10), at: 100))
        XCTAssertEqual(state.cards(at: 109), [first])
        XCTAssertTrue(state.cards(at: 110).isEmpty)
        let second = try XCTUnwrap(state.show(.init(title: "Second", body: "Two"), at: 111))
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(state.cards(at: 112), [second])
        state.clear()
        XCTAssertTrue(state.cards(at: 112).isEmpty)
    }

    func testRejectedCardCannotReplaceVisibleContent() throws {
        let state = AgentPresentationState()
        let original = try XCTUnwrap(state.show(.init(title: "Keep", body: "Visible"), at: 20))
        for invalid in [
            AgentCardRequest(title: " ", body: "Text"),
            .init(title: "Title", body: String(repeating: "猫", count: 401)),
            .init(title: "Title", body: "Hidden\0control"),
            .init(title: "Title", body: "Text", source: ""),
            .init(title: "Title", body: "Text", ttlSeconds: .infinity),
            .init(title: "Title", body: "Text", ttlSeconds: 0)
        ] { XCTAssertNil(state.show(invalid, at: 21)) }
        XCTAssertNil(state.show(.init(title: "Title", body: "Text"), at: .nan))
        XCTAssertEqual(state.cards(at: 21), [original])
    }
}
