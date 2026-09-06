import Carbon
import Foundation

/// Registers explicit hotkeys without observing general keyboard input or requiring
/// Accessibility/Input Monitoring permission. All registration and delivery happens on main.
final class GlobalShortcuts {
    enum Action: UInt32, CaseIterable {
        case agent = 1, mute = 2, agentInput = 3
        var key: Int { switch self { case .agent: return kVK_ANSI_A; case .mute: return kVK_ANSI_M; case .agentInput: return kVK_Space } }
        var label: String { switch self { case .agent: return "⌃⌥A"; case .mute: return "⌃⌥M"; case .agentInput: return "⌃⌥Space" } }
    }
    private static let signature: OSType = 0x41494341 // AICA
    private var handler: EventHandlerRef?
    private var references: [EventHotKeyRef] = []
    private var pressed = Set<Action>()
    private let onAction: @MainActor (Action) -> Void

    init(onAction: @escaping @MainActor (Action) -> Void) { self.onAction = onAction }

    @MainActor
    func register() -> String? {
        unregister()
        var kinds = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                    EventParamType(typeEventHotKeyID), nil,
                                    MemoryLayout<EventHotKeyID>.size, nil, &identifier) == noErr,
                  identifier.signature == GlobalShortcuts.signature,
                  let action = Action(rawValue: identifier.id) else { return OSStatus(eventNotHandledErr) }
            let shortcuts = Unmanaged<GlobalShortcuts>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated {
                if GetEventKind(event) == UInt32(kEventHotKeyReleased) {
                    shortcuts.pressed.remove(action)
                } else if shortcuts.pressed.insert(action).inserted {
                    shortcuts.onAction(action)
                }
            }
            return noErr
        }, kinds.count, &kinds, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard installed == noErr else { return "Global shortcuts are unavailable (\(installed)). Use the toolbar." }
        var unavailable: [String] = []
        for action in Action.allCases {
            var reference: EventHotKeyRef?
            let status = RegisterEventHotKey(UInt32(action.key), UInt32(controlKey | optionKey),
                                            EventHotKeyID(signature: Self.signature, id: action.rawValue),
                                            GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &reference)
            if status == noErr, let reference { references.append(reference) }
            else { unavailable.append(action.label) }
        }
        return unavailable.isEmpty ? nil
            : "\(unavailable.joined(separator: ", ")) could not be registered. Check other apps’ shortcuts; use the toolbar meanwhile."
    }

    @MainActor
    func unregister() {
        references.forEach { UnregisterEventHotKey($0) }
        references.removeAll()
        pressed.removeAll()
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }
}
