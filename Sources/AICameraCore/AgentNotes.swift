import Foundation

public struct AgentNote: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var text: String
    public let createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), text: String, createdAt: Date = Date(), updatedAt: Date? = nil) {
        self.id = id; self.text = text; self.createdAt = createdAt; self.updatedAt = updatedAt ?? createdAt
    }
}

public enum AgentNotesError: Error, LocalizedError, Equatable {
    case invalidText, full, missing, unreadable
    public var errorDescription: String? {
        switch self {
        case .invalidText: return "A note needs 1–2,000 bytes of text."
        case .full: return "Your notebook is full. Remove a note before adding another."
        case .missing: return "That note is no longer in your notebook."
        case .unreadable: return "Your notebook could not be opened. Its saved contents have been left untouched."
        }
    }
}

/// Only explicitly requested note text is persisted, never media or conversation transcripts.
/// File I/O is actor-isolated and never runs on a capture or render callback.
public actor AgentNoteStore {
    public static let maximumNotes = 100
    public static let maximumTextBytes = 2_000
    private static let maximumFileBytes = 512 * 1_024
    private struct Document: Codable { let version: Int; var notes: [AgentNote] }
    private let fileURL: URL
    private var document: Document?

    public init(fileURL: URL) { self.fileURL = fileURL }

    public func all() throws -> [AgentNote] {
        try load().notes.sorted { $0.updatedAt > $1.updatedAt }
    }

    @discardableResult
    public func save(text: String, id: UUID? = nil, now: Date = Date()) throws -> AgentNote {
        try Task.checkCancellation()
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.valid(text: text), now.timeIntervalSince1970.isFinite else { throw AgentNotesError.invalidText }
        var next = try load()
        let note: AgentNote
        if let id {
            guard let index = next.notes.firstIndex(where: { $0.id == id }) else { throw AgentNotesError.missing }
            var updated = next.notes[index]
            updated.text = text; updated.updatedAt = now
            next.notes[index] = updated; note = updated
        } else {
            guard next.notes.count < Self.maximumNotes else { throw AgentNotesError.full }
            note = AgentNote(text: text, createdAt: now)
            next.notes.append(note)
        }
        try persist(next)
        return note
    }

    public func delete(id: UUID) throws {
        try Task.checkCancellation()
        var next = try load()
        guard let index = next.notes.firstIndex(where: { $0.id == id }) else { throw AgentNotesError.missing }
        next.notes.remove(at: index)
        try persist(next)
    }

    private static func valid(text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.utf8.count <= maximumTextBytes
            && !text.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\t" }
    }

    private func load() throws -> Document {
        if let document { return document }
        let manager = FileManager.default
        guard manager.fileExists(atPath: fileURL.path) else {
            let empty = Document(version: 1, notes: [])
            document = empty
            return empty
        }
        do {
            let attributes = try manager.attributesOfItem(atPath: fileURL.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = attributes[.size] as? NSNumber, size.intValue <= Self.maximumFileBytes else {
                throw AgentNotesError.unreadable
            }
            let decoded = try JSONDecoder().decode(Document.self, from: Data(contentsOf: fileURL))
            guard decoded.version == 1, decoded.notes.count <= Self.maximumNotes,
                  Set(decoded.notes.map(\.id)).count == decoded.notes.count,
                  decoded.notes.allSatisfy({ Self.valid(text: $0.text)
                      && $0.createdAt.timeIntervalSince1970.isFinite && $0.updatedAt.timeIntervalSince1970.isFinite }) else {
                throw AgentNotesError.unreadable
            }
            document = decoded
            return decoded
        } catch { throw AgentNotesError.unreadable }
    }

    private func persist(_ next: Document) throws {
        try Task.checkCancellation()
        let manager = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // A failed read never reaches this path. Do not silently overwrite a damaged notebook.
        let data = try JSONEncoder().encode(next)
        guard data.count <= Self.maximumFileBytes else { throw AgentNotesError.full }
        try data.write(to: fileURL, options: [.atomic])
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        document = next
    }
}
