import AppKit
import Carbon.HIToolbox
import Combine
import ServiceManagement

final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    private enum Key {
        static let keyCode = "hotkey.keyCode"
        static let modifiers = "hotkey.modifiers"
        static let saveDirectory = "saveDirectory"
        static let showStack = "showStack"
    }

    @Published var hotkeyKeyCode: UInt32 {
        didSet { UserDefaults.standard.set(Int(hotkeyKeyCode), forKey: Key.keyCode) }
    }
    @Published var hotkeyModifiers: NSEvent.ModifierFlags {
        didSet { UserDefaults.standard.set(Int(hotkeyModifiers.rawValue), forKey: Key.modifiers) }
    }
    @Published var saveDirectory: URL {
        didSet { UserDefaults.standard.set(saveDirectory.path, forKey: Key.saveDirectory) }
    }
    @Published var showStack: Bool {
        didSet { UserDefaults.standard.set(showStack, forKey: Key.showStack) }
    }
    @Published private(set) var launchAtLogin: Bool
    @Published var launchAtLoginError: String?

    var canManageLaunchAtLogin: Bool {
        if #available(macOS 13.0, *) { return true }
        return false
    }

    private init() {
        let d = UserDefaults.standard
        let kc = d.object(forKey: Key.keyCode) as? Int ?? kVK_ANSI_S
        self.hotkeyKeyCode = UInt32(kc)
        let defaultMods = NSEvent.ModifierFlags([.command, .shift]).rawValue
        let mods = d.object(forKey: Key.modifiers) as? Int ?? Int(defaultMods)
        self.hotkeyModifiers = NSEvent.ModifierFlags(rawValue: UInt(mods))
        if let path = d.string(forKey: Key.saveDirectory), !path.isEmpty {
            self.saveDirectory = URL(fileURLWithPath: path)
        } else {
            let base = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
            self.saveDirectory = base.appendingPathComponent("ContextSnap")
        }
        self.showStack = d.object(forKey: Key.showStack) as? Bool ?? true
        if #available(macOS 13.0, *) {
            self.launchAtLogin = SMAppService.mainApp.status == .enabled
        } else {
            self.launchAtLogin = false
        }
    }

    func refreshLaunchAtLogin() {
        guard #available(macOS 13.0, *) else {
            launchAtLogin = false
            return
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        guard #available(macOS 13.0, *) else {
            launchAtLogin = false
            launchAtLoginError = "Launch at login requires macOS 13 or later."
            return
        }

        launchAtLoginError = nil
        let previous = launchAtLogin
        launchAtLogin = enabled

        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            refreshLaunchAtLogin()
        } catch {
            launchAtLogin = previous
            launchAtLoginError = error.localizedDescription
        }
    }
}

enum HotkeyFormat {
    static func label(modifiers: NSEvent.ModifierFlags, keyCode: UInt32) -> String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option)  { s += "⌥" }
        if modifiers.contains(.shift)   { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        s += keyName(keyCode)
        return s
    }

    private static func keyName(_ keyCode: UInt32) -> String {
        let map: [Int: String] = [
            kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D",
            kVK_ANSI_E: "E", kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H",
            kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
            kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P",
            kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
            kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
            kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
            kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
            kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7",
            kVK_ANSI_8: "8", kVK_ANSI_9: "9",
            kVK_Space: "Space", kVK_Return: "Return", kVK_Escape: "Esc",
            kVK_Tab: "Tab", kVK_Delete: "Delete",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4",
            kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8",
            kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        ]
        return map[Int(keyCode)] ?? "Key\(keyCode)"
    }
}
