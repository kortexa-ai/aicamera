import XCTest
@testable import AICameraCore

final class WhisperConfigurationTests: XCTestCase {
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
