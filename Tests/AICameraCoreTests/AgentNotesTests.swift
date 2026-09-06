import XCTest
@testable import AICameraCore

final class AgentNotesTests: XCTestCase {
    private func temporaryURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("Notes/notes.json")
    }

    func testExplicitSaveUpdateDeleteSurviveReopeningWithoutChangingIdentity() async throws {
        let url = try temporaryURL()
        let store = AgentNoteStore(fileURL: url)
        let original = try await store.save(text: "  Send the draft tomorrow.  ", now: Date(timeIntervalSince1970: 10))
        let updated = try await store.save(text: "Send the revised draft.", id: original.id, now: Date(timeIntervalSince1970: 20))
        XCTAssertEqual(updated.id, original.id)
        XCTAssertEqual(updated.createdAt, original.createdAt)
        let reopened = AgentNoteStore(fileURL: url)
        let notes = try await reopened.all()
        XCTAssertEqual(notes, [updated])
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        try await reopened.delete(id: original.id)
        let afterDelete = try await AgentNoteStore(fileURL: url).all()
        XCTAssertTrue(afterDelete.isEmpty)
    }

    func testCorruptNotebookIsNeverReplacedByANewSave() async throws {
        let url = try temporaryURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data("not a valid notebook".utf8)
        try original.write(to: url)
        let store = AgentNoteStore(fileURL: url)
        do { _ = try await store.save(text: "New note"); XCTFail("Damaged notebook was overwritten") }
        catch { XCTAssertEqual(error as? AgentNotesError, .unreadable) }
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testUnicodeByteLimitsAndCapacityFailWithoutLosingExistingNotes() async throws {
        let store = AgentNoteStore(fileURL: try temporaryURL())
        for text in [" \n ", String(repeating: "猫", count: 667), "hidden\0control"] {
            do { _ = try await store.save(text: text); XCTFail("Invalid note accepted") }
            catch { XCTAssertEqual(error as? AgentNotesError, .invalidText) }
        }
        for number in 0..<AgentNoteStore.maximumNotes { _ = try await store.save(text: "Note \(number)") }
        do { _ = try await store.save(text: "Overflow"); XCTFail("Unbounded notebook accepted") }
        catch { XCTAssertEqual(error as? AgentNotesError, .full) }
        let notes = try await store.all()
        XCTAssertEqual(notes.count, AgentNoteStore.maximumNotes)
        let updated = try await store.save(text: "An edit at capacity", id: notes[0].id)
        XCTAssertEqual(updated.text, "An edit at capacity")
    }

    func testMissingDeleteCannotAffectAnotherNote() async throws {
        let store = AgentNoteStore(fileURL: try temporaryURL())
        let note = try await store.save(text: "Keep me")
        do { try await store.delete(id: UUID()); XCTFail("Missing note delete reported success") }
        catch { XCTAssertEqual(error as? AgentNotesError, .missing) }
        let notes = try await store.all()
        XCTAssertEqual(notes, [note])
    }
}
