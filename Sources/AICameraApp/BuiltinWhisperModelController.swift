import AICameraCore
import Combine
import Foundation

@MainActor
final class BuiltinWhisperModelController: ObservableObject {
    enum State: Equatable { case notDownloaded, downloading, ready, failed(String) }
    @Published private(set) var states: [BuiltinWhisperModel: State] = [:]
    @Published private(set) var progress: ModelDownloadProgress?
    private let directory: URL
    private var task: Task<Void, Never>?
    private var downloadingModel: BuiltinWhisperModel?
    private var generation: UInt64 = 0
    private var clients: [BuiltinWhisperModel: BuiltinWhisperClient] = [:]

    init() {
        directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AI Camera/Models", isDirectory: true)
        for model in BuiltinWhisperModel.allCases {
            states[model] = FileManager.default.fileExists(atPath: fileURL(for: model).path) ? .ready : .notDownloaded
        }
    }

    func state(for model: BuiltinWhisperModel) -> State { states[model] ?? .notDownloaded }
    func isReady(_ model: BuiltinWhisperModel) -> Bool { state(for: model) == .ready }
    var hasActiveDownload: Bool { task != nil }
    func fileURL(for model: BuiltinWhisperModel) -> URL { directory.appendingPathComponent(model.fileName) }

    func download(_ model: BuiltinWhisperModel) {
        guard task == nil, !isReady(model) else { return }
        generation &+= 1
        let generation = generation
        downloadingModel = model
        progress = nil
        states[model] = .downloading
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                if generation == self.generation { task = nil; downloadingModel = nil; progress = nil }
            }
            do {
                let temporary = try await VerifiedModelDownload.download(model.artifact) { [weak self] progress in
                    Task { @MainActor in
                        guard let self, self.generation == generation, self.downloadingModel == model else { return }
                        self.progress = progress
                    }
                }
                defer { try? FileManager.default.removeItem(at: temporary) }
                try Task.checkCancellation()
                guard generation == self.generation else { return }
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                let destination = fileURL(for: model)
                if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
                try FileManager.default.moveItem(at: temporary, to: destination)
                clients[model] = nil
                states[model] = .ready
            } catch {
                guard generation == self.generation else { return }
                states[model] = Task.isCancelled ? .notDownloaded : .failed(error.localizedDescription)
            }
        }
    }

    func cancelDownload(_ model: BuiltinWhisperModel) {
        guard downloadingModel == model else { return }
        generation &+= 1
        task?.cancel(); task = nil; downloadingModel = nil; progress = nil
        states[model] = .notDownloaded
    }

    func remove(_ model: BuiltinWhisperModel) {
        cancelDownload(model)
        clients[model] = nil
        do {
            let url = fileURL(for: model)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            states[model] = .notDownloaded
        } catch { states[model] = .failed(error.localizedDescription) }
    }

    func makeTranscriptionClient(model: BuiltinWhisperModel) -> (any TranscriptionClient)? {
        guard isReady(model) else { return nil }
        if let client = clients[model] { return client }
        let client = BuiltinWhisperClient(modelURL: fileURL(for: model))
        clients[model] = client
        return client
    }
}
