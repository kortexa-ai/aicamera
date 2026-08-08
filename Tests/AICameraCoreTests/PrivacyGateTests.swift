import XCTest
@testable import AICameraCore

final class PrivacyGateTests: XCTestCase {
    private let remote = EndpointConfiguration(
        id: "cloud-vlm",
        adapter: .openAIVision,
        baseURL: URL(string: "https://models.example.com")!
    )

    func testLocalOnlyRejectsRemoteHost() {
        let gate = PrivacyGate(configuration: .init())
        XCTAssertThrowsError(try gate.authorize(endpoint: remote, data: [.rawFrame])) { error in
            XCTAssertEqual(error as? PrivacyGateError, .remoteHostNotAllowed("models.example.com"))
        }
    }

    func testAllowListAndGrantPermitExactData() throws {
        let privacy = PrivacyConfiguration(
            networkMode: .allowListed,
            allowedHosts: ["models.example.com"],
            grants: [.init(endpointID: remote.id, allowedData: [.rawFrame])]
        )
        let gate = PrivacyGate(configuration: privacy)
        try gate.authorize(endpoint: remote, data: [.rawFrame])
        XCTAssertThrowsError(try gate.authorize(endpoint: remote, data: [.rawFrame, .promptText])) { error in
            XCTAssertEqual(
                error as? PrivacyGateError,
                .dataClassNotGranted(endpointID: "cloud-vlm", dataClass: .promptText)
            )
        }
    }

    func testLoopbackNeedsNoNetworkAllowList() throws {
        let endpoint = EndpointConfiguration(
            id: "local",
            adapter: .openAIChat,
            baseURL: URL(string: "http://localhost:8000")!
        )
        try PrivacyGate(configuration: .init()).authorize(endpoint: endpoint, data: [.promptText])
    }
    func testRemoteAllowListStillRequiresDataGrant() {
        let privacy = PrivacyConfiguration(
            networkMode: .allowListed,
            allowedHosts: ["models.example.com"]
        )
        XCTAssertThrowsError(try PrivacyGate(configuration: privacy).authorize(endpoint: remote, data: [.rawFrame])) { error in
            XCTAssertEqual(
                error as? PrivacyGateError,
                .dataClassNotGranted(endpointID: "cloud-vlm", dataClass: .rawFrame)
            )
        }
    }

    func testConfigurationRejectsMediaPersistence() {
        var configuration = AICameraConfiguration.default
        configuration.privacy.persistMedia = true
        XCTAssertThrowsError(try ConfigurationValidator.validate(configuration)) { error in
            XCTAssertEqual(error as? ConfigurationError, .mediaPersistenceUnsupported)
        }
    }

    func testRemoteGrantDoesNotMakeLoopbackRequireGrant() throws {
        let privacy = PrivacyConfiguration(
            networkMode: .allowListed,
            allowedHosts: ["models.example.com"],
            grants: [.init(endpointID: "cloud-vlm", allowedData: [.rawFrame])]
        )
        let local = EndpointConfiguration(
            id: "local-asr",
            adapter: .kortexaPCMTranscription,
            baseURL: URL(string: "http://127.0.0.1:4002")!
        )
        XCTAssertNoThrow(try PrivacyGate(configuration: privacy).authorize(endpoint: local, data: [.rawAudio]))
    }

}
