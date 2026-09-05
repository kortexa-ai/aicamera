import XCTest
@testable import AICameraCore

final class SupportedConfigurationPolicyTests: XCTestCase {
    func testUnsupportedRoutesAreDisabledWithoutErasingProfileMetadata() {
        var profile = AICameraConfiguration.default
        let endpoint = EndpointConfiguration(
            id: "legacy", adapter: .openAIRealtime, baseURL: URL(string: "https://example.com")!,
            model: "old-model", auth: .init(kind: .bearerKeychain, reference: "old-account")
        )
        profile.endpoints = [endpoint]
        profile.pipeline.conversation.enabled = true
        profile.pipeline.conversation.realtimeEnabled = true
        profile.pipeline.conversation.realtimeEndpointID = endpoint.id
        profile.pipeline.videoStages = [
            .init(id: "hands", kind: .handGesture),
            .init(id: "local", kind: .objectDetection, options: ["provider": .string("builtin")]),
            .init(id: "remote", kind: .objectDetection, endpointID: endpoint.id),
            .init(id: "vlm", kind: .visionLanguage, endpointID: endpoint.id)
        ]
        XCTAssertTrue(SupportedConfigurationPolicy.disableUnsupportedRoutes(in: &profile))
        XCTAssertEqual(profile.endpoints, [endpoint])
        XCTAssertEqual(profile.pipeline.conversation.realtimeEndpointID, endpoint.id)
        XCTAssertFalse(profile.pipeline.conversation.enabled)
        XCTAssertEqual(profile.pipeline.videoStages.map(\.enabled), [true, true, false, false])
        XCTAssertEqual(profile.pipeline.videoStages[2].endpointID, endpoint.id)
        XCTAssertFalse(SupportedConfigurationPolicy.disableUnsupportedRoutes(in: &profile))
    }

    func testPublicConversationAndLocalTranscriptionRemainEnabled() throws {
        var profile = AICameraConfiguration.default
        profile.pipeline.conversation.enabled = true
        profile.pipeline.conversation.realtimeEnabled = true
        profile.pipeline.conversation.realtimeEndpointID = "public"
        profile.pipeline.conversation.transcriptionEnabled = true
        profile.pipeline.conversation.transcriptionProvider = .whisper
        profile.endpoints = [.init(id: "public", adapter: .openAIRealtime, baseURL: URL(string: "https://api.openai.com")!)]
        for auth in [RealtimeAuthentication.apiKey, .codex] {
            profile.pipeline.conversation.realtimeAuthentication = auth
            let before = profile
            XCTAssertFalse(SupportedConfigurationPolicy.disableUnsupportedRoutes(in: &profile))
            XCTAssertEqual(profile, before)
        }
    }

    func testLegacyConversationIsDisabledWithoutChangingIndependentTranscription() {
        var profile = AICameraConfiguration.default
        profile.pipeline.conversation.enabled = true
        profile.pipeline.conversation.realtimeEnabled = false
        profile.pipeline.conversation.transcriptionEnabled = true
        profile.pipeline.conversation.transcriptionProvider = .whisper
        XCTAssertTrue(SupportedConfigurationPolicy.disableUnsupportedRoutes(in: &profile))
        XCTAssertFalse(profile.pipeline.conversation.enabled)
        XCTAssertTrue(profile.pipeline.conversation.transcriptionEnabled)
    }

    func testEndpointMatchingRejectsUnsupportedDestinationsAndOverrides() {
        for address in ["http://api.openai.com", "https://api.openai.com.example.com", "https://api.openai.com:8443", "https://user@api.openai.com", "https://api.openai.com?key=value", "https://api.openai.com#fragment", "https://api.openai.com/unsupported"] {
            let endpoint = EndpointConfiguration(id: "test", adapter: .openAIRealtime, baseURL: URL(string: address)!)
            XCTAssertFalse(SupportedConfigurationPolicy.isPublicRealtime(endpoint), address)
        }
        var endpoint = EndpointConfiguration(id: "test", adapter: .openAIRealtime, baseURL: URL(string: "https://api.openai.com/v1")!)
        XCTAssertTrue(SupportedConfigurationPolicy.isPublicRealtime(endpoint))
        endpoint.path = "/alternate"
        XCTAssertFalse(SupportedConfigurationPolicy.isPublicRealtime(endpoint))
        endpoint.path = nil
        endpoint.adapter = .openAIChat
        XCTAssertFalse(SupportedConfigurationPolicy.isPublicRealtime(endpoint))
    }
}
