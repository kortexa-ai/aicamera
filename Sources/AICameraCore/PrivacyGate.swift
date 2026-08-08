import Foundation

public enum PrivacyGateError: LocalizedError, Equatable {
    case remoteHostNotAllowed(String)
    case dataClassNotGranted(endpointID: String, dataClass: MediaDataClass)

    public var errorDescription: String? {
        switch self {
        case let .remoteHostNotAllowed(host):
            return "Network egress to '\(host)' is not allowed by this profile."
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
        let isLoopback = EndpointLocation.isLoopback(endpoint.baseURL)
        if !isLoopback {
            let host = endpoint.baseURL.host?.lowercased() ?? "<unknown>"
            guard configuration.networkMode == .allowListed,
                  configuration.allowedHosts.map({ $0.lowercased() }).contains(host) else {
                throw PrivacyGateError.remoteHostNotAllowed(host)
            }
        }

        // Loopback data never leaves this host. Remote egress always needs an exact grant,
        // even when the same profile also contains trusted local stages.
        if isLoopback { return }
        let allowed = configuration.grants.first(where: { $0.endpointID == endpoint.id })?.allowedData ?? []
        for dataClass in data where !allowed.contains(dataClass) {
            throw PrivacyGateError.dataClassNotGranted(endpointID: endpoint.id, dataClass: dataClass)
        }
    }
}
