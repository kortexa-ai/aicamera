import AICameraCore
import Foundation
import Security

struct AppSecretResolver: SecretResolver {
    private let environment = EnvironmentSecretResolver()
    private let keychainService = "ai.kortexa.aicamera"

    func resolve(_ configuration: EndpointAuthConfiguration) async throws -> String? {
        switch configuration.kind {
        case .none, .bearerEnvironment, .apiKeyEnvironment:
            return try await environment.resolve(configuration)
        case .bearerKeychain, .apiKeyKeychain:
            guard let account = configuration.reference, !account.isEmpty else {
                throw SecretResolverError.missingReference(configuration.reference ?? "<unset>")
            }
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: keychainService,
                kSecAttrAccount as String: account,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            guard status == errSecSuccess,
                  let data = result as? Data,
                  let secret = String(data: data, encoding: .utf8),
                  !secret.isEmpty else {
                throw SecretResolverError.missingReference(account)
            }
            return secret
        }
    }

    func store(_ secret: String, account: String) throws {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var item = base
        item[kSecValueData as String] = Data(secret.utf8)
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    func maskedSecret(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let secret = String(data: data, encoding: .utf8),
              !secret.isEmpty else { return nil }
        return Self.mask(secret)
    }

    static func mask(_ secret: String) -> String {
        let characters = Array(secret)
        let recognizedPrefixes = ["sk-svcacct-", "sk-proj-", "sk-"]
        let requestedVisibleCount = recognizedPrefixes
            .first(where: { secret.hasPrefix($0) })
            .map { $0.count + 4 } ?? 6

        // Keep at least four characters hidden even for malformed or unusually
        // short values, and use a fixed mask so the UI does not disclose length.
        let visibleCount = min(requestedVisibleCount, max(0, characters.count - 4))
        return String(characters.prefix(visibleCount)) + "********"
    }

    func remove(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }
}
