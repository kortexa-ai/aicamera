import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Public data only. The injected transport supports synthetic fixtures; production uses the
/// existing capped, ephemeral, redirect-denying transport. No account or model credentials enter it.
public actor NWSWeatherClient: WeatherForecastClient {
    public static let maximumResponseBytes = 256 * 1_024
    private let transport: any HTTPTransport
    private let now: @Sendable () -> Date
    private var cached: AgentWeatherForecast?
    private var inFlight = false

    public init(transport: (any HTTPTransport)? = nil, now: @escaping @Sendable () -> Date = { Date() }) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 6
        configuration.timeoutIntervalForResource = 8
        self.transport = transport ?? URLSessionHTTPTransport(
            maximumResponseBytes: Self.maximumResponseBytes, configuration: configuration
        )
        self.now = now
    }

    public func forecast(_ request: AgentWeatherRequest, privacy: PrivacyConfiguration) async throws -> AgentWeatherForecast {
        try Task.checkCancellation()
        try AgentWeatherPolicy.authorize(privacy) // Cached data does not bypass revoked permission.
        let current = now()
        if let cached, cached.request == request,
           (0..<300).contains(current.timeIntervalSince(cached.retrievedAt)),
           (-300...129_600).contains(current.timeIntervalSince(cached.issuedAt)),
           cached.periods.first?.endsAt ?? .distantPast > current {
            return cached
        }
        guard !inFlight else { throw AgentWeatherError.busy }
        inFlight = true
        defer { inFlight = false }
        let pointURL = AgentWeatherPolicy.baseURL.appendingPathComponent("points/\(request.coordinatePath)")
        let point = try await read(PointResponse.self, url: pointURL, privacy: privacy)
        guard let city = boundedText(point.properties.relativeLocation?.properties.city, maximumBytes: 100),
              let state = boundedText(point.properties.relativeLocation?.properties.state, maximumBytes: 8),
              let rawURL = point.properties.forecast, let forecastURL = URL(string: rawURL),
              Self.isForecastURL(forecastURL) else { throw AgentWeatherError.unavailable }
        var components = URLComponents(url: forecastURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [.init(name: "units", value: request.units.nwsValue)]
        let sourceURL = components.url!
        let forecast = try await read(ForecastResponse.self, url: sourceURL, privacy: privacy)
        try Task.checkCancellation()
        let retrievedAt = now()
        guard let issuedAt = Self.date(forecast.properties.updateTime),
              (-300...129_600).contains(retrievedAt.timeIntervalSince(issuedAt)) else {
            throw AgentWeatherError.staleForecast
        }
        let periods = try forecast.properties.periods.prefix(16).compactMap { raw -> AgentWeatherPeriod? in
            guard let start = Self.date(raw.startTime), let end = Self.date(raw.endTime), end > start,
                  end.timeIntervalSince(start) <= 86_400, end <= retrievedAt.addingTimeInterval(8 * 86_400) else {
                throw AgentWeatherError.invalidResponse
            }
            guard end > retrievedAt else { return nil }
            guard let name = boundedText(raw.name, maximumBytes: 80),
                  let conditions = boundedText(raw.shortForecast, maximumBytes: 240),
                  let speed = boundedText(raw.windSpeed, maximumBytes: 60),
                  let direction = boundedText(raw.windDirection, maximumBytes: 12),
                  let temperature = raw.temperature, temperature.isFinite, (-150...160).contains(temperature),
                  raw.temperatureUnit == request.units.symbol else { throw AgentWeatherError.invalidResponse }
            let probability = raw.probabilityOfPrecipitation?.value
            if let probability {
                guard probability.isFinite, (0...100).contains(probability),
                      raw.probabilityOfPrecipitation?.unitCode == "wmoUnit:percent" else {
                    throw AgentWeatherError.invalidResponse
                }
            }
            return .init(name: name, startsAt: start, endsAt: end, temperature: temperature,
                         temperatureUnit: request.units.symbol, conditions: conditions,
                         wind: "\(direction) \(speed)", precipitationPercent: probability)
        }
        guard !periods.isEmpty, periods[0].startsAt <= retrievedAt.addingTimeInterval(86_400),
              zip(periods, periods.dropFirst()).allSatisfy({ $0.endsAt <= $1.startsAt }) else {
            throw AgentWeatherError.unavailable
        }
        let result = AgentWeatherForecast(nearCity: city, state: state, request: request,
                                         issuedAt: issuedAt, retrievedAt: retrievedAt,
                                         sourceURL: sourceURL, periods: Array(periods.prefix(4)))
        cached = result // One place, at most four periods, memory only, no stale fallback on failure.
        return result
    }

    static func isForecastURL(_ url: URL) -> Bool {
        guard url.scheme == "https", url.host == "api.weather.gov", url.port == nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return false }
        return url.path.range(of: #"^/gridpoints/[A-Z]{3}/[0-9]{1,4},[0-9]{1,4}/forecast$"#,
                              options: .regularExpression) != nil
    }

    private func read<Value: Decodable>(_ type: Value.Type, url: URL, privacy: PrivacyConfiguration) async throws -> Value {
        try Task.checkCancellation()
        try AgentWeatherPolicy.authorize(privacy)
        var request = URLRequest(url: url, timeoutInterval: 6)
        request.httpMethod = "GET"
        request.setValue("application/geo+json", forHTTPHeaderField: "Accept")
        request.setValue("AICamera (https://github.com/kortexa-ai/aicamera)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await transport.data(for: request)
        try Task.checkCancellation()
        guard response.url == url, data.count <= Self.maximumResponseBytes else { throw AgentWeatherError.invalidResponse }
        if response.statusCode == 429 { throw AgentWeatherError.rateLimited }
        guard response.statusCode == 200 else { throw AgentWeatherError.unavailable }
        guard ["application/geo+json", "application/json"].contains(response.mimeType?.lowercased() ?? "") else {
            throw AgentWeatherError.invalidResponse
        }
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw AgentWeatherError.invalidResponse }
    }

    private func boundedText(_ text: String?, maximumBytes: Int) -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf8.count <= maximumBytes, !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return text
    }

    private static func date(_ raw: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let value = formatter.date(from: raw) { return value }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: raw)
    }

    private struct PointResponse: Decodable {
        let properties: Properties
        struct Properties: Decodable {
            let forecast: String?
            let relativeLocation: Location?
        }
        struct Location: Decodable {
            let properties: Place
            struct Place: Decodable { let city: String?; let state: String? }
        }
    }
    private struct ForecastResponse: Decodable {
        let properties: Properties
        struct Properties: Decodable { let updateTime: String; let periods: [Period] }
        struct Period: Decodable {
            let name: String?
            let startTime: String
            let endTime: String
            let temperature: Double?
            let temperatureUnit: String?
            let windSpeed: String?
            let windDirection: String?
            let shortForecast: String?
            let probabilityOfPrecipitation: Probability?
            struct Probability: Decodable { let value: Double?; let unitCode: String? }
        }
    }
}
