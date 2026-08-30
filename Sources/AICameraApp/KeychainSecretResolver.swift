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
        let visibleCount: Int
        if let dash = characters.lastIndex(of: "-") {
            visibleCount = min(characters.count, dash + 1 + 4)
        } else {
            visibleCount = min(characters.count, 6)
        }
        guard visibleCount < characters.count else { return secret }
        return String(characters.prefix(visibleCount))
            + String(repeating: "*", count: characters.count - visibleCount)
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
