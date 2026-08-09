import Foundation
import Security

enum AICameraAudioDevice {
    static let uid = "ai.kortexa.aicamera.audio.device"
    static let driverBundleIdentifier = "ai.kortexa.aicamera.audio.driver"
}

enum AudioDriverStatus: Equatable {
    case checking
    case notInstalled
    case installed
    case installedNeedsReload
    case installing
    case uninstalling
    case foreignInstallation
    case untrustedInstallation
    case failed(String)

    var isBusy: Bool {
        self == .installing || self == .uninstalling || self == .checking
    }

    var isInstalled: Bool {
        switch self {
        case .installed, .installedNeedsReload: return true
        default: return false
        }
    }

    var label: String {
        switch self {
        case .checking: return "Checking…"
        case .notInstalled: return "Not installed"
        case .installed: return "Ready"
        case .installedNeedsReload: return "Installed; Core Audio reload pending"
        case .installing: return "Installing…"
        case .uninstalling: return "Uninstalling…"
        case .foreignInstallation: return "Unrecognized bundle at install path"
        case .untrustedInstallation: return "Driver signature is invalid"
        case let .failed(message): return "Failed: \(message)"
        }
    }
}

@MainActor
final class AudioDriverManager: ObservableObject {
    static let installURL = URL(fileURLWithPath: "/Library/Audio/Plug-Ins/HAL/AICameraAudioDriver.driver")
    @Published private(set) var status: AudioDriverStatus = .checking

    init() { refresh() }

    func refresh() {
        guard status != .installing, status != .uninstalling else { return }
        guard FileManager.default.fileExists(atPath: Self.installURL.path) else {
            status = .notInstalled
            return
        }
        guard Self.bundleIdentifier(at: Self.installURL) == AICameraAudioDevice.driverBundleIdentifier else {
            status = .foreignInstallation
            return
        }
        guard Self.hasValidSignature(at: Self.installURL) else {
            status = .untrustedInstallation
            return
        }
        status = DeviceDiscovery.audioDeviceID(forUID: AICameraAudioDevice.uid) == nil
            ? .installedNeedsReload
            : .installed
    }

    func install() {
        guard !status.isBusy else { return }
        guard let sourceURL = Bundle.main.url(forResource: "AICameraAudioDriver", withExtension: "driver") else {
            status = .failed("The audio driver is missing from this app bundle")
            return
        }
        guard Self.bundleIdentifier(at: sourceURL) == AICameraAudioDevice.driverBundleIdentifier else {
            status = .failed("The bundled audio driver has an unexpected identity")
            return
        }
        guard Self.hasValidSignature(at: sourceURL) else {
            status = .failed("Use a signed build before installing its audio driver")
            return
        }
        if FileManager.default.fileExists(atPath: Self.installURL.path) {
            guard Self.bundleIdentifier(at: Self.installURL) == AICameraAudioDevice.driverBundleIdentifier else {
                status = .foreignInstallation
                return
            }
            guard Self.hasValidSignature(at: Self.installURL) else {
                status = .untrustedInstallation
                return
            }
        }

        status = .installing
        let script = #"""
        on run argv
            set sourcePath to item 1 of argv
            set destinationPath to item 2 of argv
            set expectedID to item 3 of argv
            set commandText to "set -eu; src=" & quoted form of sourcePath & "; dst=" & quoted form of destinationPath & "; expected=" & quoted form of expectedID & "; tmp=\"${dst}.installing\"; bak=\"${dst}.backup\"; test -n \"$dst\"; test \"$dst\" != /; actual=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \"$src/Contents/Info.plist\"); test \"$actual\" = \"$expected\"; if test -e \"$dst\"; then installed=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \"$dst/Contents/Info.plist\"); test \"$installed\" = \"$expected\"; fi; /bin/rm -rf \"$tmp\" \"$bak\"; /usr/bin/ditto \"$src\" \"$tmp\"; /usr/sbin/chown -R root:wheel \"$tmp\"; /bin/chmod -R go-w \"$tmp\"; had=0; if test -e \"$dst\"; then /bin/mv \"$dst\" \"$bak\"; had=1; fi; if /bin/mv \"$tmp\" \"$dst\"; then /bin/rm -rf \"$bak\"; else if test \"$had\" = 1; then /bin/mv \"$bak\" \"$dst\"; fi; exit 1; fi; { /usr/bin/killall -TERM coreaudiod || true; }"
            do shell script commandText with administrator privileges
        end run
        """#
        runAppleScript(script, arguments: [
            sourceURL.path,
            Self.installURL.path,
            AICameraAudioDevice.driverBundleIdentifier,
        ])
    }

    func uninstall() {
        guard !status.isBusy else { return }
        guard FileManager.default.fileExists(atPath: Self.installURL.path) else {
            status = .notInstalled
            return
        }
        guard Self.bundleIdentifier(at: Self.installURL) == AICameraAudioDevice.driverBundleIdentifier else {
            status = .foreignInstallation
            return
        }
        guard Self.hasValidSignature(at: Self.installURL) else {
            status = .untrustedInstallation
            return
        }

        status = .uninstalling
        let script = #"""
        on run argv
            set destinationPath to item 1 of argv
            set expectedID to item 2 of argv
            set commandText to "set -eu; dst=" & quoted form of destinationPath & "; expected=" & quoted form of expectedID & "; test -n \"$dst\"; test \"$dst\" != /; if test -e \"$dst\"; then actual=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \"$dst/Contents/Info.plist\"); test \"$actual\" = \"$expected\"; /bin/rm -rf \"$dst\"; fi; { /usr/bin/killall -TERM coreaudiod || true; }"
            do shell script commandText with administrator privileges
        end run
        """#
        runAppleScript(script, arguments: [
            Self.installURL.path,
            AICameraAudioDevice.driverBundleIdentifier,
        ])
    }

    private func runAppleScript(_ source: String, arguments: [String]) {
        Task { [weak self] in
            let failure = await Task.detached(priority: .userInitiated) {
                Self.executeAppleScript(source, arguments: arguments)
            }.value
            guard let self else { return }
            if let failure {
                self.status = .failed(failure)
            } else {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                self.status = .checking
                self.refresh()
            }
        }
    }

    nonisolated private static func executeAppleScript(_ source: String, arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source] + arguments
        let errorPipe = Pipe()
        process.standardError = errorPipe
        do {
            try process.run()
            process.waitUntilExit()
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorText = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard process.terminationStatus != 0 else { return nil }
            return errorText.isEmpty ? "Authorization was cancelled" : errorText
        } catch {
            return error.localizedDescription
        }
    }

    nonisolated private static func hasValidSignature(at url: URL) -> Bool {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode else { return false }
        let flags = SecCSFlags(
            rawValue: UInt32(kSecCSCheckAllArchitectures | kSecCSStrictValidate)
        )
        return SecStaticCodeCheckValidity(staticCode, flags, nil) == errSecSuccess
    }

    nonisolated private static func bundleIdentifier(at url: URL) -> String? {
        let infoURL = url.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: infoURL),
              let value = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dictionary = value as? [String: Any] else { return nil }
        return dictionary["CFBundleIdentifier"] as? String
    }
}
