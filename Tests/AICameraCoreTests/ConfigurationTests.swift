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

    func testLegacyConversationDecodesWithWakePhraseDefaults() throws {
        let encoded = try JSONEncoder().encode(AICameraConfiguration.default)
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var pipeline = try XCTUnwrap(root["pipeline"] as? [String: Any])
        var conversation = try XCTUnwrap(pipeline["conversation"] as? [String: Any])
        conversation.removeValue(forKey: "transcriptionEnabled")
        conversation.removeValue(forKey: "activationMode")
        conversation.removeValue(forKey: "wakePhrase")
        conversation.removeValue(forKey: "wakeWindowSeconds")
        pipeline["conversation"] = conversation
        root["pipeline"] = pipeline

        let legacy = try JSONSerialization.data(withJSONObject: root)
        let decoded = try JSONDecoder().decode(AICameraConfiguration.self, from: legacy)
        XCTAssertFalse(decoded.pipeline.conversation.transcriptionEnabled)
        XCTAssertEqual(decoded.pipeline.conversation.activationMode, .alwaysListening)
        XCTAssertEqual(decoded.pipeline.conversation.wakePhrase, ConversationConfiguration.defaultWakePhrase)
        XCTAssertEqual(decoded.pipeline.conversation.wakeWindowSeconds, 8)
    }

    func testLegacyConversationWithASREndpointKeepsTranscriptionEnabled() throws {
        var configuration = AICameraConfiguration.default
        configuration.endpoints = [EndpointConfiguration(
            id: "asr",
            adapter: .kortexaPCMTranscription,
            baseURL: URL(string: "http://127.0.0.1:4002")!
        )]
        configuration.pipeline.conversation.transcriptionEndpointID = "asr"
        let encoded = try JSONEncoder().encode(configuration)
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var pipeline = try XCTUnwrap(root["pipeline"] as? [String: Any])
        var conversation = try XCTUnwrap(pipeline["conversation"] as? [String: Any])
        conversation.removeValue(forKey: "transcriptionEnabled")
        pipeline["conversation"] = conversation
        root["pipeline"] = pipeline

        let legacy = try JSONSerialization.data(withJSONObject: root)
        let decoded = try JSONDecoder().decode(AICameraConfiguration.self, from: legacy)
        XCTAssertTrue(decoded.pipeline.conversation.transcriptionEnabled)
        XCTAssertNoThrow(try ConfigurationValidator.validate(decoded))
    }

    func testLegacyEnabledConversationWithoutASREndpointRemainsValid() throws {
        let encoded = try JSONEncoder().encode(AICameraConfiguration.default)
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var pipeline = try XCTUnwrap(root["pipeline"] as? [String: Any])
        var conversation = try XCTUnwrap(pipeline["conversation"] as? [String: Any])
        conversation["enabled"] = true
        conversation.removeValue(forKey: "transcriptionEnabled")
        conversation.removeValue(forKey: "activationMode")
        conversation.removeValue(forKey: "wakePhrase")
        conversation.removeValue(forKey: "wakeWindowSeconds")
        pipeline["conversation"] = conversation
        root["pipeline"] = pipeline

        let legacy = try JSONSerialization.data(withJSONObject: root)
        let decoded = try JSONDecoder().decode(AICameraConfiguration.self, from: legacy)
        XCTAssertFalse(decoded.pipeline.conversation.transcriptionEnabled)
        XCTAssertEqual(decoded.pipeline.conversation.activationMode, .alwaysListening)
        XCTAssertNoThrow(try ConfigurationValidator.validate(decoded))
    }

    func testMalformedLegacyConversationStillRequiresExistingFields() throws {
        let encoded = try JSONEncoder().encode(AICameraConfiguration.default)
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var pipeline = try XCTUnwrap(root["pipeline"] as? [String: Any])
        var conversation = try XCTUnwrap(pipeline["conversation"] as? [String: Any])
        conversation.removeValue(forKey: "systemPrompt")
        pipeline["conversation"] = conversation
        root["pipeline"] = pipeline

        let malformed = try JSONSerialization.data(withJSONObject: root)
        XCTAssertThrowsError(try JSONDecoder().decode(AICameraConfiguration.self, from: malformed))
    }

    func testEffectiveTranscriptionRequiresEndpoint() {
        var configuration = AICameraConfiguration.default
        configuration.pipeline.conversation.enabled = true
        XCTAssertThrowsError(try ConfigurationValidator.validate(configuration)) { error in
            XCTAssertEqual(
                error as? ConfigurationError,
                .missingEndpoint(stageID: "conversation.asr", endpointID: "<unset>")
            )
        }

        configuration.pipeline.conversation.transcriptionEnabled = false
        configuration.pipeline.conversation.respondToFinalTranscripts = false
        configuration.pipeline.conversation.respondToGestures = false
        XCTAssertNoThrow(try ConfigurationValidator.validate(configuration))
    }

    func testRejectsInvalidWakePhraseConfiguration() {
        var configuration = AICameraConfiguration.default
        configuration.pipeline.conversation.wakePhrase = "   "
        XCTAssertThrowsError(try ConfigurationValidator.validate(configuration)) { error in
            XCTAssertEqual(error as? ConfigurationError, .invalidText("conversation"))
        }

        configuration = .default
        configuration.pipeline.conversation.wakePhrase = "!!!"
        XCTAssertThrowsError(try ConfigurationValidator.validate(configuration)) { error in
            XCTAssertEqual(error as? ConfigurationError, .invalidText("conversation"))
        }

        configuration = .default
        configuration.pipeline.conversation.wakeWindowSeconds = 31
        XCTAssertThrowsError(try ConfigurationValidator.validate(configuration)) { error in
            XCTAssertEqual(error as? ConfigurationError, .invalidRate("conversation"))
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
