import XCTest
@testable import AICameraCore

final class NWSWeatherClientTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_783_339_200) // Synthetic fixed clock.
    private let request = AgentWeatherRequest(latitude: 47.6062, longitude: -122.3321)!
    private var privacy: PrivacyConfiguration {
        var profile = AICameraConfiguration.default
        AgentWeatherPolicy.setEnabled(true, in: &profile)
        return profile.privacy
    }

    private func responses(forecastURL: String = "https://api.weather.gov/gridpoints/SEW/125,68/forecast",
                           age: TimeInterval = 600, temperatureUnit: String = "C",
                           conditions: String = "Partly Cloudy") throws -> [Data] {
        let formatter = ISO8601DateFormatter()
        let point: [String: Any] = ["properties": ["forecast": forecastURL,
            "relativeLocation": ["properties": ["city": "Seattle", "state": "WA"]]]]
        let periods: [[String: Any]] = (0..<8).map { index in
            ["name": "Period \(index + 1)", "startTime": formatter.string(from: date.addingTimeInterval(Double(index) * 43_200 - 600)),
             "endTime": formatter.string(from: date.addingTimeInterval(Double(index + 1) * 43_200 - 600)),
             "temperature": 21, "temperatureUnit": temperatureUnit, "shortForecast": conditions,
             "windSpeed": "5 km/h", "windDirection": "NW", "probabilityOfPrecipitation": ["unitCode": "wmoUnit:percent", "value": 10]]
        }
        let forecast: [String: Any] = ["properties": ["updateTime": formatter.string(from: date.addingTimeInterval(-age)), "periods": periods]]
        return try [point, forecast].map { try JSONSerialization.data(withJSONObject: $0) }
    }

    func testLookupIsBoundedGroundedAndCanContinueIntoACard() async throws {
        let transport = WeatherFixtureTransport(responses: try responses())
        let date = date
        let client = NWSWeatherClient(transport: transport, now: { date })
        var turn = AgentToolTurn()
        XCTAssertTrue(turn.admit(callID: "lookup")); turn.endedResponse()
        let result = try await client.forecast(request, privacy: privacy)
        XCTAssertEqual(result.nearCity, "Seattle")
        XCTAssertEqual(result.periods.count, 4)
        XCTAssertEqual(result.periods.first?.temperatureUnit, "C")
        XCTAssertEqual(result.retrievedAt, date)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(result.toolResult))
        XCTAssertLessThan(try JSONSerialization.data(withJSONObject: result.toolResult).count, 6_000)
        turn.completed(callID: "lookup")
        XCTAssertEqual(turn.takeNext(), .continueResponse(allowTools: true))
        XCTAssertTrue(turn.admit(callID: "card"))
        let card = try XCTUnwrap(result.cardRequest)
        XCTAssertTrue(AgentPresentationState.valid(card))
        XCTAssertTrue(card.source?.contains("NWS") == true)
        XCTAssertNotNil(AgentPresentationState().show(card))
        turn.completed(callID: "card"); turn.endedResponse()
        XCTAssertEqual(turn.takeNext(), .continueResponse(allowTools: true))
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].url?.path, "/points/47.61,-122.33")
        XCTAssertEqual(requests[1].url?.query, "units=si")
        for sent in requests {
            XCTAssertEqual(sent.httpMethod, "GET")
            XCTAssertNil(sent.httpBody)
            XCTAssertNil(sent.value(forHTTPHeaderField: "Authorization"))
            XCTAssertNil(sent.value(forHTTPHeaderField: "Cookie"))
            XCTAssertTrue(sent.value(forHTTPHeaderField: "User-Agent")?.contains("AICamera") == true)
            XCTAssertEqual(sent.timeoutInterval, 6)
        }
        let cached = try await client.forecast(request, privacy: privacy)
        XCTAssertEqual(cached, result)
        let count = await transport.requests.count
        XCTAssertEqual(count, 2)
        do { _ = try await client.forecast(request, privacy: .init()); XCTFail("Revoked permission must deny cached data") }
        catch { XCTAssertTrue(error is PrivacyGateError) }
    }

    func testDeniedPermissionSendsNoRequest() async throws {
        let transport = WeatherFixtureTransport(responses: [])
        do { _ = try await NWSWeatherClient(transport: transport).forecast(request, privacy: .init()); XCTFail() }
        catch { XCTAssertTrue(error is PrivacyGateError) }
        let count = await transport.requests.count
        XCTAssertEqual(count, 0)
    }

    func testExpiredCacheDoesNotMaskServiceFailure() async throws {
        let clock = WeatherFixtureClock(date)
        let transport = WeatherFixtureTransport(responses: try responses())
        let client = NWSWeatherClient(transport: transport, now: { clock.value })
        _ = try await client.forecast(request, privacy: privacy)
        clock.advance(301)
        do { _ = try await client.forecast(request, privacy: privacy); XCTFail("An expired cache must not hide a failed refresh") }
        catch { XCTAssertEqual(error as? AgentWeatherError, .unavailable) }
        let count = await transport.requests.count
        XCTAssertEqual(count, 3)
    }

    func testExpiredPeriodsAreOmittedFromARefreshedForecast() async throws {
        let clock = WeatherFixtureClock(date.addingTimeInterval(43_200))
        let client = NWSWeatherClient(transport: WeatherFixtureTransport(responses: try responses()), now: { clock.value })
        let result = try await client.forecast(request, privacy: privacy)
        XCTAssertEqual(result.periods.first?.name, "Period 2")
        XCTAssertTrue(result.periods.allSatisfy { $0.endsAt > clock.value })
    }

    func testUntrustedLinkedURLsCannotCauseAnotherRequest() async throws {
        for raw in ["https://example.com/gridpoints/SEW/125,68/forecast", "http://api.weather.gov/gridpoints/SEW/125,68/forecast",
                    "https://api.weather.gov/gridpoints/SEW/125,68/forecast?secret=x", "https://user@api.weather.gov/gridpoints/SEW/125,68/forecast",
                    "https://api.weather.gov:444/gridpoints/SEW/125,68/forecast", "https://api.weather.gov/anything"] {
            let transport = WeatherFixtureTransport(responses: try responses(forecastURL: raw))
            do { _ = try await NWSWeatherClient(transport: transport).forecast(request, privacy: privacy); XCTFail(raw) }
            catch { XCTAssertEqual(error as? AgentWeatherError, .unavailable) }
            let count = await transport.requests.count
            XCTAssertEqual(count, 1)
        }
    }

    func testHTTPFailuresAndMalformedOversizedResponsesAreExplicit() async throws {
        for (status, expected) in [(404, AgentWeatherError.unavailable), (429, .rateLimited), (503, .unavailable), (302, .unavailable)] {
            let transport = WeatherFixtureTransport(responses: [Data("upstream text must not be returned".utf8)], status: status)
            do { _ = try await NWSWeatherClient(transport: transport).forecast(request, privacy: privacy); XCTFail() }
            catch { XCTAssertEqual(error as? AgentWeatherError, expected) }
        }
        for data in [Data("not JSON".utf8), Data(repeating: 32, count: NWSWeatherClient.maximumResponseBytes + 1)] {
            let transport = WeatherFixtureTransport(responses: [data])
            do { _ = try await NWSWeatherClient(transport: transport).forecast(request, privacy: privacy); XCTFail() }
            catch { XCTAssertEqual(error as? AgentWeatherError, .invalidResponse) }
        }
        let wrongHost = WeatherFixtureTransport(responses: try responses(), responseURL: URL(string: "https://example.com")!)
        do { _ = try await NWSWeatherClient(transport: wrongHost).forecast(request, privacy: privacy); XCTFail() }
        catch { XCTAssertEqual(error as? AgentWeatherError, .invalidResponse) }
    }

    func testOldFutureWrongUnitsAndUnboundedTextAreRejected() async throws {
        let date = date
        for (payloads, expected) in [(try responses(age: 172_800), AgentWeatherError.staleForecast),
                                    (try responses(age: -600), .staleForecast),
                                    (try responses(temperatureUnit: "F"), .invalidResponse),
                                    (try responses(conditions: String(repeating: "x", count: 241)), .invalidResponse)] {
            let client = NWSWeatherClient(transport: WeatherFixtureTransport(responses: payloads), now: { date })
            do { _ = try await client.forecast(request, privacy: privacy); XCTFail() }
            catch { XCTAssertEqual(error as? AgentWeatherError, expected) }
        }
    }

    func testCancellationDropsLateTransportDataAndReleasesInFlightSlot() async throws {
        let transport = SuspendedWeatherTransport()
        let client = NWSWeatherClient(transport: transport)
        let request = request, privacy = privacy
        let task = Task { try await client.forecast(request, privacy: privacy) }
        await transport.waitForRequest()
        do { _ = try await client.forecast(request, privacy: privacy); XCTFail("Parallel lookup must be bounded") }
        catch { XCTAssertEqual(error as? AgentWeatherError, .busy) }
        task.cancel()
        await transport.finish(data: try responses()[0])
        do { _ = try await task.value; XCTFail("Cancelled lookup must not publish") }
        catch { XCTAssertTrue(error is CancellationError) }
        let cancelled = Task { try await client.forecast(request, privacy: privacy) }
        await transport.waitForRequest()
        cancelled.cancel()
        await transport.finish(data: Data())
        _ = await cancelled.result
        let count = await transport.count
        XCTAssertEqual(count, 2, "No forecast follow-up after cancellation; next lookup can acquire the slot")
    }
}

private final class WeatherFixtureClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    init(_ date: Date) { self.date = date }
    var value: Date { lock.lock(); defer { lock.unlock() }; return date }
    func advance(_ interval: TimeInterval) { lock.lock(); defer { lock.unlock() }; date.addTimeInterval(interval) }
}

private actor WeatherFixtureTransport: HTTPTransport {
    var requests: [URLRequest] = []
    private var responses: [Data]
    private let status: Int
    private let responseURL: URL?
    init(responses: [Data], status: Int = 200, responseURL: URL? = nil) {
        self.responses = responses; self.status = status; self.responseURL = responseURL
    }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !responses.isEmpty else { throw AgentWeatherError.unavailable }
        return (responses.removeFirst(), HTTPURLResponse(url: responseURL ?? request.url!, statusCode: status,
                    httpVersion: nil, headerFields: ["Content-Type": "application/geo+json"])!)
    }
}

private actor SuspendedWeatherTransport: HTTPTransport {
    private var pending: CheckedContinuation<(Data, HTTPURLResponse), Error>?
    private var request: URLRequest?
    private var waiting: CheckedContinuation<Void, Never>?
    private(set) var count = 0
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        count += 1; self.request = request
        return try await withCheckedThrowingContinuation { continuation in
            pending = continuation; waiting?.resume(); waiting = nil
        }
    }
    func waitForRequest() async {
        if pending != nil { return }
        await withCheckedContinuation { waiting = $0 }
    }
    func finish(data: Data) {
        let continuation = pending; pending = nil
        continuation?.resume(returning: (data, HTTPURLResponse(url: request!.url!, statusCode: 200,
                                httpVersion: nil, headerFields: ["Content-Type": "application/geo+json"])!))
    }
}
