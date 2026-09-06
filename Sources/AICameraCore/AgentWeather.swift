import Foundation

public enum AgentWeatherUnits: String, CaseIterable, Sendable {
    case celsius, fahrenheit
    var nwsValue: String { self == .celsius ? "si" : "us" }
    var symbol: String { self == .celsius ? "C" : "F" }
}

/// Coordinates describe a requested public place, never an automatic device-location lookup.
public struct AgentWeatherRequest: Equatable, Sendable {
    public let latitude: Double
    public let longitude: Double
    public let units: AgentWeatherUnits

    public init?(latitude: Double, longitude: Double, units: AgentWeatherUnits = .celsius) {
        guard latitude.isFinite, longitude.isFinite,
              (-90...90).contains(latitude), (-180...180).contains(longitude) else { return nil }
        self.latitude = (latitude * 100).rounded() / 100
        self.longitude = (longitude * 100).rounded() / 100
        self.units = units
    }

    var coordinatePath: String {
        String(format: "%.2f,%.2f", locale: Locale(identifier: "en_US_POSIX"), latitude, longitude)
    }
}

public enum AgentWeatherPolicy {
    public static let endpointID = "builtin-nws-forecast"
    public static let baseURL = URL(string: "https://api.weather.gov")!

    /// Called only by the user's Settings toggle. No agent tool can grant this permission.
    public static func setEnabled(_ enabled: Bool, in profile: inout AICameraConfiguration) {
        profile.overlays.script.weatherForecastEnabled = enabled
        profile.privacy.grants.removeAll { $0.endpointID == endpointID }
        if enabled {
            profile.privacy.networkMode = .allowListed
            if !profile.privacy.allowedHosts.contains(where: { $0.lowercased() == baseURL.host }) {
                profile.privacy.allowedHosts.append(baseURL.host!)
            }
            profile.privacy.grants.append(.init(endpointID: endpointID, allowedData: [.approximateLocation]))
        }
    }

    public static func isAvailable(in profile: AICameraConfiguration) -> Bool {
        guard profile.overlays.script.enabled, profile.overlays.script.weatherForecastEnabled else { return false }
        return (try? authorize(profile.privacy)) != nil
    }

    public static func authorize(_ privacy: PrivacyConfiguration) throws {
        try PrivacyGate(configuration: privacy).authorize(
            endpointID: endpointID, baseURL: baseURL, data: [.approximateLocation]
        )
    }
}

public enum AgentWeatherError: LocalizedError, Equatable {
    case unavailable, rateLimited, invalidResponse, staleForecast, busy
    public var errorDescription: String? {
        switch self {
        case .unavailable: return "A U.S. National Weather Service forecast is unavailable for this location."
        case .rateLimited: return "The forecast service is busy. Try again later."
        case .invalidResponse: return "The forecast service returned an unsupported response."
        case .staleForecast: return "The forecast is too old to present as current."
        case .busy: return "Another forecast lookup is already in progress."
        }
    }
}

public struct AgentWeatherPeriod: Equatable, Sendable {
    public let name: String
    public let startsAt: Date
    public let endsAt: Date
    public let temperature: Double
    public let temperatureUnit: String
    public let conditions: String
    public let wind: String
    public let precipitationPercent: Double?
}

public struct AgentWeatherForecast: Equatable, Sendable {
    public let nearCity: String
    public let state: String
    public let request: AgentWeatherRequest
    public let issuedAt: Date
    public let retrievedAt: Date
    public let sourceURL: URL
    public let periods: [AgentWeatherPeriod]

    /// Dates, units, and the provider's nearby location travel with the facts through tool rounds.
    public var toolResult: [String: Any] {
        let formatter = ISO8601DateFormatter()
        return ["ok": true, "kind": "forecast", "provider": "National Weather Service",
                "coverage": "United States; approximate requested coordinates, near the named place",
                "nearCity": nearCity, "state": state,
                "latitude": request.latitude, "longitude": request.longitude,
                "issuedAt": formatter.string(from: issuedAt), "retrievedAt": formatter.string(from: retrievedAt),
                "sourceURL": sourceURL.absoluteString,
                "periods": periods.map { period -> [String: Any] in
                    var value: [String: Any] = ["name": period.name,
                        "startsAt": formatter.string(from: period.startsAt), "endsAt": formatter.string(from: period.endsAt),
                        "temperature": period.temperature, "temperatureUnit": period.temperatureUnit,
                        "conditions": period.conditions, "wind": period.wind]
                    if let probability = period.precipitationPercent { value["precipitationPercent"] = probability }
                    return value
                }]
    }

    /// A deterministic compact fallback; the model can also build a sourced card/illustration.
    public var cardRequest: AgentCardRequest? {
        guard let first = periods.first else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "MMM d HH:mm 'UTC'"
        return .init(title: "Forecast near \(nearCity), \(state)",
                     body: "\(first.name): \(first.temperature.formatted())°\(first.temperatureUnit)\n\(first.conditions)",
                     source: "NWS · issued \(formatter.string(from: issuedAt))", style: .metric)
    }
}

public protocol WeatherForecastClient: Sendable {
    func forecast(_ request: AgentWeatherRequest, privacy: PrivacyConfiguration) async throws -> AgentWeatherForecast
}
