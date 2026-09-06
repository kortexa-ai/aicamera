import AICameraCore
import Combine
import Foundation

@MainActor
final class AgentNotesController: ObservableObject {
    @Published private(set) var notes: [AgentNote] = []
    @Published private(set) var error: String?
    let store: AgentNoteStore

    init(fileURL: URL? = nil) {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        store = AgentNoteStore(fileURL: fileURL ?? root.appendingPathComponent("AI Camera/Notes/notes.json"))
    }

    func refresh() async {
        do { notes = try await store.all(); error = nil }
        catch { self.error = error.localizedDescription }
    }

    @discardableResult
    func save(text: String, id: UUID? = nil) async throws -> AgentNote {
        do {
            let note = try await store.save(text: text, id: id)
            await refresh()
            return note
        } catch { self.error = error.localizedDescription; throw error }
    }

    func delete(id: UUID) async throws {
        do { try await store.delete(id: id); await refresh() }
        catch { self.error = error.localizedDescription; throw error }
    }
}
