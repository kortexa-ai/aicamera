import Darwin
import Foundation
import Security

/// Verifies the live process behind a sink client when CoreMediaIO cannot provide a useful signing ID.
///
/// Security's live-code lookup is authoritative when it is available. CMIO extensions run in a
/// dedicated service session where that lookup can fail for a GUI process. In that case, query the
/// kernel's live code-signing state and bind every query to a PID version that changes on exec.
/// The returned binding is rechecked before each accepted feeder frame. No result is cached by PID.
enum CompanionHostAuthorizer {
    struct ProcessBinding: Equatable {
        fileprivate let pid: pid_t
        fileprivate let executablePath: String
        fileprivate let startedAtSeconds: Int
        fileprivate let startedAtMicroseconds: Int32
        fileprivate let uniqueIdentifier: UInt64
        fileprivate let pidVersion: Int32
        fileprivate let executableUUID: [UInt8]
    }

    struct Decision {
        let isAuthorized: Bool
        let reason: String
        let binding: ProcessBinding?

        init(isAuthorized: Bool, reason: String, binding: ProcessBinding? = nil) {
            self.isAuthorized = isAuthorized
            self.reason = reason
            self.binding = binding
        }
    }

    static func evaluate(pid: pid_t) -> Decision {
        guard pid > 0 else {
            return Decision(isAuthorized: false, reason: "missing client process identifier")
        }
        guard let requirement = companionRequirement(),
              let expectedTeamIdentifier = extensionTeamIdentifier else {
            return Decision(isAuthorized: false, reason: "companion requirement is unavailable")
        }

        let attributes = [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary
        var clientCode: SecCode?
        let lookupStatus = SecCodeCopyGuestWithAttributes(
            nil,
            attributes,
            SecCSFlags(),
            &clientCode
        )
        let liveCodeWasValidated: Bool
        if lookupStatus == errSecSuccess, let clientCode {
            guard SecCodeCheckValidity(
                clientCode,
                SecCSFlags(rawValue: kSecCSStrictValidate),
                requirement
            ) == errSecSuccess else {
                return Decision(isAuthorized: false, reason: "client code signature or identity does not match")
            }
            liveCodeWasValidated = true
        } else {
            liveCodeWasValidated = false
        }

        guard let first = kernelSnapshot(pid: pid),
              kernelSnapshotIsAuthorized(
                  first,
                  expectedTeamIdentifier: expectedTeamIdentifier
              ),
              let second = kernelSnapshot(pid: pid),
              first == second else {
            return Decision(
                isAuthorized: false,
                reason: "live lookup \(lookupStatus); kernel code identity did not match"
            )
        }
        let binding = processBinding(pid: pid, process: second.process)
        return Decision(
            isAuthorized: true,
            reason: liveCodeWasValidated
                ? "validated live and kernel companion code identity"
                : "validated kernel code identity after live lookup \(lookupStatus)",
            binding: binding
        )
    }

    static func bindingIsCurrent(_ binding: ProcessBinding) -> Bool {
        guard let current = uniqueProcessIdentity(pid: binding.pid) else { return false }
        return current.uniqueIdentifier == binding.uniqueIdentifier
            && current.pidVersion == binding.pidVersion
            && current.executableUUID == binding.executableUUID
    }

    private struct ProcessIdentity: Equatable {
        let executablePath: String
        let startedAtSeconds: Int
        let startedAtMicroseconds: Int32
        let uniqueIdentifier: UInt64
        let pidVersion: Int32
        let executableUUID: [UInt8]
    }

    private struct UniqueProcessIdentity: Equatable {
        let uniqueIdentifier: UInt64
        let pidVersion: Int32
        let executableUUID: [UInt8]
    }

    private struct KernelSnapshot: Equatable {
        let process: ProcessIdentity
        let codeFlags: UInt32
        let signingIdentifier: String
        let teamIdentifier: String
        let validationCategory: UInt32
    }

    // These csops selectors and flags are XNU ABI values. They query the kernel's live code object
    // rather than attacker-controlled filesystem metadata. The SDK does not expose them, so any ABI
    // or sandbox-policy change fails closed and must be covered by native release acceptance.
    private enum KernelCodeSigning {
        static let statusOperation: UInt32 = 0
        static let identityOperation: UInt32 = 11
        static let teamIdentifierOperation: UInt32 = 14
        static let validationCategoryOperation: UInt32 = 17

        static let valid: UInt32 = 0x0000_0001
        static let adHoc: UInt32 = 0x0000_0002
        static let getTaskAllow: UInt32 = 0x0000_0004
        static let forcedLibraryValidation: UInt32 = 0x0000_0010
        static let invalidPagesAllowed: UInt32 = 0x0000_0020
        static let hard: UInt32 = 0x0000_0100
        static let kill: UInt32 = 0x0000_0200
        static let requireLibraryValidation: UInt32 = 0x0000_2000
        static let hardenedRuntime: UInt32 = 0x0001_0000
        static let debugged: UInt32 = 0x1000_0000
        static let signed: UInt32 = 0x2000_0000

        static let appleDevelopmentCategory: UInt32 = 3
        static let appStoreCategory: UInt32 = 4
        static let developerIDCategory: UInt32 = 6
    }

    private static func kernelSnapshot(pid: pid_t) -> KernelSnapshot? {
        guard let process = processIdentity(pid: pid),
              let codeFlags = kernelUInt32(
                  pid: pid,
                  operation: KernelCodeSigning.statusOperation,
                  process: process
              ),
              let signingIdentifier = kernelString(
                  pid: pid,
                  operation: KernelCodeSigning.identityOperation,
                  process: process
              ),
              let teamIdentifier = kernelString(
                  pid: pid,
                  operation: KernelCodeSigning.teamIdentifierOperation,
                  process: process
              ),
              let validationCategory = kernelUInt32(
                  pid: pid,
                  operation: KernelCodeSigning.validationCategoryOperation,
                  process: process
              ),
              processIdentity(pid: pid) == process else { return nil }
        return KernelSnapshot(
            process: process,
            codeFlags: codeFlags,
            signingIdentifier: signingIdentifier,
            teamIdentifier: teamIdentifier,
            validationCategory: validationCategory
        )
    }

    private static func kernelSnapshotIsAuthorized(
        _ snapshot: KernelSnapshot,
        expectedTeamIdentifier: String
    ) -> Bool {
        let requiredFlags = KernelCodeSigning.valid
            | KernelCodeSigning.hard
            | KernelCodeSigning.kill
            | KernelCodeSigning.hardenedRuntime
            | KernelCodeSigning.signed
        let forbiddenFlags = KernelCodeSigning.adHoc
            | KernelCodeSigning.getTaskAllow
            | KernelCodeSigning.invalidPagesAllowed
            | KernelCodeSigning.debugged
        let allowedCategories: Set<UInt32> = [
            KernelCodeSigning.appleDevelopmentCategory,
            KernelCodeSigning.appStoreCategory,
            KernelCodeSigning.developerIDCategory,
        ]
        return snapshot.process.executablePath == installedHostExecutablePath
            && snapshot.signingIdentifier == AICameraVirtualCamera.hostBundleIdentifier
            && snapshot.teamIdentifier == expectedTeamIdentifier
            && snapshot.codeFlags & requiredFlags == requiredFlags
            && snapshot.codeFlags & forbiddenFlags == 0
            && snapshot.codeFlags
                & (KernelCodeSigning.forcedLibraryValidation
                    | KernelCodeSigning.requireLibraryValidation) != 0
            && allowedCategories.contains(snapshot.validationCategory)
    }

    private static func processIdentity(pid: pid_t) -> ProcessIdentity? {
        guard let firstUniqueIdentity = uniqueProcessIdentity(pid: pid) else { return nil }
        var pathBuffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count)) > 0 else { return nil }
        var selectors: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var information = kinfo_proc()
        var informationSize = MemoryLayout<kinfo_proc>.size
        guard sysctl(
            &selectors,
            UInt32(selectors.count),
            &information,
            &informationSize,
            nil,
            0
        ) == 0,
              informationSize == MemoryLayout<kinfo_proc>.size,
              information.kp_proc.p_pid == pid,
              information.kp_proc.p_starttime.tv_sec >= 0,
              information.kp_proc.p_starttime.tv_usec >= 0,
              let secondUniqueIdentity = uniqueProcessIdentity(pid: pid),
              firstUniqueIdentity == secondUniqueIdentity else { return nil }
        return ProcessIdentity(
            executablePath: String(cString: pathBuffer),
            startedAtSeconds: information.kp_proc.p_starttime.tv_sec,
            startedAtMicroseconds: information.kp_proc.p_starttime.tv_usec,
            uniqueIdentifier: secondUniqueIdentity.uniqueIdentifier,
            pidVersion: secondUniqueIdentity.pidVersion,
            executableUUID: secondUniqueIdentity.executableUUID
        )
    }

    private static func uniqueProcessIdentity(pid: pid_t) -> UniqueProcessIdentity? {
        // PROC_PIDUNIQIDENTIFIERINFO is stable kernel ABI but is not exposed by the macOS SDK.
        let flavor: Int32 = 17
        let expectedSize = 56
        var bytes = [UInt8](repeating: 0, count: expectedSize)
        let copied = bytes.withUnsafeMutableBytes { buffer in
            proc_pidinfo(pid, flavor, 0, buffer.baseAddress, Int32(buffer.count))
        }
        guard copied == expectedSize else { return nil }
        return UniqueProcessIdentity(
            uniqueIdentifier: uint64(bytes, offset: 16),
            pidVersion: int32(bytes, offset: 32),
            executableUUID: Array(bytes[0..<16])
        )
    }

    private static func uint64(_ bytes: [UInt8], offset: Int) -> UInt64 {
        var value: UInt64 = 0
        withUnsafeMutableBytes(of: &value) { destination in
            destination.copyBytes(from: bytes[offset..<(offset + MemoryLayout<UInt64>.size)])
        }
        return value
    }

    private static func int32(_ bytes: [UInt8], offset: Int) -> Int32 {
        var value: Int32 = 0
        withUnsafeMutableBytes(of: &value) { destination in
            destination.copyBytes(from: bytes[offset..<(offset + MemoryLayout<Int32>.size)])
        }
        return value
    }

    private static func processBinding(pid: pid_t, process: ProcessIdentity) -> ProcessBinding {
        ProcessBinding(
            pid: pid,
            executablePath: process.executablePath,
            startedAtSeconds: process.startedAtSeconds,
            startedAtMicroseconds: process.startedAtMicroseconds,
            uniqueIdentifier: process.uniqueIdentifier,
            pidVersion: process.pidVersion,
            executableUUID: process.executableUUID
        )
    }

    private static func kernelUInt32(
        pid: pid_t,
        operation: UInt32,
        process: ProcessIdentity
    ) -> UInt32? {
        var value: UInt32 = 0
        let status = withUnsafeMutableBytes(of: &value) { bytes in
            kernelCodeSigningCall(
                pid: pid,
                operation: operation,
                process: process,
                userAddress: bytes.baseAddress,
                userSize: bytes.count
            )
        }
        return status == 0 ? value : nil
    }

    private static func kernelString(
        pid: pid_t,
        operation: UInt32,
        process: ProcessIdentity
    ) -> String? {
        var buffer = [UInt8](repeating: 0, count: 4_096)
        let status = buffer.withUnsafeMutableBytes { bytes in
            kernelCodeSigningCall(
                pid: pid,
                operation: operation,
                process: process,
                userAddress: bytes.baseAddress,
                userSize: bytes.count
            )
        }
        guard status == 0, buffer.count >= 9 else { return nil }
        let totalLength = Int(buffer[4]) << 24
            | Int(buffer[5]) << 16
            | Int(buffer[6]) << 8
            | Int(buffer[7])
        guard totalLength > 9,
              totalLength <= buffer.count,
              buffer[totalLength - 1] == 0 else { return nil }
        let valueBytes = buffer[8..<(totalLength - 1)]
        guard !valueBytes.contains(0),
              let value = String(bytes: valueBytes, encoding: .utf8),
              !value.isEmpty else { return nil }
        return value
    }

    private static func kernelCodeSigningCall(
        pid: pid_t,
        operation: UInt32,
        process: ProcessIdentity,
        userAddress: UnsafeMutableRawPointer?,
        userSize: Int
    ) -> Int32 {
        var auditToken = [UInt32](repeating: 0, count: 8)
        auditToken[5] = UInt32(bitPattern: pid)
        auditToken[7] = UInt32(bitPattern: process.pidVersion)
        return auditToken.withUnsafeMutableBytes { tokenBytes in
            aicamera_csops_audittoken(
                pid,
                operation,
                userAddress,
                userSize,
                tokenBytes.baseAddress
            )
        }
    }

    private static func companionRequirement() -> SecRequirement? {
        guard let extensionTeamIdentifier else { return nil }
        let source = #"identifier "ai.kortexa.aicamera" and anchor apple generic and certificate leaf[subject.OU] = "\#(extensionTeamIdentifier)" and entitlement["com.apple.security.get-task-allow"] absent"#
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(
            source as CFString,
            SecCSFlags(),
            &requirement
        ) == errSecSuccess else { return nil }
        return requirement
    }

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
              let identifier = values[kSecCodeInfoIdentifier as String] as? String,
              identifier == AICameraVirtualCamera.extensionBundleIdentifier,
              let teamIdentifier = values[kSecCodeInfoTeamIdentifier as String] as? String,
              !teamIdentifier.isEmpty,
              teamIdentifier.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.contains($0) || $0 == "-"
              }) else { return nil }
        return teamIdentifier
    }()

    private static let installedHostExecutablePath =
        "/Applications/AI Camera.app/Contents/MacOS/AI Camera"
}

@_silgen_name("csops_audittoken")
private func aicamera_csops_audittoken(
    _ pid: pid_t,
    _ operation: UInt32,
    _ userAddress: UnsafeMutableRawPointer?,
    _ userSize: Int,
    _ auditToken: UnsafeMutableRawPointer?
) -> Int32
