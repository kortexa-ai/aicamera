import AICameraCore
import SwiftUI

struct AgentNotesView: View {
    @ObservedObject var controller: AgentNotesController
    @State private var draft = ""
    @State private var editingID: UUID?
    @State private var isSaving = false
    @State private var search = ""

    private var visibleNotes: [AgentNote] {
        controller.notes.filter { search.isEmpty || $0.text.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "note.text")
                    .font(.title2).foregroundStyle(.purple)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Your notes").font(.title2.weight(.semibold))
                    Text("Saved on this Mac. Not added to the camera feed.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }

            TextField("Find a note", text: $search)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("notes-search")

            if let error = controller.error {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }

            if controller.notes.isEmpty, controller.error == nil {
                VStack(spacing: 8) {
                    Image(systemName: "text.bubble").font(.system(size: 30)).foregroundStyle(.tertiary)
                    Text("Something worth remembering?").font(.headline)
                    Text("Ask the agent to remember a note, or write one below.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(visibleNotes) { note in
                            VStack(alignment: .leading, spacing: 10) {
                                Text(note.text).font(.body).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                HStack {
                                    Text(note.updatedAt, style: .date).font(.caption2).foregroundStyle(.secondary)
                                    Spacer()
                                    Button("Edit") { editingID = note.id; draft = note.text }
                                    Button(role: .destructive) { remove(note) } label: {
                                        Image(systemName: "trash")
                                    }
                                    .accessibilityLabel("Delete note")
                                }
                                .buttonStyle(.borderless).controlSize(.small)
                                .disabled(isSaving)
                            }
                            .padding(14)
                            .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
                        }
                        if visibleNotes.isEmpty { Text("No matching notes").foregroundStyle(.secondary).padding() }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                TextField("Write a note…", text: $draft, axis: .vertical)
                    .lineLimit(2...5)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("note-draft")
                HStack {
                    Text("\(controller.notes.count) of \(AgentNoteStore.maximumNotes) notes")
                        .font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    if editingID != nil {
                        Button("Cancel") { editingID = nil; draft = "" }
                    }
                    Button(editingID == nil ? "Save note" : "Save changes", action: save)
                        .disabled(isSaving || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || draft.utf8.count > AgentNoteStore.maximumTextBytes)
                }
                .controlSize(.small)
            }
        }
        .padding(20)
        .frame(minWidth: 380, idealWidth: 460, minHeight: 420, idealHeight: 560)
        .background(AppWindowLifecycle())
        .task { await controller.refresh() }
    }

    private func save() {
        isSaving = true
        let text = draft, id = editingID
        Task {
            do {
                _ = try await controller.save(text: text, id: id)
                if draft == text { draft = ""; editingID = nil }
            } catch { /* The controller presents the error without discarding the draft. */ }
            isSaving = false
        }
    }

    private func remove(_ note: AgentNote) {
        isSaving = true
        Task {
            do {
                try await controller.delete(id: note.id)
                if editingID == note.id { editingID = nil; draft = "" }
            } catch { /* The controller presents the error. */ }
            isSaving = false
        }
    }
}
