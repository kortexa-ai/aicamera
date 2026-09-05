// Auth-only native CLI check; never reads the desktop login or requests model generation.
import AICameraCore
import Foundation

private enum CheckFailure: Error { case unexpectedAccount, malformedLogin, cancellationFailed, stoppedStartupSucceeded }

@main private struct CodexAuthValidation {
    @MainActor static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aicamera-codex-check-\(UUID())")
        let server = CodexAppServer(home: directory)
        defer { server.stop(); try? FileManager.default.removeItem(at: directory) }
        var cancelledID: String?
        server.onNotification = { method, params in
            if method == "account/login/completed", params["success"] as? Bool == false {
                cancelledID = params["loginId"] as? String
            }
        }
        let initial = try await server.request("account/read", params: ["refreshToken": false])
        guard initial["account"] is NSNull else { throw CheckFailure.unexpectedAccount }
        print("Isolated app-server initialized with no account")
        let login = try await server.request("account/login/start", params: ["type": "chatgptDeviceCode"])
        guard let id = login["loginId"] as? String, let code = login["userCode"] as? String,
              let url = login["verificationUrl"] as? String else { throw CheckFailure.malformedLogin }
        _ = try CodexAuthPolicy.deviceLogin(url: url, code: code)
        _ = try await server.request("account/login/cancel", params: ["loginId": id])
        for _ in 0..<100 where cancelledID != id { try await Task.sleep(for: .milliseconds(20)) }
        guard cancelledID == id else { throw CheckFailure.cancellationFailed }
        let final = try await server.request("account/read", params: ["refreshToken": false])
        guard final["account"] is NSNull else { throw CheckFailure.unexpectedAccount }
        _ = try await server.request("account/logout")
        server.stop()
        let restarted = try await server.request("account/read", params: ["refreshToken": false])
        guard restarted["account"] is NSNull else { throw CheckFailure.unexpectedAccount }
        server.stop()
        // Start a replacement before the abandoned startup's catch has had a chance to unwind.
        // The old generation must not terminate the replacement or launch after cancellation.
        for _ in 0..<3 {
            var attempted = false
            let abandoned = Task { @MainActor in attempted = true; try await server.start() }
            while !attempted { await Task.yield() }
            server.stop()
            let replacement = try await server.request("account/read", params: ["refreshToken": false])
            guard replacement["account"] is NSNull else { throw CheckFailure.unexpectedAccount }
            do {
                try await abandoned.value
                throw CheckFailure.stoppedStartupSucceeded
            } catch is CheckFailure { throw CheckFailure.stoppedStartupSucceeded }
            catch { }
            server.stop()
        }
        print("Device-code contract, cancellation notification, empty logout, helper restart, and overlapping startup shutdown passed")
    }
}
