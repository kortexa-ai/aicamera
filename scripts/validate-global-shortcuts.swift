import AppKit
import Carbon

@main
struct ShortcutValidation {
    @MainActor
    static func main() {
        do { try run() }
        catch {
            FileHandle.standardError.write(Data("Global shortcuts failed: \(error)\n".utf8))
            exit(1)
        }
    }
    @MainActor
    private static func run() throws {
        _ = NSApplication.shared
        var actions: [GlobalShortcuts.Action] = []
        let shortcuts = GlobalShortcuts { actions.append($0) }
        defer { shortcuts.unregister() }
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.isEmpty || arguments == ["--allow-agent-mute-conflicts"] else {
            throw Failure("Usage: validate-global-shortcuts [--allow-agent-mute-conflicts]")
        }
        let allowExistingApp = !arguments.isEmpty
        func register() throws {
            if let message = shortcuts.register() {
                // Older installed releases own A/M but have no agent-input shortcut. Their
                // exclusive registrations remain untouched; Space must succeed in this mode.
                guard allowExistingApp, message.contains("could not be registered"),
                      message.contains(GlobalShortcuts.Action.agent.label) || message.contains(GlobalShortcuts.Action.mute.label),
                      !message.contains(GlobalShortcuts.Action.agentInput.label) else {
                    throw Failure("Hotkeys unavailable for synthetic validation: \(message)")
                }
            }
        }
        try register()
        func send(_ id: UInt32, released: Bool = false, signature: OSType = 0x41494341) throws {
            var event: EventRef?
            guard CreateEvent(nil, OSType(kEventClassKeyboard),
                              UInt32(released ? kEventHotKeyReleased : kEventHotKeyPressed),
                              GetCurrentEventTime(), EventAttributes(kEventAttributeUserEvent), &event) == noErr,
                  let event else { throw Failure("Event construction failed") }
            defer { ReleaseEvent(event) }
            var identifier = EventHotKeyID(signature: signature, id: id)
            guard SetEventParameter(event, EventParamName(kEventParamDirectObject),
                                    EventParamType(typeEventHotKeyID), MemoryLayout<EventHotKeyID>.size, &identifier) == noErr
            else { throw Failure("Event parameter failed") }
            _ = SendEventToEventTarget(event, GetApplicationEventTarget())
        }
        try send(1)
        try send(1) // Holding a key must not repeatedly toggle.
        try send(1, released: true)
        try send(1)
        try send(1, released: true)
        try send(2)
        try send(2, released: true)
        try send(3)
        try send(3)
        try send(3, released: true)
        try send(3)
        try send(3, released: true)
        try send(99)
        try send(1, signature: 0)
        guard actions == [.agent, .agent, .mute, .agentInput, .agentInput] else { throw Failure("Wrong action or repeated hotkey delivery") }
        shortcuts.unregister()
        try send(3)
        guard actions.count == 5 else { throw Failure("Unregistered handler remained active") }
        try register()
        try send(3)
        try send(3, released: true)
        guard actions == [.agent, .agent, .mute, .agentInput, .agentInput, .agentInput] else { throw Failure("Re-registration did not deliver") }
        print("Global shortcuts passed: agent/mute/input action routing, held-key suppression, unknown IDs, unregister/re-register; no keyboard input observed or physical keystrokes sent. \(allowExistingApp ? "A/M conflicts allowed; Space registration required." : "All three shortcut registrations required.")")
    }
    struct Failure: Error { let message: String; init(_ message: String) { self.message = message } }
}
