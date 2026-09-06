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
        guard shortcuts.register() == nil else { throw Failure("Hotkeys unavailable for synthetic validation") }
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
        try send(99)
        try send(1, signature: 0)
        guard actions == [.agent, .agent, .mute] else { throw Failure("Wrong action or repeated hotkey delivery") }
        shortcuts.unregister()
        try send(2)
        guard actions.count == 3 else { throw Failure("Unregistered handler remained active") }
        guard shortcuts.register() == nil else { throw Failure("Hotkeys were not released") }
        try send(2)
        try send(2, released: true)
        guard actions.count == 4 else { throw Failure("Re-registration did not deliver") }
        print("Global shortcuts passed: registration, action routing, held-key suppression, unknown IDs, unregister/re-register; no keyboard input observed")
    }
    struct Failure: Error { let message: String; init(_ message: String) { self.message = message } }
}
