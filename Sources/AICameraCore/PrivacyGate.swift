import Foundation

public enum PrivacyGateError: LocalizedError, Equatable {
    case remoteHostNotAllowed(String)
    case dataClassNotGranted(endpointID: String, dataClass: MediaDataClass)

    public var errorDescription: String? {
        switch self {
        case let .remoteHostNotAllowed(host):
            return "Network egress to '\(host)' is not allowed by these settings."
        case let .dataClassNotGranted(endpointID, dataClass):
            return "Endpoint '\(endpointID)' is not allowed to receive \(dataClass.rawValue)."
        }
    }
}

public struct PrivacyGate: Sendable {
    public var configuration: PrivacyConfiguration

    public init(configuration: PrivacyConfiguration) {
        self.configuration = configuration
    }

    public func authorize(endpoint: EndpointConfiguration, data: Set<MediaDataClass>) throws {
        try authorize(endpointID: endpoint.id, baseURL: endpoint.baseURL, data: data)
    }

    /// Built-in data services have a fixed identity/URL and need no model adapter or credential.
    public func authorize(endpointID: String, baseURL: URL, data: Set<MediaDataClass>) throws {
        let isLoopback = EndpointLocation.isLoopback(baseURL)
        if !isLoopback {
            let host = baseURL.host?.lowercased() ?? "<unknown>"
            guard configuration.networkMode == .allowListed,
                  configuration.allowedHosts.map({ $0.lowercased() }).contains(host) else {
                throw PrivacyGateError.remoteHostNotAllowed(host)
            }
        }

        // Loopback data never leaves this host. Remote egress always needs an exact grant,
        // even when the same profile also contains trusted local stages.
        if isLoopback { return }
        let allowed = configuration.grants.first(where: { $0.endpointID == endpointID })?.allowedData ?? []
        for dataClass in data where !allowed.contains(dataClass) {
                throw PrivacyGateError.dataClassNotGranted(endpointID: endpointID, dataClass: dataClass)
        }
    }
}
