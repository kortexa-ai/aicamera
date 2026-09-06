import AICameraCore
import Combine
import Darwin
import Foundation

@MainActor
final class BuiltinWhisperModelController: ObservableObject {
    enum State: Equatable { case notDownloaded, downloading, ready, failed(String) }
    @Published private(set) var states: [BuiltinWhisperModel: State] = [:]
    @Published private(set) var progress: ModelDownloadProgress?
    let availableModels: [BuiltinWhisperModel]
    private let directory: URL
    private var task: Task<Void, Never>?
    private var downloadingModel: BuiltinWhisperModel?
    private var generation: UInt64 = 0
    private var isShutdown = false
    private var clients: [BuiltinWhisperModel: BuiltinWhisperClient] = [:]
    private struct LiveClient { weak var value: BuiltinWhisperClient? }
    // A replaced cache entry can still be owned by an inference task during shutdown.
    private var liveClients: [LiveClient] = []

    init(processorBrand: String? = nil) {
        availableModels = BuiltinWhisperModel.availableModels(processorBrand: processorBrand ?? Self.processorBrand)
        directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AI Camera/Models", isDirectory: true)
        for model in BuiltinWhisperModel.allCases {
            states[model] = FileManager.default.fileExists(atPath: fileURL(for: model).path) ? .ready : .notDownloaded
        }
    }

    func state(for model: BuiltinWhisperModel) -> State { states[model] ?? .notDownloaded }
    func isReady(_ model: BuiltinWhisperModel) -> Bool {
        availableModels.contains(model) && state(for: model) == .ready
    }
    var hasActiveDownload: Bool { task != nil }
    func fileURL(for model: BuiltinWhisperModel) -> URL { directory.appendingPathComponent(model.fileName) }

    func download(_ model: BuiltinWhisperModel) {
        guard !isShutdown else { return }
        guard availableModels.contains(model), task == nil, !isReady(model) else { return }
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
        guard !isShutdown, isReady(model) else { return nil }
        if let client = clients[model] { return client }
        let client = BuiltinWhisperClient(modelURL: fileURL(for: model))
        clients[model] = client
        liveClients.removeAll { $0.value == nil }
        liveClients.append(LiveClient(value: client))
        return client
    }

    func shutdown() async {
        isShutdown = true
        generation &+= 1
        task?.cancel()
        task = nil
        downloadingModel = nil
        let retainedClients = liveClients.compactMap(\.value)
        clients.removeAll()
        liveClients.removeAll()
        for client in retainedClients { await client.shutdown() }
    }

    private static var processorBrand: String {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0,
              size > 0, size <= 256 else { return "" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &bytes, &size, nil, 0) == 0 else { return "" }
        return String(cString: bytes)
    }
}
