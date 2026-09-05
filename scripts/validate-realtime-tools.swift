import AICameraCore
import AppKit
import CoreVideo
import Foundation
import Security
import LocalAuthentication

// Public Realtime + the production overlay renderer, using synthetic instructions only.
// Reads credentials in memory with Keychain UI forbidden. No captured media, playback, or files.
@main
struct RealtimeToolValidation {
    struct Failure: Error, CustomStringConvertible { let description: String }
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            do { try await run(); Darwin.exit(0) }
            catch { fputs("Realtime tool validation failed: \(error)\n", stderr); Darwin.exit(1) }
        }
        app.run()
    }

    @MainActor static func run() async throws {
        guard CommandLine.arguments.count == 3, ["api-key", "codex"].contains(CommandLine.arguments[2]) else {
            throw Failure(description: "Supply Resources/Overlay/overlay.html and api-key or codex")
        }
        let credential = try readCredential(mode: CommandLine.arguments[2])
        var profile = AICameraConfiguration.default
        profile.overlays.script.enabled = true
        let endpoint = EndpointConfiguration(id: "validation", adapter: .openAIRealtime,
            baseURL: URL(string: "https://api.openai.com")!, model: "gpt-realtime", options: ["voice": .string("marin")])
        let session = RealtimeConversationSession(signalingURL: endpoint.baseURL, credential: .init(value: "Bearer " + credential))
        let renderer = OverlayScriptRenderer(scriptConfiguration: profile.overlays.script,
            pageURL: URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL, onLog: { _ in })
        renderer.start()
        defer { renderer.stop() }
        let timeout = Task {
            try? await Task.sleep(nanoseconds: 45_000_000_000)
            if !Task.isCancelled { await session.close() }
        }
        defer { timeout.cancel() }
        do {
            let request = RealtimeSessionConfiguration.request(endpoint: endpoint,
                conversation: profile.pipeline.conversation, profile: profile, toolsAvailable: true)
            try await session.connect(session: request)
            let started = Date()
            try await session.requestContinuation([
                "instructions": "Use render_overlay to draw one solid blue cube at the center. Use THREE.BoxGeometry(1.5,1.5,1.5), THREE.MeshBasicMaterial({color:0x0000ff}), and AICamera.scene.add. Keep the host camera unchanged. Set ttlSeconds to 20. This is a synthetic renderer check.",
                "tool_choice": ["type": "function", "name": "render_overlay"]
            ])
            var rendered = false, cleared = false, continuationDone = false
            var phase = 0, audioBytes = 0, captionCharacters = 0
            for await event in session.events {
                switch event {
                case let .functionCall(call):
                    guard let command = RealtimeOverlayCommand.parse(name: call.name, arguments: call.arguments, configuration: profile.overlays.script) else {
                        throw Failure(description: "Model returned invalid tool arguments")
                    }
                    switch command {
                    case let .render(script, ttl):
                        guard phase == 0, !rendered, renderer.load(script: script, ttlSeconds: ttl) else {
                            throw Failure(description: "Unexpected or rejected render call")
                        }
                        try await waitForPixels(renderer)
                        rendered = true
                        print("Generated overlay reached native pixels in \(Date().timeIntervalSince(started))s")
                    case .clear:
                        guard phase == 2, rendered else { throw Failure(description: "Unexpected Clear call") }
                        renderer.clear()
                        try await Task.sleep(nanoseconds: 250_000_000)
                        guard renderer.latestFreshOverlay() == nil else { throw Failure(description: "Clear retained pixels") }
                        cleared = true
                    }
                    try await session.completeFunctionCall(callID: call.callID, output: "{\"ok\":true}")
                case .responseDone:
                    if phase == 0 {
                        guard rendered else { throw Failure(description: "Missing render call") }
                        phase = 1
                        try await session.requestContinuation(["tool_choice": "none", "instructions": "The overlay tool succeeded. Say only: Blue cube ready."])
                    } else if phase == 1 {
                        guard audioBytes > 0, captionCharacters > 0 else { throw Failure(description: "No continuation audio/caption") }
                        continuationDone = true
                        phase = 2
                        try await session.requestContinuation(["tool_choice": ["type": "function", "name": "clear_overlay"], "instructions": "Clear the generated overlay now using clear_overlay."])
                    } else {
                        guard cleared else { throw Failure(description: "Missing Clear call") }
                        await session.close()
                    }
                case let .audio(chunk):
                    guard chunk.sampleRate == 24_000, chunk.channels == 1, chunk.playbackBuffers != nil else {
                        throw Failure(description: "Invalid continuation PCM")
                    }
                    audioBytes += chunk.data.count
                    guard audioBytes <= 4 * 1_024 * 1_024 else { throw Failure(description: "Excessive synthetic response audio") }
                case let .transcript(_, text, _): captionCharacters += text.count
                case let .error(error): throw error
                default: break
                }
            }
            guard rendered, cleared, continuationDone else { throw Failure(description: "Incomplete tool sequence or timeout") }
            print("Passed \(CommandLine.arguments[2]): render, native pixels, function output, continuation PCM/caption, Clear; audio bytes=\(audioBytes)")
        } catch {
            await session.close()
            throw error
        }
    }

    @MainActor static func waitForPixels(_ renderer: OverlayScriptRenderer) async throws {
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if let buffer = renderer.latestFreshOverlay() {
                CVPixelBufferLockBaseAddress(buffer, .readOnly)
                let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self)
                let index = 180 * CVPixelBufferGetBytesPerRow(buffer) + 320 * 4
                let visible = base.map { $0[index] > 180 && $0[index + 3] > 180 } ?? false
                CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
                if visible { return }
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw Failure(description: "Generated script produced no expected blue center pixels")
    }

    static func readCredential(mode: String) throws -> String {
        // LAContext alone does not suppress legacy login-Keychain ACL prompts on this Mac.
        // This process-local switch also covers those items; it changes no Keychain ACL/settings.
        SecKeychainSetUserInteractionAllowed(false)
        if mode == "api-key", let value = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !value.isEmpty { return value }
        let service: String, account: String
        if mode == "api-key" { service = "ai.kortexa.aicamera"; account = "openai-realtime" }
        else {
            service = "Codex Auth"
            let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/AI Camera/Codex")
            account = CodexAuthPolicy.keychainAccount(canonicalHomePath: home.resolvingSymlinksInPath().path)
        }
        let authentication = LAContext()
        authentication.interactionNotAllowed = true
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: authentication,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            throw Failure(description: "Credential unavailable without interaction (OSStatus \(status)); no login prompt was requested")
        }
        if mode == "codex" {
            let token = try CodexAuthPolicy.accessToken(from: data)
            guard !token.needsRefresh() else { throw Failure(description: "Refresh the separate login in the installed app first") }
            return token.value
        }
        guard let value = String(data: data, encoding: .utf8), !value.isEmpty else { throw Failure(description: "Credential is empty") }
        return value
    }
}
