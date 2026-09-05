import AICameraCore
import AppKit
import Combine
import Foundation
import Security

@MainActor
final class CodexAuthController: ObservableObject {
    @Published private(set) var accountLabel: String?
    @Published private(set) var deviceCode: String?
    @Published private(set) var verificationURL: URL?
    @Published private(set) var isBusy = false
    @Published private(set) var message: String?
    var isSignedIn: Bool { accountLabel != nil }
    private let server: CodexAppServer
    private var operation: Task<Void, Never>?
    private var loginDeadline: Task<Void, Never>?
    private var loginID: String?
    private var generation = 0
    private var loadedStatus = false
    private var credentialTask: Task<String, Error>?

    init(home: URL? = nil) {
        let home = home ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AI Camera/Codex", isDirectory: true)
        server = CodexAppServer(home: home)
        server.onNotification = { [weak self] method, params in self?.receive(method, params: params) }
    }

    func loadStatus() {
        guard !loadedStatus, !isBusy else { return }
        perform {
            try await self.readAccount(refresh: false)
            self.loadedStatus = true
        }
    }

    func signIn() {
        guard !isBusy, loginID == nil else { return }
        perform {
            let result = try await self.server.request("account/login/start", params: ["type": "chatgptDeviceCode"])
            guard let id = result["loginId"] as? String, id.utf8.count <= 128,
                  let code = result["userCode"] as? String,
                  let url = result["verificationUrl"] as? String else { throw CodexAppServer.Failure.invalidResponse }
            let verified = try CodexAuthPolicy.deviceLogin(url: url, code: code)
            try Task.checkCancellation()
            self.loginID = id; self.deviceCode = code; self.verificationURL = verified
            self.message = "Enter this code on the Codex sign-in page. This login is only for AI Camera."
            self.loginDeadline?.cancel()
            self.loginDeadline = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(15 * 60)) } catch { return }
                self?.cancelSignIn()
            }
            NSWorkspace.shared.open(verified)
        }
    }

    func openSignInPage() {
        if let verificationURL { NSWorkspace.shared.open(verificationURL) }
    }

    func cancelSignIn() {
        let id = loginID
        clearLogin()
        generation += 1
        operation?.cancel(); operation = nil; isBusy = false
        perform {
            if let id { _ = try await self.server.request("account/login/cancel", params: ["loginId": id]) }
            else { self.server.stop() }
            self.message = "Sign-in cancelled."
        }
    }

    func refreshLogin() {
        guard !isBusy, loginID == nil else { return }
        perform {
            try await self.readAccount(refresh: true)
            self.message = self.isSignedIn ? "AI Camera's Codex login was refreshed." : "Sign in to Codex to continue."
        }
    }

    func signOut() {
        guard !isBusy else { return }
        clearLogin()
        credentialTask?.cancel(); credentialTask = nil
        perform {
            _ = try await self.server.request("account/logout")
            self.accountLabel = nil
            self.loadedStatus = true
            self.message = "Signed out of AI Camera's Codex login."
            self.server.stop()
        }
    }

    /// Called only for an explicitly selected Codex Realtime turn. Never falls back to an API key.
    func realtimeCredential() async throws -> String {
        if let credentialTask {
            let credential = try await credentialTask.value
            try Task.checkCancellation()
            return credential
        }
        guard !isBusy, loginID == nil else { throw CodexAppServer.Failure.busy }
        generation += 1
        let generation = generation
        isBusy = true
        let task = Task { @MainActor in
            try await server.start()
            let account = CodexAuthPolicy.keychainAccount(canonicalHomePath: server.home.resolvingSymlinksInPath().path)
            var token = try await Self.readAccessToken(account: account)
            if token.needsRefresh() {
                try await readAccount(refresh: true)
                token = try await Self.readAccessToken(account: account)
            }
            try Task.checkCancellation()
            guard !token.needsRefresh() else { throw CodexAppServer.Failure.rejected }
            return token.value
        }
        credentialTask = task
        defer {
            if generation == self.generation { credentialTask = nil; isBusy = false }
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
    }

    func stop() {
        generation += 1
        clearLogin()
        operation?.cancel(); operation = nil
        credentialTask?.cancel(); credentialTask = nil
        server.stop(); isBusy = false
    }

    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        guard !isBusy else { return }
        generation += 1
        let generation = generation
        isBusy = true; message = nil
        operation = Task { [weak self] in
            guard let self else { return }
            defer { if generation == self.generation { self.isBusy = false; self.operation = nil } }
            do { try await action() }
            catch is CancellationError { }
            catch {
                guard generation == self.generation else { return }
                self.clearLogin()
                self.server.stop()
                self.message = (error as? LocalizedError)?.errorDescription ?? "Codex authentication could not complete. Retry sign-in."
            }
        }
    }

    private func readAccount(refresh: Bool) async throws {
        let result = try await server.request("account/read", params: ["refreshToken": refresh])
        try Task.checkCancellation()
        guard let account = result["account"] as? [String: Any], account["type"] as? String == "chatgpt" else {
            accountLabel = nil; return
        }
        let email = account["email"] as? String ?? "Codex account"
        guard email.utf8.count <= 320, !email.contains(where: { $0.isNewline }) else {
            throw CodexAppServer.Failure.invalidResponse
        }
        accountLabel = email
    }

    private func receive(_ method: String, params: [String: Any]) {
        guard method == "account/login/completed", let id = params["loginId"] as? String,
              id == loginID else { return }
        let success = params["success"] as? Bool == true
        clearLogin()
        perform {
            if success {
                try await self.readAccount(refresh: false)
                self.loadedStatus = true
                self.message = "Signed in for AI Camera. Save the Codex choice to use it for Realtime."
            } else { throw CodexAppServer.Failure.rejected }
        }
    }

    private func clearLogin() {
        loginDeadline?.cancel(); loginDeadline = nil
        loginID = nil; deviceCode = nil; verificationURL = nil
    }

    nonisolated private static func readAccessToken(account: String) async throws -> CodexAuthPolicy.AccessToken {
        try await Task.detached(priority: .userInitiated) {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "Codex Auth",
                kSecAttrAccount as String: account,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne
            ]
            var result: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
                  let data = result as? Data else { throw CodexAppServer.Failure.rejected }
            return try CodexAuthPolicy.accessToken(from: data)
        }.value
    }
}
