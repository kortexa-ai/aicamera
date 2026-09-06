import XCTest
@testable import AICameraCore

final class AgentPresentationTests: XCTestCase {
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
