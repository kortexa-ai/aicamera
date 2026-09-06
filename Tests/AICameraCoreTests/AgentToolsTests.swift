import XCTest
@testable import AICameraCore

final class AgentToolsTests: XCTestCase {
    private func parse(_ name: String, _ arguments: String) -> AgentToolCommand? {
        AgentToolCommand.parse(name: name, arguments: arguments, script: AICameraConfiguration.default.overlays.script)
    }

    func testToolArgumentsRejectUnknownFieldsInvalidIdentifiersAndCoercion() {
        XCTAssertEqual(parse("save_note", #"{"text":"Follow up tomorrow"}"#), .saveNote(text: "Follow up tomorrow", id: nil))
        XCTAssertEqual(parse("list_notes", "{}"), .listNotes(query: ""))
        XCTAssertEqual(parse("wait_for_user", "{}"), .waitForUser)
        XCTAssertEqual(parse("sleep_agent", "{}"), .sleep)
        for (name, arguments) in [
            ("save_note", #"{"text":"Remember","id":"not-an-id"}"#),
            ("save_note", #"{"text":"Remember","publish":true}"#),
            ("delete_note", #"{"id":"all"}"#),
            ("list_notes", #"{"query":false}"#),
            ("wait_for_user", #"{"unmute":true}"#),
            ("sleep_agent", "[]"),
            ("show_card", #"{"title":"Value","body":"12","ttlSeconds":true}"#),
            ("show_card", #"{"title":"Value","body":"12","ttlSeconds":301}"#),
            ("show_card", #"{"title":"Value","body":"12","position":"face"}"#),
            ("show_card", #"{"title":"Value","body":"12","html":"<script>"}"#)
        ] { XCTAssertNil(parse(name, arguments), "Accepted \(name): \(arguments)") }
    }

    func testCardDefaultsAndExactNoteIdentity() {
        XCTAssertEqual(parse("show_card", #"{"title":"Idea","body":"Take a walk."}"#),
                       .showCard(.init(title: "Idea", body: "Take a walk.")))
        let id = UUID()
        XCTAssertEqual(parse("delete_note", "{\"id\":\"\(id.uuidString)\"}"), .deleteNote(id: id))
        XCTAssertEqual(parse("save_note", "{\"text\":\"Revised\",\"id\":\"\(id.uuidString)\"}"),
                       .saveNote(text: "Revised", id: id))
    }

    func testToolCatalogExposesOnlyAvailableCapabilitiesAndValidSchemas() throws {
        let script = AICameraConfiguration.default.overlays.script
        XCTAssertTrue(AgentToolCatalog.definitions(capabilities: .init(), script: script).isEmpty)
        let controls = AgentToolCatalog.definitions(capabilities: .init(conversationControls: true), script: script)
        XCTAssertEqual(controls.compactMap { $0["name"] as? String }, ["wait_for_user", "sleep_agent"])
        let notes = AgentToolCatalog.definitions(capabilities: .init(notes: true), script: script)
        XCTAssertEqual(notes.compactMap { $0["name"] as? String }, ["save_note", "list_notes", "delete_note"])
        let all = AgentToolCatalog.definitions(capabilities: .init(visuals: true, notes: true, conversationControls: true), script: script)
        XCTAssertEqual(all.count, 10)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(all))
        for tool in all {
            let schema = try XCTUnwrap(tool["parameters"] as? [String: Any])
            XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
            let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
            let required = try XCTUnwrap(schema["required"] as? [String])
            XCTAssertTrue(Set(required).isSubset(of: Set(properties.keys)))
        }
        let prompt = AgentToolCatalog.instructions(capabilities: .init(notes: true))
        XCTAssertTrue(prompt.contains("save_note"))
        XCTAssertFalse(prompt.contains("show_card"))
        XCTAssertFalse(prompt.contains("wait_for_user"))
    }

    func testContinuationWaitsForResponseAndEveryAsynchronousToolOutput() {
        var turn = AgentToolTurn()
        XCTAssertTrue(turn.admit(callID: "save"))
        XCTAssertTrue(turn.admit(callID: "display"))
        turn.completed(callID: "save")
        XCTAssertEqual(turn.takeNext(), .waiting)
        turn.endedResponse()
        XCTAssertEqual(turn.takeNext(), .waiting)
        turn.completed(callID: "unrelated")
        XCTAssertEqual(turn.takeNext(), .waiting)
        turn.completed(callID: "display")
        XCTAssertEqual(turn.takeNext(), .continueResponse(allowTools: true))
        XCTAssertEqual(turn.takeNext(), .waiting, "Must not create a second response")
        turn.endedResponse()
        XCTAssertEqual(turn.takeNext(), .finish)
    }

    func testToolRoundsAndTotalCallsAreBoundedAcrossContinuations() {
        var rounds = AgentToolTurn()
        for round in 0..<AgentToolTurn.maximumRounds {
            let id = "call-\(round)"
            XCTAssertTrue(rounds.admit(callID: id))
            XCTAssertFalse(rounds.admit(callID: id), "Duplicate tool must not execute")
            rounds.completed(callID: id)
            rounds.endedResponse()
            XCTAssertEqual(rounds.takeNext(), .continueResponse(allowTools: round < 2))
        }
        XCTAssertFalse(rounds.admit(callID: "fourth-round"))
        rounds.endedResponse()
        XCTAssertEqual(rounds.takeNext(), .finish)

        var calls = AgentToolTurn()
        for index in 0..<AgentToolTurn.maximumCalls {
            XCTAssertTrue(calls.admit(callID: "call-\(index)"))
            calls.completed(callID: "call-\(index)")
        }
        XCTAssertFalse(calls.admit(callID: "overflow"))
        calls.endedResponse()
        XCTAssertFalse(calls.admit(callID: "late"))
        XCTAssertEqual(calls.takeNext(), .continueResponse(allowTools: false))
    }

    func testQuietToolFinishesWithoutRequestingAnotherModelResponse() {
        var turn = AgentToolTurn()
        XCTAssertTrue(turn.admit(callID: "wait"))
        turn.endedResponse()
        turn.completed(callID: "wait", quiet: true)
        XCTAssertEqual(turn.takeNext(), .finish)
        XCTAssertEqual(turn.takeNext(), .waiting)
    }
}
