import XCTest
@testable import AICameraCore

final class ConfigurationTests: XCTestCase {
    func testDefaultConfigurationIsPurePassthrough() throws {
        let configuration = AICameraConfiguration.default
        try ConfigurationValidator.validate(configuration)
        XCTAssertNil(configuration.capture.videoDeviceID)
        XCTAssertNil(configuration.capture.audioDeviceID)
        XCTAssertFalse(configuration.capture.mirrorVideo)
        XCTAssertTrue(configuration.endpoints.isEmpty)
        XCTAssertTrue(configuration.pipeline.videoStages.isEmpty)
        XCTAssertFalse(configuration.pipeline.conversation.enabled)
        XCTAssertFalse(configuration.pipeline.conversation.realtimeEnabled)
        XCTAssertNil(configuration.pipeline.conversation.realtimeEndpointID)
        XCTAssertFalse(configuration.pipeline.conversation.transcriptionEnabled)
        XCTAssertFalse(configuration.overlays.enabled)
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

    func testScriptOverlayDefaultsAreDisabled() throws {
        let configuration = AICameraConfiguration.default
        try ConfigurationValidator.validate(configuration)
        XCTAssertFalse(configuration.overlays.script.enabled)
        XCTAssertEqual(configuration.overlays.script.maxScriptBytes, 65_536)
        XCTAssertEqual(configuration.overlays.script.maximumFps, 30)
        XCTAssertEqual(configuration.overlays.script.defaultTTLSeconds, 30)
        XCTAssertEqual(configuration.overlays.script.maximumTTLSeconds, 60)
        XCTAssertFalse(configuration.overlays.script.allowSceneData)
    }

    func testDecodesProfileWithoutScriptBlock() throws {
        var configuration = AICameraConfiguration.default
        configuration.overlays.enabled = true
        configuration.overlays.script = ScriptOverlayConfiguration(enabled: true)
        let data = try JSONEncoder().encode(configuration)
        // Simulate a schema-1 profile: strip the script key before decoding.
        var root = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        var overlays = root["overlays"] as! [String: Any]
        overlays.removeValue(forKey: "script")
        root["overlays"] = overlays
        let legacy = try JSONSerialization.data(withJSONObject: root)
        let decoded = try JSONDecoder().decode(AICameraConfiguration.self, from: legacy)
        XCTAssertFalse(decoded.overlays.script.enabled)
        XCTAssertTrue(decoded.overlays.enabled)
    }

    func testRejectsInvalidScriptOverlayConfiguration() {
        var configuration = AICameraConfiguration.default
        configuration.overlays.script = ScriptOverlayConfiguration(
            enabled: true,
            maxScriptBytes: 64,
            maximumFps: 30,
            defaultTTLSeconds: 30,
            maximumTTLSeconds: 60,
            allowSceneData: false
        )
        XCTAssertThrowsError(try ConfigurationValidator.validate(configuration)) { error in
            XCTAssertEqual(error as? ConfigurationError, .invalidOverlayConfiguration)
        }
        configuration.overlays.script = ScriptOverlayConfiguration(
            enabled: true,
            maxScriptBytes: 65_536,
            maximumFps: 30,
            defaultTTLSeconds: 120,
            maximumTTLSeconds: 60,
            allowSceneData: false
        )
        XCTAssertThrowsError(try ConfigurationValidator.validate(configuration)) { error in
            XCTAssertEqual(error as? ConfigurationError, .invalidOverlayConfiguration)
        }
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
        conversation.removeValue(forKey: "realtimeEnabled")
        conversation.removeValue(forKey: "realtimeEndpointID")
        conversation.removeValue(forKey: "transcriptionEnabled")
        conversation.removeValue(forKey: "activationMode")
        conversation.removeValue(forKey: "wakePhrase")
        conversation.removeValue(forKey: "wakeWindowSeconds")
        pipeline["conversation"] = conversation
        root["pipeline"] = pipeline

        let legacy = try JSONSerialization.data(withJSONObject: root)
        let decoded = try JSONDecoder().decode(AICameraConfiguration.self, from: legacy)
        XCTAssertFalse(decoded.pipeline.conversation.realtimeEnabled)
        XCTAssertNil(decoded.pipeline.conversation.realtimeEndpointID)
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
        configuration.pipeline.conversation.transcriptionEnabled = true
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

    func testRealtimeConversationRequiresCompatibleEndpoint() {
        var configuration = AICameraConfiguration.default
        configuration.pipeline.conversation.enabled = true
        configuration.pipeline.conversation.realtimeEnabled = true

        XCTAssertThrowsError(try ConfigurationValidator.validate(configuration)) { error in
            XCTAssertEqual(
                error as? ConfigurationError,
                .missingEndpoint(stageID: "conversation.realtime", endpointID: "<unset>")
            )
        }

        configuration.endpoints = [
            .init(
                id: "not-realtime",
                adapter: .openAIChat,
                baseURL: URL(string: "http://127.0.0.1:2030")!
            ),
        ]
        configuration.pipeline.conversation.realtimeEndpointID = "not-realtime"
        XCTAssertThrowsError(try ConfigurationValidator.validate(configuration)) { error in
            XCTAssertEqual(
                error as? ConfigurationError,
                .incompatibleEndpoint(stageID: "conversation.realtime", adapter: .openAIChat)
            )
        }
    }

    func testRealtimeAndLegacyConversationEndpointsCanCoexist() throws {
        var configuration = AICameraConfiguration.default
        configuration.endpoints = [
            .init(
                id: "realtime",
                adapter: .openAIRealtime,
                baseURL: URL(string: "https://api.example.com")!,
                model: "gpt-realtime",
                options: ["temperature": .number(0.8)]
            ),
            .init(id: "asr", adapter: .openAITranscription, baseURL: URL(string: "https://api.example.com")!),
            .init(id: "agent", adapter: .openAIChat, baseURL: URL(string: "https://api.example.com")!),
            .init(id: "tts", adapter: .openAISpeech, baseURL: URL(string: "https://api.example.com")!),
        ]
        configuration.pipeline.conversation.enabled = true
        configuration.pipeline.conversation.realtimeEnabled = true
        configuration.pipeline.conversation.realtimeEndpointID = "realtime"
        configuration.pipeline.conversation.transcriptionEnabled = true
        configuration.pipeline.conversation.transcriptionEndpointID = "asr"
        configuration.pipeline.conversation.agentEndpointID = "agent"
        configuration.pipeline.conversation.speechEndpointID = "tts"

        XCTAssertNoThrow(try ConfigurationValidator.validate(configuration))
        let decoded = try JSONDecoder().decode(
            AICameraConfiguration.self,
            from: JSONEncoder().encode(configuration)
        )
        XCTAssertTrue(decoded.pipeline.conversation.realtimeEnabled)
        XCTAssertEqual(decoded.pipeline.conversation.realtimeEndpointID, "realtime")
    }

    func testDisabledConversationDoesNotRequireRealtimeEndpoint() {
        var configuration = AICameraConfiguration.default
        configuration.pipeline.conversation.realtimeEnabled = true
        XCTAssertNoThrow(try ConfigurationValidator.validate(configuration))
    }

    func testRealtimeEndpointUsesExistingModelAndOptionBounds() {
        var configuration = AICameraConfiguration.default
        configuration.endpoints = [
            .init(
                id: "realtime",
                adapter: .openAIRealtime,
                baseURL: URL(string: "https://api.example.com")!,
                model: String(repeating: "m", count: 513)
            ),
        ]
        XCTAssertThrowsError(try ConfigurationValidator.validate(configuration)) { error in
            XCTAssertEqual(error as? ConfigurationError, .invalidText("endpoint.realtime"))
        }

        configuration.endpoints[0].model = "gpt-realtime"
        configuration.endpoints[0].options = ["temperature": .number(3)]
        XCTAssertThrowsError(try ConfigurationValidator.validate(configuration)) { error in
            XCTAssertEqual(
                error as? ConfigurationError,
                .invalidOption(endpointID: "realtime", option: "temperature")
            )
        }
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
        configuration.pipeline.videoStages = [
            .init(id: "hands", kind: .handGesture, maximumRateHz: 1e-300)
        ]
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
