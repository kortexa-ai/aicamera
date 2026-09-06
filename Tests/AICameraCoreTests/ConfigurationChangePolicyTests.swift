import XCTest
@testable import AICameraCore

final class ConfigurationChangePolicyTests: XCTestCase {
    func testOnlyTranslationLanguageChangesReuseTheLiveGraph() {
        let original = AICameraConfiguration.default
        XCTAssertEqual(ConfigurationChangePolicy.classify(from: original, to: original), .unchanged)
        var changed = original
        changed.pipeline.translation.targetLanguage = "es"
        XCTAssertEqual(ConfigurationChangePolicy.classify(from: original, to: changed), .translationLanguages)
        changed.pipeline.translation.sourceLanguage = "fr"
        XCTAssertEqual(ConfigurationChangePolicy.classify(from: original, to: changed), .translationLanguages)
        changed.capture.width += 1
        XCTAssertEqual(ConfigurationChangePolicy.classify(from: original, to: changed), .restartMedia)
    }

    func testSimultaneousSensitiveConfigurationChangesStillRestart() {
        let original = AICameraConfiguration.default
        for mutate: (inout AICameraConfiguration) -> Void in [
            { $0.pipeline.translation.enabled.toggle() },
            { $0.pipeline.translation.model = "different-model" },
            { $0.pipeline.conversation.realtimeEnabled.toggle() },
            { $0.capture.mirrorVideo.toggle() },
            { $0.privacy.allowedHosts.append("example.com") },
            { $0.overlays.script.enabled.toggle() }
        ] {
            var changed = original
            changed.pipeline.translation.targetLanguage = "de"
            mutate(&changed)
            XCTAssertEqual(ConfigurationChangePolicy.classify(from: original, to: changed), .restartMedia)
        }
    }
}
