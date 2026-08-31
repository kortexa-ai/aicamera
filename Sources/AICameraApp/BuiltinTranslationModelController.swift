import AICameraCore
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
    static let modelURL = URL(
        string: "https://huggingface.co/tencent/Hy-MT2-1.8B-GGUF/resolve/1cd5208700acedef4ef93019b6cfc148b8522d45/Hy-MT2-1.8B-Q4_K_M.gguf"
    )!
    static let expectedSHA256 = "dc5f44fcf1fa496ee7ad725982c0c8c553a4de00259b53af84c4b89fb0c06699"
    private static let maximumDownloadBytes = 1_200 * 1_024 * 1_024

    @Published private(set) var state: State
    let modelFileURL: URL
    private var downloadTask: Task<Void, Never>?

    init() {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appendingPathComponent("AI Camera/Models", isDirectory: true)
        modelFileURL = support.appendingPathComponent("Hy-MT2-1.8B-Q4_K_M.gguf")
        state = FileManager.default.fileExists(atPath: modelFileURL.path) ? .ready : .notDownloaded
    }

    var isReady: Bool { state == .ready }

    func download() {
        guard downloadTask == nil, !isReady else { return }
        state = .downloading
        downloadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let (temporaryURL, response) = try await URLSession.shared.download(from: Self.modelURL)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    throw ModelError.invalidResponse
                }
                let attributes = try FileManager.default.attributesOfItem(atPath: temporaryURL.path)
                let byteCount = (attributes[.size] as? NSNumber)?.intValue ?? 0
                guard byteCount > 0, byteCount <= Self.maximumDownloadBytes else {
                    throw ModelError.invalidSize
                }
                let digest = try await Task.detached(priority: .utility) {
                    try Self.sha256(of: temporaryURL)
                }.value
                guard digest == Self.expectedSHA256 else { throw ModelError.integrityMismatch }

                let parent = modelFileURL.deletingLastPathComponent()
                try FileManager.default.createDirectory(
                    at: parent,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                if FileManager.default.fileExists(atPath: modelFileURL.path) {
                    try FileManager.default.removeItem(at: modelFileURL)
                }
                try FileManager.default.moveItem(at: temporaryURL, to: modelFileURL)
                state = .ready
            } catch is CancellationError {
                state = .notDownloaded
            } catch {
                state = .failed(error.localizedDescription)
            }
            downloadTask = nil
        }
    }

    func cancelDownload() {
        downloadTask?.cancel()
    }

    func remove() {
        downloadTask?.cancel()
        downloadTask = nil
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
        return BuiltinTranslationClient(modelURL: modelFileURL)
    }

    nonisolated private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 4 * 1_024 * 1_024) ?? Data()
            if chunk.isEmpty { break }
            hash.update(data: chunk)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private enum ModelError: LocalizedError {
        case invalidResponse
        case invalidSize
        case integrityMismatch

        var errorDescription: String? {
            switch self {
            case .invalidResponse: return "The model server returned an invalid response."
            case .invalidSize: return "The downloaded translation model has an unexpected size."
            case .integrityMismatch: return "The downloaded translation model failed its integrity check."
            }
        }
    }
}
