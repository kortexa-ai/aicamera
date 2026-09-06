import XCTest
@testable import AICameraCore

final class AgentTranslationControlsTests: XCTestCase {
    private func parse(_ arguments: String) -> AgentToolCommand? {
        AgentToolCommand.parse(name: "set_translation", arguments: arguments, script: AICameraConfiguration.default.overlays.script)
    }

    func testTranslationToolRequiresAnExplicitSupportedChange() throws {
        XCTAssertEqual(parse(#"{"enabled":false}"#), .setTranslation(try XCTUnwrap(AgentTranslationRequest(enabled: false))))
        XCTAssertEqual(parse(#"{"targetLanguage":"es"}"#), .setTranslation(try XCTUnwrap(AgentTranslationRequest(targetLanguage: "es"))))
        XCTAssertEqual(parse(#"{"enabled":true,"targetLanguage":"zh-Hant"}"#),
                       .setTranslation(try XCTUnwrap(AgentTranslationRequest(enabled: true, targetLanguage: "zh-Hant"))))
        for invalid in ["{}", #"{"enabled":1}"#, #"{"enabled":"true"}"#, #"{"enabled":null}"#,
                        #"{"targetLanguage":"Klingon"}"#, #"{"targetLanguage":"auto"}"#,
                        #"{"targetLanguage":true}"#, #"{"enabled":true,"unmute":true}"#] {
            XCTAssertNil(parse(invalid), "Invalid controls accepted: \(invalid)")
        }
    }

    func testLanguageCatalogAndSchemaHaveTheSameSupportedTargets() throws {
        XCTAssertEqual(Set(TranslationLanguageCatalog.languages.map(\.code)).count, TranslationLanguageCatalog.languages.count)
        XCTAssertEqual(TranslationLanguageCatalog.name(for: "fr"), "French")
        let tools = AgentToolCatalog.definitions(capabilities: .init(cameraState: true, translation: true),
                                               script: AICameraConfiguration.default.overlays.script)
        XCTAssertEqual(tools.compactMap { $0["name"] as? String }, ["get_camera_state", "set_translation"])
        let schema = try XCTUnwrap(tools.last?["parameters"] as? [String: Any])
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        let language = try XCTUnwrap(properties["targetLanguage"] as? [String: Any])
        XCTAssertEqual(language["enum"] as? [String], TranslationLanguageCatalog.targetCodes)
        XCTAssertNil(AgentToolCommand.parse(name: "get_camera_state", arguments: #"{"includeSecrets":true}"#,
                                            script: AICameraConfiguration.default.overlays.script))
    }
}
