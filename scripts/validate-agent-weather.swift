import AICameraCore
import AppKit

/// Default mode uses synthetic public-data responses. --live checks only Seattle city-center
/// forecast HTTP, with no account, location access, camera, microphone, or audio playback.
@main
struct WeatherValidation {
    @MainActor static func main() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count == 2, ["--fixture", "--live"].contains(args[0]) else {
            throw Failure(description: "Usage: validate-agent-weather --fixture|--live output-directory")
        }
        let live = args[0] == "--live"
        let output = URL(fileURLWithPath: args[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var profile = AICameraConfiguration.default
        profile.overlays.script.enabled = true
        AgentWeatherPolicy.setEnabled(true, in: &profile)
        let fixed = Date(timeIntervalSince1970: 1_788_691_200)
        let client = live ? NWSWeatherClient() : NWSWeatherClient(transport: Fixture(now: fixed), now: { fixed })
        let request = AgentWeatherRequest(latitude: 47.6062, longitude: -122.3321, units: .fahrenheit)!
        var turn = AgentToolTurn()
        guard turn.admit(callID: "forecast") else { throw Failure(description: "Tool admission failed") }
        turn.endedResponse()
        let result = try await client.forecast(request, privacy: profile.privacy)
        guard result.nearCity == "Seattle", result.state == "WA", result.periods.count > 0,
              result.periods[0].temperatureUnit == "F",
              let card = result.cardRequest, AgentPresentationState.valid(card) else {
            throw Failure(description: "Forecast did not preserve location, units, or a bounded card")
        }
        turn.completed(callID: "forecast")
        guard turn.takeNext() == .continueResponse(allowTools: true), turn.admit(callID: "card") else {
            throw Failure(description: "Lookup did not permit its display continuation")
        }
        let state = AgentPresentationState()
        let value = state.show(card)!
        for (width, height) in [(1280, 720), (640, 480)] {
            let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(NSColor(calibratedRed: 0.11, green: 0.14, blue: 0.2, alpha: 1).cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.translateBy(x: 0, y: CGFloat(height)); context.scaleBy(x: 1, y: -1)
            AgentCardRenderer().draw(value, width: CGFloat(width), height: CGFloat(height), context: context)
            guard let image = context.makeImage(), let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                throw Failure(description: "Native weather card rendering failed")
            }
            try png.write(to: output.appendingPathComponent("\(live ? "live" : "synthetic")-weather-\(width).png"))
        }
        turn.completed(callID: "card"); turn.endedResponse()
        guard turn.takeNext() == .continueResponse(allowTools: true) else { throw Failure(description: "Missing final response continuation") }
        let encoderData = try JSONSerialization.data(withJSONObject: result.toolResult, options: [.prettyPrinted, .sortedKeys])
        try encoderData.write(to: output.appendingPathComponent("\(live ? "live" : "synthetic")-forecast.json"))
        print("\(live ? "Public NWS HTTP" : "Synthetic NWS") lookup → bounded card → response continuation passed at 1280×720 and 640×480. No media capture or model request.")
    }
    struct Failure: Error, CustomStringConvertible { let description: String }
}

private actor Fixture: HTTPTransport {
    let now: Date
    init(now: Date) { self.now = now }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let value: [String: Any]
        if request.url!.path.hasPrefix("/points/") {
            value = ["properties": ["forecast": "https://api.weather.gov/gridpoints/SEW/125,68/forecast",
                                    "relativeLocation": ["properties": ["city": "Seattle", "state": "WA"]]]]
        } else {
            let date = ISO8601DateFormatter()
            value = ["properties": ["updateTime": date.string(from: now.addingTimeInterval(-600)), "periods": [
                ["name": "This Afternoon", "startTime": date.string(from: now.addingTimeInterval(-3600)),
                 "endTime": date.string(from: now.addingTimeInterval(3600)), "temperature": 74, "temperatureUnit": "F",
                 "shortForecast": "Mostly Sunny", "windSpeed": "5 mph", "windDirection": "NW",
                 "probabilityOfPrecipitation": ["unitCode": "wmoUnit:percent", "value": 5]]]]]
        }
        return (try JSONSerialization.data(withJSONObject: value), HTTPURLResponse(url: request.url!, statusCode: 200,
                           httpVersion: nil, headerFields: ["Content-Type": "application/geo+json"])!)
    }
}
