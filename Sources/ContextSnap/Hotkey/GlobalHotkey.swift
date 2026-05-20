import AppKit
import Carbon.HIToolbox

/// Thin wrapper around Carbon's RegisterEventHotKey for app-wide hotkeys.
/// One instance == one key combo == one callback.
final class GlobalHotkey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let id: UInt32
    private let action: () -> Void

    private static var nextID: UInt32 = 1
    private static var registry: [UInt32: () -> Void] = [:]

    init?(keyCode: UInt32, modifiers: NSEvent.ModifierFlags, action: @escaping () -> Void) {
        self.action = action
        self.id = Self.nextID
        Self.nextID += 1

        var carbonMods: UInt32 = 0
        if modifiers.contains(.command) { carbonMods |= UInt32(cmdKey) }
        if modifiers.contains(.option)  { carbonMods |= UInt32(optionKey) }
        if modifiers.contains(.control) { carbonMods |= UInt32(controlKey) }
        if modifiers.contains(.shift)   { carbonMods |= UInt32(shiftKey) }

        let signature: OSType = 0x43545853 // 'CTXS'
        let hotKeyID = EventHotKeyID(signature: signature, id: id)
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))

        let installStatus = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            guard let event = event else { return noErr }
            var hkID = EventHotKeyID()
            GetEventParameter(event,
                              EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID),
                              nil,
                              MemoryLayout<EventHotKeyID>.size,
                              nil,
                              &hkID)
            if let fire = GlobalHotkey.registry[hkID.id] {
                DispatchQueue.main.async { fire() }
            }
            return noErr
        }, 1, &eventType, nil, &handlerRef)

        guard installStatus == noErr else { return nil }

        let regStatus = RegisterEventHotKey(keyCode,
                                            carbonMods,
                                            hotKeyID,
                                            GetApplicationEventTarget(),
                                            0,
                                            &hotKeyRef)
        guard regStatus == noErr else { return nil }

        Self.registry[id] = action
    }

    deinit {
        if let h = hotKeyRef { UnregisterEventHotKey(h) }
        if let h = handlerRef { RemoveEventHandler(h) }
        Self.registry.removeValue(forKey: id)
    }
}
