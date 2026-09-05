import AICameraCore
import Combine
import Foundation

@MainActor
final class BuiltinTranslationModelController: ObservableObject {
    enum State: Equatable {
        case notDownloaded
        case downloading
        case ready
        case failed(String)
    }

    static let modelName = "HY-MT2 1.8B"
    static let downloadSize = "1.1 GB"
    nonisolated static let modelURL = URL(
        string: "https://huggingface.co/tencent/Hy-MT2-1.8B-GGUF/resolve/1cd5208700acedef4ef93019b6cfc148b8522d45/Hy-MT2-1.8B-Q4_K_M.gguf"
    )!
    nonisolated static let expectedSHA256 = "dc5f44fcf1fa496ee7ad725982c0c8c553a4de00259b53af84c4b89fb0c06699"
    nonisolated private static let maximumDownloadBytes = 1_200 * 1_024 * 1_024

    @Published private(set) var state: State
    @Published private(set) var progress: ModelDownloadProgress?
    let modelFileURL: URL
    private let downloadModel: (@Sendable () async throws -> URL)?
    private var downloadTask: Task<Void, Never>?
    private var downloadGeneration: UInt64 = 0
    private var cachedClient: BuiltinTranslationClient?

    init(modelDirectory: URL? = nil, downloadModel: (@Sendable () async throws -> URL)? = nil) {
        let support = modelDirectory ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appendingPathComponent("AI Camera/Models", isDirectory: true)
        modelFileURL = support.appendingPathComponent("Hy-MT2-1.8B-Q4_K_M.gguf")
        self.downloadModel = downloadModel
        state = FileManager.default.fileExists(atPath: modelFileURL.path) ? .ready : .notDownloaded
    }

    var isReady: Bool { state == .ready }

    func download() {
        guard downloadTask == nil, !isReady else { return }
        downloadGeneration &+= 1
        let generation = downloadGeneration
        state = .downloading
        progress = nil
        downloadTask = Task { [weak self] in
            guard let self else { return }
            defer { if generation == downloadGeneration { downloadTask = nil; progress = nil } }
            do {
                try Task.checkCancellation()
                let temporaryURL: URL
                if let downloadModel { temporaryURL = try await downloadModel() }
                else {
                    temporaryURL = try await VerifiedModelDownload.download(.init(
                        url: Self.modelURL, sha256: Self.expectedSHA256, maximumBytes: Int64(Self.maximumDownloadBytes)
                    )) { [weak self] progress in
                        Task { @MainActor in
                            guard let self, self.downloadGeneration == generation, self.downloadTask != nil else { return }
                            self.progress = progress
                        }
                    }
                }
                defer { try? FileManager.default.removeItem(at: temporaryURL) }
                try Task.checkCancellation()
                guard generation == downloadGeneration else { return }
                try FileManager.default.createDirectory(
                    at: modelFileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                if FileManager.default.fileExists(atPath: modelFileURL.path) {
                    try FileManager.default.removeItem(at: modelFileURL)
                }
                try FileManager.default.moveItem(at: temporaryURL, to: modelFileURL)
                cachedClient = nil
                state = .ready
            } catch {
                guard generation == downloadGeneration else { return }
                state = Task.isCancelled ? .notDownloaded : .failed(error.localizedDescription)
            }
        }
    }

    func cancelDownload() {
        guard downloadTask != nil else { return }
        invalidateDownload()
        state = .notDownloaded
    }

    func remove() {
        invalidateDownload()
        cachedClient = nil
        do {
            if FileManager.default.fileExists(atPath: modelFileURL.path) {
                try FileManager.default.removeItem(at: modelFileURL)
            }
            state = .notDownloaded
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func makeTranslationClient() -> (any TranslationClient)? {
        guard isReady else { return nil }
        if let cachedClient { return cachedClient }
        let client = BuiltinTranslationClient(modelURL: modelFileURL)
        cachedClient = client
        return client
    }

    private func invalidateDownload() {
        downloadGeneration &+= 1
        downloadTask?.cancel()
        downloadTask = nil
        progress = nil
    }

}
