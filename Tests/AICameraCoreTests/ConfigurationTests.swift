import XCTest
@testable import AICameraCore

final class ConfigurationTests: XCTestCase {
    func testDefaultConfigurationIsValid() throws {
        try ConfigurationValidator.validate(.default)
    }

    func testRoundTripsThroughStore() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = directory.appendingPathComponent("profile.json")
        let store = ConfigurationStore(fileURL: url)
        var configuration = AICameraConfiguration.default
        configuration.profileName = "Studio"
        configuration.capture.videoDeviceID = "camera-123"
        try store.save(configuration)
        XCTAssertEqual(try store.load(), configuration)
        try? FileManager.default.removeItem(at: directory)
    }

    func testRejectsDuplicateEndpoints() {
        let endpoint = EndpointConfiguration(
            id: "same",
            adapter: .openAIChat,
            baseURL: URL(string: "http://127.0.0.1:2030")!
        )
        var configuration = AICameraConfiguration.default
        configuration.endpoints = [endpoint, endpoint]
        XCTAssertThrowsError(try ConfigurationValidator.validate(configuration)) { error in
            XCTAssertEqual(error as? ConfigurationError, .duplicateEndpointID("same"))
        }
    }

    func testRejectsCleartextRemoteEndpoint() {
        var configuration = AICameraConfiguration.default
        configuration.endpoints = [
            .init(id: "remote", adapter: .openAIChat, baseURL: URL(string: "http://models.example.com")!)
        ]
        XCTAssertThrowsError(try ConfigurationValidator.validate(configuration)) { error in
            XCTAssertEqual(error as? ConfigurationError, .insecureRemoteEndpoint("remote"))
        }
    }

    func testStageRequiresCompatibleEndpoint() {
        var configuration = AICameraConfiguration.default
        configuration.pipeline.videoStages = [
            .init(id: "objects", kind: .objectDetection, endpointID: "missing")
        ]
        XCTAssertThrowsError(try ConfigurationValidator.validate(configuration)) { error in
            XCTAssertEqual(error as? ConfigurationError, .missingEndpoint(stageID: "objects", endpointID: "missing"))
        }
    }
    func testCheckedInExampleProfilesDecodeAndValidate() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        for name in ["kortexa-local", "remote-openai-compatible"] {
            let data = try Data(contentsOf: repository.appendingPathComponent("Examples/\(name).json"))
            let profile = try JSONDecoder().decode(AICameraConfiguration.self, from: data)
            XCTAssertNoThrow(try ConfigurationValidator.validate(profile), name)
        }
    }

    func testRejectsCredentialBearingEndpointValues() {
        var configuration = AICameraConfiguration.default
        configuration.endpoints = [
            .init(
                id: "unsafe",
                adapter: .openAIChat,
                baseURL: URL(string: "https://user:password@models.example.com")!,
                model: "model"
            ),
        ]
        XCTAssertThrowsError(try ConfigurationValidator.validate(configuration)) { error in
            XCTAssertEqual(error as? ConfigurationError, .invalidEndpointURL("unsafe"))
        }

        configuration.endpoints = [
            .init(
                id: "unsafe-options",
                adapter: .openAIChat,
                baseURL: URL(string: "https://models.example.com")!,
                model: "model",
                options: ["api_key": .string("do-not-store-this")]
            ),
        ]
        XCTAssertThrowsError(try ConfigurationValidator.validate(configuration)) { error in
            XCTAssertEqual(error as? ConfigurationError, .invalidSecretReference("unsafe-options"))
        }
    }

    func testRejectsVirtualCameraFormatThatExtensionCannotPublish() {
        var configuration = AICameraConfiguration.default
        configuration.capture.width = 800
        configuration.capture.height = 600
        XCTAssertThrowsError(try ConfigurationValidator.validate(configuration)) { error in
            XCTAssertEqual(error as? ConfigurationError, .unsupportedVirtualCameraFormat)
        }
    }

    func testRejectsFiniteButDangerousNumericValues() {
        var configuration = AICameraConfiguration.default
        configuration.pipeline.conversation.utteranceSeconds = 1e300
        XCTAssertThrowsError(try ConfigurationValidator.validate(configuration)) { error in
            XCTAssertEqual(error as? ConfigurationError, .invalidRate("conversation"))
        }

        configuration = .default
        configuration.pipeline.videoStages[0].maximumRateHz = 1e-300
        XCTAssertThrowsError(try ConfigurationValidator.validate(configuration)) { error in
            XCTAssertEqual(error as? ConfigurationError, .invalidRate("hands"))
        }

        configuration = .default
        configuration.capture.audioSampleRate = 1e300
        XCTAssertThrowsError(try ConfigurationValidator.validate(configuration)) { error in
            XCTAssertEqual(error as? ConfigurationError, .invalidAudioConfiguration)
        }

        configuration = .default
        configuration.endpoints = [
            .init(
                id: "huge",
                adapter: .openAIChat,
                baseURL: URL(string: "https://models.example.com")!,
                model: "model",
                options: ["max_tokens": .number(1e300)]
            ),
        ]
        XCTAssertThrowsError(try ConfigurationValidator.validate(configuration)) { error in
            XCTAssertEqual(error as? ConfigurationError, .invalidOption(endpointID: "huge", option: "max_tokens"))
        }
    }

}
