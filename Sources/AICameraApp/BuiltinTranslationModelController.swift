import AICameraCore
import Combine
import CryptoKit
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
    let modelFileURL: URL
    private let downloadModel: @Sendable () async throws -> URL
    private var downloadTask: Task<Void, Never>?
    private var downloadGeneration: UInt64 = 0
    private var cachedClient: BuiltinTranslationClient?

    init(modelDirectory: URL? = nil, downloadModel: (@Sendable () async throws -> URL)? = nil) {
        let support = modelDirectory ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appendingPathComponent("AI Camera/Models", isDirectory: true)
        modelFileURL = support.appendingPathComponent("Hy-MT2-1.8B-Q4_K_M.gguf")
        self.downloadModel = downloadModel ?? { try await Self.downloadVerifiedModel() }
        state = FileManager.default.fileExists(atPath: modelFileURL.path) ? .ready : .notDownloaded
    }

    var isReady: Bool { state == .ready }

    func download() {
        guard downloadTask == nil, !isReady else { return }
        downloadGeneration &+= 1
        let generation = downloadGeneration
        state = .downloading
        downloadTask = Task { [weak self] in
            guard let self else { return }
            defer { if generation == downloadGeneration { downloadTask = nil } }
            do {
                try Task.checkCancellation()
                let temporaryURL = try await downloadModel()
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
    }

    nonisolated private static func downloadVerifiedModel() async throws -> URL {
        let (temporaryURL, response) = try await URLSession.shared.download(from: modelURL)
        do {
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw ModelError.invalidResponse
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: temporaryURL.path)
            let byteCount = (attributes[.size] as? NSNumber)?.intValue ?? 0
            guard byteCount > 0, byteCount <= maximumDownloadBytes else { throw ModelError.invalidSize }
            let hashTask = Task.detached(priority: .utility) { try sha256(of: temporaryURL) }
            let digest = try await withTaskCancellationHandler {
                try await hashTask.value
            } onCancel: {
                hashTask.cancel()
            }
            try Task.checkCancellation()
            guard digest == expectedSHA256 else { throw ModelError.integrityMismatch }
            return temporaryURL
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
    }

    nonisolated private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while true {
            try Task.checkCancellation()
            let chunk = try handle.read(upToCount: 4 * 1_024 * 1_024) ?? Data()
            if chunk.isEmpty { break }
            hash.update(data: chunk)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private enum ModelError: LocalizedError {
        case invalidResponse, invalidSize, integrityMismatch
        var errorDescription: String? {
            switch self {
            case .invalidResponse: "The model server returned an invalid response."
            case .invalidSize: "The downloaded translation model has an unexpected size."
            case .integrityMismatch: "The downloaded translation model failed its integrity check."
            }
        }
    }
}
