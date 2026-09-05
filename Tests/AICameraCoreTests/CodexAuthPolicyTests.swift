import Foundation
import XCTest
@testable import AICameraCore

final class CodexAuthPolicyTests: XCTestCase {
    private func bundle(expiry: Double, tokenOverride: String? = nil) throws -> Data {
        let body = try JSONSerialization.data(withJSONObject: ["exp": expiry]).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return try JSONSerialization.data(withJSONObject: ["tokens": ["access_token": tokenOverride ?? "test.\(body).test"]])
    }

    func testExpiryIsOnlyALocalRefreshHint() throws {
        let token = try CodexAuthPolicy.accessToken(from: bundle(expiry: 1_000))
        XCTAssertFalse(token.needsRefresh(at: Date(timeIntervalSince1970: 800)))
        XCTAssertTrue(token.needsRefresh(at: Date(timeIntervalSince1970: 900)))
        XCTAssertTrue(token.needsRefresh(at: Date(timeIntervalSince1970: 1_001)))
        XCTAssertThrowsError(try CodexAuthPolicy.accessToken(from: bundle(expiry: -1)))
    }

    func testCredentialBoundsAndHeaderInjection() throws {
        for token in ["", "not-a-jwt", "x.y.z\n", String(repeating: "a", count: 16_000)] {
            XCTAssertThrowsError(try CodexAuthPolicy.accessToken(from: bundle(expiry: 1_000, tokenOverride: token)))
        }
        XCTAssertThrowsError(try CodexAuthPolicy.accessToken(from: Data(count: 65_537)))
        XCTAssertThrowsError(try CodexAuthPolicy.accessToken(from: Data("{\"tokens\":{}}".utf8)))
    }

    func testDevicePageIsExactAndCannotCarryCredentials() throws {
        XCTAssertEqual(try CodexAuthPolicy.deviceLogin(url: "https://auth.openai.com/codex/device", code: "ABCD-1234").host, "auth.openai.com")
        for url in ["http://auth.openai.com/codex/device", "https://evil.test/codex/device",
                    "https://auth.openai.com@evil.test/codex/device", "https://auth.openai.com/codex/device?next=bad",
                    "https://auth.openai.com:443/codex/device"] {
            XCTAssertThrowsError(try CodexAuthPolicy.deviceLogin(url: url, code: "ABCD-1234"))
        }
        XCTAssertThrowsError(try CodexAuthPolicy.deviceLogin(url: "https://auth.openai.com/codex/device", code: "ABCD\n1234"))
    }

    func testKeychainScopeAndSplitJSONLines() throws {
        XCTAssertNotEqual(CodexAuthPolicy.keychainAccount(canonicalHomePath: "/test/AI Camera/Codex"),
                          CodexAuthPolicy.keychainAccount(canonicalHomePath: "/test/.codex"))
        XCTAssertEqual(CodexAuthPolicy.keychainAccount(canonicalHomePath: "abc"), "cli|ba7816bf8f01cfea")
        var buffer = CodexMessageBuffer()
        XCTAssertEqual(try buffer.append(Data("{\"a\":".utf8)), [])
        XCTAssertEqual(try buffer.append(Data("1}\n{}\npart".utf8)), [Data("{\"a\":1}".utf8), Data("{}".utf8)])
        XCTAssertEqual(try buffer.append(Data("ial\n".utf8)), [Data("partial".utf8)])
        XCTAssertThrowsError(try buffer.append(Data(count: CodexMessageBuffer.maximumBytes + 1)))
    }

    func testLegacyProfilesDefaultToAPIKeyAndCodexCannotRetainAKeyFallback() throws {
        let original = AICameraConfiguration.default
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as! [String: Any]
        var pipeline = json["pipeline"] as! [String: Any]
        var conversation = pipeline["conversation"] as! [String: Any]
        conversation.removeValue(forKey: "realtimeAuthentication")
        pipeline["conversation"] = conversation; json["pipeline"] = pipeline
        let decoded = try JSONDecoder().decode(AICameraConfiguration.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded.pipeline.conversation.realtimeAuthentication, .apiKey)
        var local = original
        local.pipeline.conversation.realtimeAuthentication = .codex
        local.pipeline.conversation.realtimeEndpointID = "rt"
        local.endpoints = [.init(id: "rt", adapter: .openAIRealtime, baseURL: URL(string: "https://api.openai.com")!)]
        XCTAssertNoThrow(try ConfigurationValidator.validate(local))
        local.endpoints[0].auth = .init(kind: .bearerKeychain, reference: "test-key")
        XCTAssertThrowsError(try ConfigurationValidator.validate(local))
        local.endpoints[0].auth = .init()
        local.endpoints[0].baseURL = URL(string: "https://other.test")!
        XCTAssertThrowsError(try ConfigurationValidator.validate(local))
    }
}
