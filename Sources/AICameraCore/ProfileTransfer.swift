import Foundation

/// Bounded, validated serialization for profiles copied between installations.
///
/// Profiles contain credential references only. Secret values remain in their original
/// environment or Keychain and are never consulted by this codec.
public enum ProfileTransfer {
    public static let maximumBytes = ConfigurationStore.maximumProfileBytes

    public static func encode(_ configuration: AICameraConfiguration) throws -> Data {
        try ConfigurationValidator.validate(configuration)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(configuration)
        guard data.count <= maximumBytes else {
            throw ConfigurationError.profileTooLarge
        }
        return data
    }

    public static func decode(_ data: Data) throws -> AICameraConfiguration {
        guard data.count <= maximumBytes else {
            throw ConfigurationError.profileTooLarge
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let configuration = try decoder.decode(AICameraConfiguration.self, from: data)
        try ConfigurationValidator.validate(configuration)
        return configuration
    }

    public static func read(from url: URL) throws -> AICameraConfiguration {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        if let size = attributes[.size] as? NSNumber, size.intValue > maximumBytes {
            throw ConfigurationError.profileTooLarge
        }
        return try decode(Data(contentsOf: url))
    }

    public static func write(_ configuration: AICameraConfiguration, to url: URL) throws {
        let data = try encode(configuration)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: url.path
        )
    }
}
