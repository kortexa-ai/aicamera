import Foundation
import Security

/// Verifies the process behind a sink client when CoreMediaIO cannot provide a useful signing ID.
///
/// CoreMediaIO can report an unsandboxed client's signing ID as `"unknown"` even when the
/// executable has a valid Developer signature. Resolve the client PID synchronously and require a
/// valid Apple-issued signature whose bundle identifier matches the companion host and whose
/// certificate team matches this extension. Any failure is rejected.
enum CompanionHostAuthorizer {
    struct Decision {
        let isAuthorized: Bool
        let reason: String
    }

    static func evaluate(pid: pid_t) -> Decision {
        guard pid > 0 else {
            return Decision(isAuthorized: false, reason: "missing client process identifier")
        }
        guard let extensionCompanionRequirement else {
            return Decision(isAuthorized: false, reason: "extension companion requirement is unavailable")
        }
        guard let clientCode = processCode(pid: pid) else {
            return Decision(isAuthorized: false, reason: "client code identity is unavailable")
        }
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate)
        guard SecCodeCheckValidity(clientCode, flags, extensionCompanionRequirement) == errSecSuccess else {
            return Decision(isAuthorized: false, reason: "client code signature or identity does not match")
        }
        return Decision(isAuthorized: true, reason: "validated companion code identity")
    }

    /// A CMIO client is bound by `clientID` after this check. PID lookup is deliberately repeated
    /// for every new client rather than cached by PID, which limits PID-reuse exposure to the
    /// synchronous authorization callback.
    private static func processCode(pid: pid_t) -> SecCode? {
        let attributes = [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, SecCSFlags(), &code) == errSecSuccess else {
            return nil
        }
        return code
    }

    private static let extensionCompanionRequirement: SecRequirement? = {
        let bundleIdentifier = AICameraVirtualCamera.hostBundleIdentifier
        guard isSafeRequirementIdentifier(bundleIdentifier),
              let extensionTeamIdentifier,
              isSafeRequirementIdentifier(extensionTeamIdentifier) else { return nil }
        let source = #"identifier "\#(bundleIdentifier)" and anchor apple generic and certificate leaf[subject.OU] = "\#(extensionTeamIdentifier)""#
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(
            source as CFString,
            SecCSFlags(),
            &requirement
        ) == errSecSuccess else { return nil }
        return requirement
    }()

    private static let extensionTeamIdentifier: String? = {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess,
              let code,
              SecCodeCheckValidity(
                  code,
                  SecCSFlags(rawValue: kSecCSStrictValidate),
                  nil
              ) == errSecSuccess else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        ) == errSecSuccess,
              let values = information as? [String: Any],
              let teamIdentifier = values[kSecCodeInfoTeamIdentifier as String] as? String,
              !teamIdentifier.isEmpty else { return nil }
        return teamIdentifier
    }()

    private static func isSafeRequirementIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-"
        }
    }
}
