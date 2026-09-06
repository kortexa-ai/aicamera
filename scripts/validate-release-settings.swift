import AICameraCore
import AICameraReleaseCore
import Foundation

// Both code generations read a single disposable synthetic settings file. No user settings,
// defaults domain, Keychain, model, network, device, or installed app is accessed.
@main
struct ReleaseSettingsValidation {
    typealias Current = AICameraCore.AICameraConfiguration
    typealias Released = AICameraReleaseCore.AICameraConfiguration
    struct Failure: Error { let message: String }

    static func require(_ value: Bool, _ message: String) throws {
        if !value { throw Failure(message: message) }
    }

    static func main() throws {
        guard CommandLine.arguments.count == 2 else { throw Failure(message: "Supply a disposable synthetic-file path") }
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw Failure(message: "Refusing to replace an existing file")
        }
        let currentStore = AICameraCore.ConfigurationStore(fileURL: url)
        let releasedStore = AICameraReleaseCore.ConfigurationStore(fileURL: url)

        try releasedStore.save(.default)
        let upgraded = try currentStore.load()
        try require(upgraded == Current.default, "Public default settings changed on upgrade")
        try require(upgraded.pipeline.conversation.agentListeningMode == .conversation,
                    "Upgrade changed the default listening behavior")
        try require(!upgraded.overlays.script.weatherForecastEnabled, "Upgrade enabled remote weather")

        try currentStore.save(.default)
        try require(try releasedStore.load() == Released.default, "Current defaults cannot be read by 0.2.0")
        var candidate = Current.default
        candidate.profileName = "Synthetic compatibility fixture"
        candidate.capture.mirrorVideo = true
        candidate.pipeline.translation.targetLanguage = "es"
        candidate.pipeline.conversation.agentListeningMode = .oneQuestion
        candidate.overlays.script.enabled = true
        var expected = Released.default
        expected.profileName = candidate.profileName
        expected.capture.mirrorVideo = true
        expected.pipeline.translation.targetLanguage = "es"
        expected.overlays.script.enabled = true
        try currentStore.save(candidate)
        try require(try releasedStore.load() == expected, "New optional listening field changed old settings")
        print("0.2.0 → current defaults and current defaults/one-question settings → 0.2.0 passed. Old code ignores the new listening option.")

        AgentWeatherPolicy.setEnabled(true, in: &candidate)
        try currentStore.save(candidate)
        try require(AgentWeatherPolicy.isAvailable(in: try currentStore.load()), "Current weather setup is invalid")
        try rejectWeatherWithoutChangingFile(releasedStore, at: url)
        // Turning Tools off alone retains the saved weather permission.
        candidate.overlays.script.enabled = false
        try currentStore.save(candidate)
        try rejectWeatherWithoutChangingFile(releasedStore, at: url)
        print("0.2.0 rejects the new weather grant without modifying its file, including when Tools alone is off.")

        AgentWeatherPolicy.setEnabled(false, in: &candidate)
        try currentStore.save(candidate)
        expected.overlays.script.enabled = false
        expected.privacy.networkMode = .allowListed
        if !expected.privacy.allowedHosts.contains("api.weather.gov") {
            expected.privacy.allowedHosts.append("api.weather.gov")
        }
        try require(try releasedStore.load() == expected, "Weather Off did not restore 0.2.0 compatibility")
        try require(try currentStore.load() == candidate, "Rollback check changed current settings")
        print("Explicit Weather forecasts Off restores 0.2.0 readability and preserves the other synthetic settings.")
        print("Release-settings compatibility passed. No actual settings, installed app, device, credential, or network was used.")
    }

    private static func rejectWeatherWithoutChangingFile(_ store: AICameraReleaseCore.ConfigurationStore,
                                                          at url: URL) throws {
        let before = try Data(contentsOf: url)
        do {
            _ = try store.load()
            throw Failure(message: "Old code unexpectedly accepted the new weather permission")
        } catch DecodingError.dataCorrupted(let context) {
            try require(context.codingPath.contains { $0.stringValue == "allowedData" },
                        "Old code rejected an unrelated setting")
        }
        try require(try Data(contentsOf: url) == before, "Rejected settings file was modified")
    }
}
