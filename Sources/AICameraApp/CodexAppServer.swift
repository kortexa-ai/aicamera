import AICameraCore
import Foundation

/// Runs only authentication RPCs in an isolated Codex home. No agent threads are created.
@MainActor
final class CodexAppServer {
    enum Failure: LocalizedError {
        case unavailable, stopped, timeout, invalidResponse, rejected, busy
        var errorDescription: String? {
            switch self {
            case .unavailable: "Install the Codex CLI, then retry sign-in."
            case .stopped: "The Codex sign-in helper stopped. Retry the operation."
            case .timeout: "Codex did not respond in time. Retry the operation."
            case .invalidResponse: "The installed Codex CLI returned an unsupported response. Update Codex and retry."
            case .rejected: "Codex could not complete authentication. Check your account's device sign-in setting and try again."
            case .busy: "Another Codex authentication operation is still running."
            }
        }
    }
    let home: URL
    var onNotification: ((String, [String: Any]) -> Void)?
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var startup: Task<Void, Error>?
    private var buffer = CodexMessageBuffer()
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var timeouts: [Int: Task<Void, Never>] = [:]
    private var generation = 0

    init(home: URL) { self.home = home }

    func start() async throws {
        if let startup { return try await startup.value }
        let generation = generation
        let task = Task { @MainActor in
            try Task.checkCancellation()
            try launch()
            _ = try await send("initialize", params: ["clientInfo": [
                "name": "aicamera", "title": "AI Camera", "version": "1.0"
            ]])
            try Task.checkCancellation()
            guard generation == self.generation else { throw Failure.stopped }
            try write(["method": "initialized"])
        }
        startup = task
        do { try await task.value }
        catch {
            if generation == self.generation { stop() }
            throw error
        }
    }

    func request(_ method: String, params: [String: Any] = [:]) async throws -> [String: Any] {
        guard ["account/read", "account/login/start", "account/login/cancel", "account/logout"].contains(method) else {
            throw Failure.rejected
        }
        try await start()
        return try await send(method, params: params)
    }

    func stop() {
        generation += 1
        startup?.cancel(); startup = nil
        output?.readabilityHandler = nil
        try? output?.close(); output = nil
        try? input?.close(); input = nil
        if let process, process.isRunning { process.terminate() }
        process = nil
        buffer = CodexMessageBuffer()
        let requests = pending; pending.removeAll()
        for task in timeouts.values { task.cancel() }
        timeouts.removeAll()
        for continuation in requests.values { continuation.resume(throwing: Failure.stopped) }
    }

    private func launch() throws {
        guard let executable = Self.findExecutable() else { throw Failure.unavailable }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        guard !FileManager.default.fileExists(atPath: home.appendingPathComponent("auth.json").path) else {
            // Never import an existing file credential or let it select another auth mode.
            throw Failure.rejected
        }
        let process = Process()
        process.executableURL = executable
        process.currentDirectoryURL = home
        process.arguments = ["-c", "cli_auth_credentials_store=\"keyring\"",
                             "-c", "forced_login_method=\"chatgpt\"",
                             "-c", "features.secret_auth_storage=false",
                             "-c", "analytics.enabled=false", "app-server", "--listen", "stdio://"]
        process.environment = [
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "CODEX_HOME": home.path,
            "PATH": executable.deletingLastPathComponent().path + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "TMPDIR": FileManager.default.temporaryDirectory.path,
            "LANG": "en_US.UTF-8"
        ]
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin; process.standardOutput = stdout
        // Auth diagnostics are deliberately not copied into app logs or UI.
        process.standardError = FileHandle.nullDevice
        input = stdin.fileHandleForWriting; output = stdout.fileHandleForReading
        let generation = generation
        let readSlots = DispatchSemaphore(value: 4)
        output?.readabilityHandler = { [weak self] handle in
            guard readSlots.wait(timeout: .now()) == .success else {
                handle.readabilityHandler = nil
                Task { @MainActor [weak self] in
                    guard let self, self.generation == generation else { return }
                    self.stop()
                }
                return
            }
            // A fixed-length FileHandle read can wait for a full buffer on a pipe.
            // availableData returns the bytes ready now; the framing limit rejects excess.
            let data = handle.availableData
            Task { @MainActor [weak self] in
                defer { readSlots.signal() }
                guard let self, self.generation == generation else { return }
                if data.isEmpty { self.stop(); return }
                self.receive(data)
            }
        }
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation else { return }
                self.stop()
            }
        }
        self.process = process
        try process.run()
    }

    private func send(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        try Task.checkCancellation()
        guard process?.isRunning == true, pending.count < 8 else { throw Failure.busy }
        nextID += 1
        let id = nextID
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                timeouts[id] = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(30)) } catch { return }
                    self?.finish(id, result: .failure(Failure.timeout))
                }
                do { try write(["method": method, "id": id, "params": params]) }
                catch { finish(id, result: .failure(error)) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(id, result: .failure(CancellationError())) }
        }
    }

    private func write(_ value: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: value) + Data([10])
        guard data.count <= 4_096, let input else { throw Failure.invalidResponse }
        try input.write(contentsOf: data)
    }

    private func receive(_ data: Data) {
        do {
            for line in try buffer.append(data) {
                guard let message = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                    throw Failure.invalidResponse
                }
                if let id = message["id"] as? Int {
                    if let result = message["result"] as? [String: Any] { finish(id, result: .success(result)) }
                    else { finish(id, result: .failure(Failure.rejected)) }
                } else if let method = message["method"] as? String,
                          let params = message["params"] as? [String: Any] {
                    onNotification?(method, params)
                }
            }
        } catch { stop() }
    }

    private func finish(_ id: Int, result: Result<[String: Any], Error>) {
        timeouts.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)?.resume(with: result)
    }

    private static func findExecutable() -> URL? {
        let manager = FileManager.default
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
        var candidates = paths.prefix(32).map { URL(fileURLWithPath: String($0)).appendingPathComponent("codex") }
        candidates += [URL(fileURLWithPath: "/opt/homebrew/bin/codex"), URL(fileURLWithPath: "/usr/local/bin/codex")]
        let versions = manager.homeDirectoryForCurrentUser.appendingPathComponent(".nvm/versions/node")
        let nodes = (try? manager.contentsOfDirectory(at: versions, includingPropertiesForKeys: nil)) ?? []
        candidates += nodes.sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending }
            .prefix(32).map { $0.appendingPathComponent("bin/codex") }
        return candidates.first { manager.isExecutableFile(atPath: $0.path) }
    }
}
