import XCTest
@testable import AICameraCore

final class AgentWeatherTests: XCTestCase {
    func testStrictArgumentsAndCoarseCoordinates() throws {
        let script = ScriptOverlayConfiguration()
        let request = try XCTUnwrap(AgentWeatherRequest(latitude: 47.6062, longitude: -122.3321))
        XCTAssertEqual(request.latitude, 47.61)
        XCTAssertEqual(request.longitude, -122.33)
        XCTAssertEqual(request.coordinatePath, "47.61,-122.33")
        XCTAssertEqual(AgentToolCommand.parse(name: "get_weather_forecast", arguments: #"{"latitude":47.6062,"longitude":-122.3321}"#, script: script), .weatherForecast(request))
        for bad in [#"{}"#, #"{"latitude":true,"longitude":2}"#, #"{"latitude":"47","longitude":2}"#,
                    #"{"latitude":91,"longitude":2}"#, #"{"latitude":4,"longitude":181}"#,
                    #"{"latitude":4,"longitude":2,"units":"kelvin"}"#,
                    #"{"latitude":4,"longitude":2,"units":null}"#,
                    #"{"latitude":4,"longitude":2,"address":"home"}"#] {
            XCTAssertNil(AgentToolCommand.parse(name: "get_weather_forecast", arguments: bad, script: script))
        }
        XCTAssertNil(AgentWeatherRequest(latitude: .nan, longitude: 1))
        XCTAssertNil(AgentWeatherRequest(latitude: 1, longitude: .infinity))
    }

    func testOptInRequiresToolsHostAndOnlyApproximateLocationGrant() throws {
        var profile = AICameraConfiguration.default
        XCTAssertFalse(AgentWeatherPolicy.isAvailable(in: profile))
        AgentWeatherPolicy.setEnabled(true, in: &profile)
        XCTAssertFalse(AgentWeatherPolicy.isAvailable(in: profile), "Tools must also be enabled")
        profile.overlays.script.enabled = true
        XCTAssertTrue(AgentWeatherPolicy.isAvailable(in: profile))
        XCTAssertNoThrow(try ConfigurationValidator.validate(profile))
        XCTAssertEqual(profile.privacy.grants, [.init(endpointID: AgentWeatherPolicy.endpointID, allowedData: [.approximateLocation])])
        XCTAssertTrue(profile.endpoints.isEmpty, "A public data lookup must not create a fake model endpoint")
        var denied = profile
        denied.privacy.networkMode = .localOnly
        XCTAssertFalse(AgentWeatherPolicy.isAvailable(in: denied))
        denied = profile; denied.privacy.allowedHosts = ["api.weather.gov.example.com"]
        XCTAssertFalse(AgentWeatherPolicy.isAvailable(in: denied))
        denied = profile; denied.privacy.grants = []
        XCTAssertFalse(AgentWeatherPolicy.isAvailable(in: denied))
        denied = profile; denied.privacy.grants[0].allowedData.insert(.rawAudio)
        XCTAssertThrowsError(try ConfigurationValidator.validate(denied))
        AgentWeatherPolicy.setEnabled(false, in: &profile)
        XCTAssertFalse(AgentWeatherPolicy.isAvailable(in: profile))
        XCTAssertTrue(profile.privacy.grants.isEmpty)
        XCTAssertTrue(profile.overlays.script.enabled, "Turning off weather must leave other tools enabled")
        XCTAssertThrowsError(try AgentWeatherPolicy.authorize(profile.privacy))
    }

    func testExistingProfilesDecodeWithoutEnablingWeather() throws {
        let profile = AICameraConfiguration.default
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as? [String: Any])
        var overlays = try XCTUnwrap(object["overlays"] as? [String: Any])
        var script = try XCTUnwrap(overlays["script"] as? [String: Any])
        script.removeValue(forKey: "weatherForecastEnabled")
        overlays["script"] = script; object["overlays"] = overlays
        let legacy = try JSONDecoder().decode(AICameraConfiguration.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(legacy, profile)
        XCTAssertFalse(AgentWeatherPolicy.isAvailable(in: legacy))
    }

    func testWeatherCatalogRequiresCapabilityAndHonestPrompt() throws {
        let script = ScriptOverlayConfiguration()
        let absent = AgentToolCatalog.definitions(capabilities: .init(visuals: true), script: script)
        XCTAssertFalse(absent.contains { $0["name"] as? String == "get_weather_forecast" })
        let available = AgentToolCatalog.definitions(capabilities: .init(weather: true), script: script)
        XCTAssertEqual(available.count, 1)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(available))
        let prompt = AgentToolCatalog.instructions(capabilities: .init(weather: true))
        XCTAssertTrue(prompt.contains("nearCity/state"))
        XCTAssertTrue(prompt.contains("never device location"))
        XCTAssertFalse(AgentToolCatalog.instructions(capabilities: .init()).contains("get_weather_forecast"))
    }
}
