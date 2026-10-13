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
                Toggle("Floating shortcut", isOn: $store.persistentIcon)
                Text("Pins a small ContextSnap icon to the top-right of the active screen. Click it to start a capture.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Toggle(
                    "Launch ContextSnap at login",
                    isOn: Binding(
                        get: { store.launchAtLogin },
                        set: { store.setLaunchAtLogin($0) }
                    )
                )
                .disabled(!store.canManageLaunchAtLogin)

                if let error = store.launchAtLoginError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                } else {
                    Text("Starts the app automatically when you sign in.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Toggle("Break reminder pet", isOn: $store.breakReminderEnabled)
                if store.breakReminderEnabled {
                    HStack(spacing: 8) {
                        Text("Nudge me after").font(.callout)
                        Picker("", selection: $store.breakIntervalMinutes) {
                            ForEach([20, 30, 45, 60], id: \.self) { Text("\($0) min").tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 92)
                        Text("of work, break for").font(.callout)
                        Picker("", selection: $store.breakLengthMinutes) {
                            ForEach([1, 3, 5], id: \.self) { Text("\($0) min").tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 82)
                        Spacer()
                        Button("Say hi") { BreakReminderController.shared.preview() }
                    }
                }
                Text("A small pet hops into the middle of your screen when you've been typing for too long. Time away from the keyboard already counts as a break, so it stays quiet when you're not here.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Ask AI commands").font(.headline)
                HStack {
                    Text("Claude").frame(width: 54, alignment: .leading)
                    TextField("claude", text: $store.claudeCommand)
                        .font(.system(.body, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                }
                HStack {
                    Text("Codex").frame(width: 54, alignment: .leading)
                    TextField("codex", text: $store.codexCommand)
                        .font(.system(.body, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                }
                Picker("Default agent", selection: $store.aiBackend) {
                    ForEach(AIBackend.allCases) { backend in
                        Text(backend.displayName).tag(backend)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text("Each runs in a login shell with the screenshot attached. Change a command if the CLI lives somewhere your shell profile doesn't add to PATH; a chat window only offers the agents actually installed.")
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
        .onAppear {
            store.refreshLaunchAtLogin()
        }
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
