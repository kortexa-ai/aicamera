import XCTest
@testable import AICameraCore

final class WhisperConfigurationTests: XCTestCase {
    func testLargeAvailabilityMatchesChipPolicy() {
        for chip in ["Apple M4 Pro", "Apple M4 Max", "Apple M4 Ultra",
                     "Apple M5", "Apple M5 Pro", "Apple M5 Max", "Apple M5 Ultra",
                     "  Apple M4 Pro  "] {
            XCTAssertEqual(BuiltinWhisperModel.availableModels(processorBrand: chip), [.base, .small, .large], chip)
        }
        for chip in ["", "Unknown", "Intel Core i9", "Apple M1", "Apple M2 Ultra",
                     "Apple M3 Max", "Apple M4", "Apple M40 Pro", "Apple M5 Unknown"] {
            XCTAssertEqual(BuiltinWhisperModel.availableModels(processorBrand: chip), [.base, .small], chip)
        }
    }

    func testAllWhisperTiersRoundTripWithoutRemoteRoutes() throws {
        for model in BuiltinWhisperModel.allCases {
            var profile = AICameraConfiguration.default
            profile.pipeline.conversation.transcriptionEnabled = true
            profile.pipeline.conversation.transcriptionProvider = .whisper
            profile.pipeline.conversation.transcriptionWhisperModel = model
            try ConfigurationValidator.validate(profile)
            XCTAssertEqual(try JSONDecoder().decode(AICameraConfiguration.self,
                                                    from: JSONEncoder().encode(profile)), profile)
            XCTAssertNil(profile.pipeline.conversation.transcriptionEndpointID)
        }
        XCTAssertEqual(BuiltinWhisperModel(rawValue: "base"), .base)
        XCTAssertEqual(BuiltinWhisperModel(rawValue: "small-q5_1"), .small)
        XCTAssertEqual(BuiltinWhisperModel.large.fileName, "ggml-large-v3-q5_0.bin")
    }

    func testLegacyProfilesRetainRemoteProviderDefaults() throws {
        let encoded = try JSONEncoder().encode(AICameraConfiguration.default)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var pipeline = try XCTUnwrap(object["pipeline"] as? [String: Any])
        var conversation = try XCTUnwrap(pipeline["conversation"] as? [String: Any])
        for key in ["transcriptionProvider", "transcriptionWhisperModel", "transcriptionLanguage"] { conversation[key] = nil }
        pipeline["conversation"] = conversation; object["pipeline"] = pipeline
        let profile = try JSONDecoder().decode(AICameraConfiguration.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(profile.pipeline.conversation.transcriptionProvider, .openAI)
        XCTAssertFalse(profile.pipeline.conversation.transcriptionEnabled)
    }

    func testLocalTranscriptionNeedsNoEndpointOrNetworkPermissionAndRoundTrips() throws {
        var profile = AICameraConfiguration.default
        profile.pipeline.conversation.transcriptionEnabled = true
        profile.pipeline.conversation.transcriptionProvider = .whisper
        profile.pipeline.conversation.transcriptionWhisperModel = .small
        profile.pipeline.conversation.transcriptionLanguage = "ja"
        try ConfigurationValidator.validate(profile)
        XCTAssertTrue(profile.endpoints.isEmpty)
        let decoded = try JSONDecoder().decode(AICameraConfiguration.self, from: JSONEncoder().encode(profile))
        XCTAssertEqual(decoded, profile)
    }

    func testLocalProfilesCannotRetainAnActiveRemoteTranscriptionReference() {
        var profile = AICameraConfiguration.default
        profile.pipeline.conversation.transcriptionProvider = .whisper
        profile.pipeline.conversation.transcriptionEndpointID = "old-cloud-endpoint"
        XCTAssertThrowsError(try ConfigurationValidator.validate(profile))
    }

    func testMalformedLanguageIsRejectedBeforeRuntime() {
        var profile = AICameraConfiguration.default
        for language in ["", "en\u{0}", "en\r\n", String(repeating: "a", count: 17)] {
            profile.pipeline.conversation.transcriptionLanguage = language
            XCTAssertThrowsError(try ConfigurationValidator.validate(profile))
        }
    }
}
