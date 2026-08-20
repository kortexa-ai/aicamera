import XCTest
@testable import AICameraCore

final class ProfileTransferTests: XCTestCase {
    func testRoundTripPreservesSecretReferencesWithoutResolvingValues() throws {
        var configuration = AICameraConfiguration.default
        configuration.profileName = "Portable OpenAI"
        configuration.endpoints = [
            .init(
                id: "agent",
                adapter: .openAIChat,
                baseURL: URL(string: "https://api.openai.com")!,
                model: "gpt-5-mini",
                auth: .init(kind: .bearerEnvironment, reference: "OPENAI_API_KEY")
            ),
        ]

        let data = try ProfileTransfer.encode(configuration)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.contains("OPENAI_API_KEY"))
        XCTAssertFalse(text.contains("sk-test-secret"))
        XCTAssertEqual(try ProfileTransfer.decode(data), configuration)
    }

    func testImportRejectsCredentialValues() throws {
        var configuration = AICameraConfiguration.default
        configuration.endpoints = [
            .init(
                id: "unsafe",
                adapter: .openAIChat,
                baseURL: URL(string: "https://api.openai.com")!,
                options: ["api_key": .string("sk-test-secret")]
            ),
        ]
        let unvalidated = try JSONEncoder().encode(configuration)

        XCTAssertThrowsError(try ProfileTransfer.decode(unvalidated)) { error in
            XCTAssertEqual(error as? ConfigurationError, .invalidSecretReference("unsafe"))
        }
    }

    func testImportRejectsOversizedProfileBeforeDecoding() {
        let data = Data(repeating: 0x20, count: ProfileTransfer.maximumBytes + 1)
        XCTAssertThrowsError(try ProfileTransfer.decode(data)) { error in
            XCTAssertEqual(error as? ConfigurationError, .profileTooLarge)
        }
    }

    func testExportUsesOwnerOnlyPermissions() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = directory.appendingPathComponent("profile.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        try ProfileTransfer.write(.default, to: url)

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.intValue & 0o777, 0o600)
        XCTAssertEqual(try ProfileTransfer.read(from: url), .default)
    }

    func testCanonicalOpenAIExampleDecodesAndValidates() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = repository.appendingPathComponent("Examples/openai.json")
        let profile = try ProfileTransfer.read(from: url)

        XCTAssertEqual(profile.profileName, "OpenAI example")
        XCTAssertTrue(profile.endpoints.allSatisfy {
            $0.auth.reference == "OPENAI_API_KEY" && $0.auth.kind == .bearerEnvironment
        })
    }
}
