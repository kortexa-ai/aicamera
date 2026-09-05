// Compile with BuiltinTranslationClient.swift and BuiltinTranslationModelController.swift,
// linking the generated Debug AICameraCore/llama frameworks. See docs/testing.md.
// Uses synthetic text and disposable fixtures only. Never downloads weights or reads Keychain.
import AICameraCore
import Darwin
import Foundation

private enum ProbeError: Error { case failed(String) }
private func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw ProbeError.failed(message) }
}

private actor PendingDownloads {
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<URL, Error>] = [:]
    func fetch() async throws -> URL {
        nextID += 1
        let id = nextID
        // Intentionally ignores cancellation to reproduce a late download/hash completion.
        return try await withCheckedThrowingContinuation { pending[id] = $0 }
    }
    func hasStarted(_ id: Int) -> Bool { pending[id] != nil }
    func finish(_ id: Int, url: URL) { pending.removeValue(forKey: id)?.resume(returning: url) }
}

@main private struct LocalTranslationValidation {
    @MainActor static func main() async throws {
        try await validateDownloadOwnership()
        if CommandLine.arguments.contains("--lifecycle-only") { return }
        let controller = BuiltinTranslationModelController()
        guard let client = controller.makeTranslationClient() as? BuiltinTranslationClient else {
            throw ProbeError.failed("Download HY-MT2 in AI Camera before running native inference validation.")
        }
        try require(controller.makeTranslationClient() as? BuiltinTranslationClient === client, "Client was not reused")
        for target in ["zh", "ja", "ar"] {
            let start = ProcessInfo.processInfo.systemUptime
            let output = try await client.translate(.init(
                text: "The camera is ready. Hello, world!", sourceLanguage: "en", targetLanguage: target
            ))
            try require(!output.contains("\u{FFFD}"), "Translation contains replacement characters")
            print("target=\(target) seconds=\(ProcessInfo.processInfo.systemUptime - start) output=\(output)")
        }
        let cancelled = Task {
            try await client.translate(.init(
                text: String(repeating: "The camera is ready and the microphone is quiet. ", count: 100),
                sourceLanguage: "en", targetLanguage: "zh"
            ))
        }
        try await Task.sleep(for: .milliseconds(50))
        let cancellationStart = ProcessInfo.processInfo.systemUptime
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            throw ProbeError.failed("Cancelled inference completed normally")
        } catch is CancellationError {
            print("cancellationSeconds=\(ProcessInfo.processInfo.systemUptime - cancellationStart)")
        }
        let recovery = try await client.translate(.init(text: "Ready again.", sourceLanguage: "en", targetLanguage: "zh"))
        try require(!recovery.isEmpty, "Recovery returned no text")
        var transient: BuiltinTranslationClient? = BuiltinTranslationClient(modelURL: controller.modelFileURL)
        _ = try await transient!.translate(.init(text: "Hello.", targetLanguage: "ja"))
        transient = nil
        let survivor = try await client.translate(.init(text: "Still ready.", targetLanguage: "zh"))
        try require(!survivor.isEmpty, "One engine's teardown broke another engine")
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        print("native translation passed; peakResidentBytes=\(usage.ru_maxrss)")
    }

    @MainActor private static func waitUntil(_ predicate: () async -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while !(await predicate()) {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw ProbeError.failed("Fixture timed out") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @MainActor private static func validateDownloadOwnership() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aicamera-translation-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pending = PendingDownloads()
        let controller = BuiltinTranslationModelController(
            modelDirectory: directory.appendingPathComponent("models"),
            downloadModel: { try await pending.fetch() }
        )
        let old = directory.appendingPathComponent("old.tmp")
        let current = directory.appendingPathComponent("current.tmp")
        try Data("old fixture".utf8).write(to: old)
        try Data("current fixture".utf8).write(to: current)
        controller.download()
        try await waitUntil { await pending.hasStarted(1) }
        controller.remove()
        controller.download()
        try await waitUntil { await pending.hasStarted(2) }
        await pending.finish(1, url: old)
        try await waitUntil { !FileManager.default.fileExists(atPath: old.path) }
        try require(controller.state == .downloading, "Old completion changed the new download state")
        try require(!FileManager.default.fileExists(atPath: controller.modelFileURL.path), "Removed model reappeared")
        await pending.finish(2, url: current)
        try await waitUntil { controller.isReady }
        let installed = try Data(contentsOf: controller.modelFileURL)
        try require(installed == Data("current fixture".utf8), "Wrong generation was installed")
        guard let first = controller.makeTranslationClient() as? BuiltinTranslationClient else {
            throw ProbeError.failed("Ready model has no client")
        }
        try require(controller.makeTranslationClient() as? BuiltinTranslationClient === first, "Ready client was not cached")
        controller.remove()
        try require(controller.makeTranslationClient() == nil, "Removed model is still available to new pipelines")
        try require(controller.state == .notDownloaded, "Removal did not return to not-downloaded")
        print("download generation/removal/cache checks passed")
    }
}
