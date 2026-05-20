import AppKit
import Carbon.HIToolbox
import SwiftUI

@MainActor
final class HotkeyRecorder: ObservableObject {
    @Published var recording = false
    private var monitor: Any?
    private let store: SettingsStore

    init(store: SettingsStore) { self.store = store }

    func toggle() { recording ? stop() : start() }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event)
            return nil
        }
    }

    private func stop() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        recording = false
    }

    private func handle(_ event: NSEvent) {
        if event.keyCode == kVK_Escape { stop(); return }
        let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard !mods.isEmpty else { return }
        store.hotkeyKeyCode = UInt32(event.keyCode)
        store.hotkeyModifiers = mods
        stop()
    }
}

struct SettingsView: View {
    @ObservedObject var store: SettingsStore
    @StateObject private var recorder: HotkeyRecorder

    init(store: SettingsStore) {
        self.store = store
        _recorder = StateObject(wrappedValue: HotkeyRecorder(store: store))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Capture hotkey").font(.headline)
                HStack {
                    Text(recorder.recording
                         ? "Press a key combo… (Esc to cancel)"
                         : HotkeyFormat.label(modifiers: store.hotkeyModifiers, keyCode: store.hotkeyKeyCode))
                        .font(.system(.body, design: .monospaced))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .frame(minWidth: 200, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color(NSColor.textBackgroundColor)))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(NSColor.separatorColor)))
                    Button(recorder.recording ? "Cancel" : "Change…") { recorder.toggle() }
                }
                Text("Tip: must include at least one modifier (⌃ ⌥ ⇧ ⌘).")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Toggle("Show stack overlay after capture", isOn: $store.showStack)
                Text("When off, captures are still copied to the clipboard but the floating stack is hidden.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Save location").font(.headline)
                HStack {
                    Text(store.saveDirectory.path)
                        .font(.system(.body, design: .monospaced))
                        .truncationMode(.head)
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color(NSColor.textBackgroundColor)))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(NSColor.separatorColor)))
                    Button("Choose…") { chooseDirectory() }
                    Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([store.saveDirectory]) }
                }
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = store.saveDirectory
        if panel.runModal() == .OK, let url = panel.url {
            store.saveDirectory = url
        }
    }
}
