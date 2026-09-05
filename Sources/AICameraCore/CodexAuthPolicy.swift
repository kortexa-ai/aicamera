import CryptoKit
import Foundation

public enum RealtimeAuthentication: String, Codable, CaseIterable, Sendable {
    case apiKey
    case codex
}

public enum CodexAuthPolicy {
    public enum Failure: Error { case invalidCredential, invalidDeviceCode, oversizedMessage }
    public struct AccessToken: Sendable {
        public let value: String
        public let expiresAt: Date
        public func needsRefresh(at now: Date = Date()) -> Bool { expiresAt.timeIntervalSince(now) < 120 }
    }

    /// Codex's direct Keychain backend scopes its account to the canonical CODEX_HOME path.
    public static func keychainAccount(canonicalHomePath: String) -> String {
        "cli|" + SHA256.hash(data: Data(canonicalHomePath.utf8))
            .map { String(format: "%02x", $0) }.joined().prefix(16)
    }

    /// Decoding expiry only schedules refresh; OpenAI remains responsible for JWT verification.
    public static func accessToken(from data: Data) throws -> AccessToken {
        guard data.count <= 64 * 1_024,
              let bundle = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = bundle["tokens"] as? [String: Any],
              let token = tokens["access_token"] as? String, !token.isEmpty,
              token.utf8.count <= 15 * 1_024, token.utf8.allSatisfy({ $0 > 32 && $0 < 127 }) else {
            throw Failure.invalidCredential
        }
        let components = token.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 3 else { throw Failure.invalidCredential }
        var payload = String(components[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let bytes = Data(base64Encoded: payload),
              let claims = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let expiry = claims["exp"] as? Double, expiry.isFinite, expiry > 0,
              expiry < 253_402_300_800 else { throw Failure.invalidCredential }
        return .init(value: token, expiresAt: Date(timeIntervalSince1970: expiry))
    }

    public static func deviceLogin(url: String, code: String) throws -> URL {
        guard let target = URLComponents(string: url), target.scheme == "https",
              target.host == "auth.openai.com", target.path == "/codex/device",
              target.port == nil, target.user == nil, target.password == nil,
              target.query == nil, target.fragment == nil,
              (4...32).contains(code.utf8.count),
              code.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || $0 == 45 }),
              let result = target.url else { throw Failure.invalidDeviceCode }
        return result
    }
}

/// Bounded JSONL framing for the local auth-only app-server connection.
public struct CodexMessageBuffer {
    public static let maximumBytes = 64 * 1_024
    private var pending = Data()
    public init() {}
    public mutating func append(_ chunk: Data) throws -> [Data] {
        guard chunk.count <= Self.maximumBytes, pending.count + chunk.count <= Self.maximumBytes else {
            throw CodexAuthPolicy.Failure.oversizedMessage
        }
        pending.append(chunk)
        var lines = [Data]()
        while let newline = pending.firstIndex(of: 10) {
            let line = Data(pending[..<newline])
            pending.removeSubrange(...newline)
            if !line.isEmpty { lines.append(line) }
        }
        pending = Data(pending)
        return lines
    }
}
