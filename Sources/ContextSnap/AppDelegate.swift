import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var overlay: OverlayPanelController!
    private var hotkey: GlobalHotkey?
    private var settingsWindow: NSWindow?
    private var captureMenuItem: NSMenuItem!
    private var cancellables: Set<AnyCancellable> = []
    private let settings = SettingsStore.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        overlay = OverlayPanelController()
        // On some macOS 15.x systems, creating the status item during the
        // launch notification can silently fail to surface in SystemUIServer.
        // Defer it one runloop turn so NSApp has fully settled.
        DispatchQueue.main.async { [weak self] in
            self?.setupStatusItem()
        }
        reloadHotkey()

        Publishers.CombineLatest(settings.$hotkeyKeyCode, settings.$hotkeyModifiers)
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in self?.reloadHotkey() }
            .store(in: &cancellables)

        settings.$showStack
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.overlay.applyVisibility() }
            .store(in: &cancellables)
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.isVisible = true
        if let button = statusItem.button {
            button.image = Self.makeStatusIcon()
            button.imagePosition = .imageOnly
            button.title = ""
            button.toolTip = "ContextSnap"
        }
        let menu = NSMenu()
        captureMenuItem = NSMenuItem(title: captureMenuTitle, action: #selector(capture), keyEquivalent: "")
        captureMenuItem.target = self
        menu.addItem(captureMenuItem)
        menu.addItem(.separator())
        let clearItem = NSMenuItem(title: "Clear Stack", action: #selector(clearStack), keyEquivalent: "")
        clearItem.target = self
        menu.addItem(clearItem)
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit ContextSnap", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private var captureMenuTitle: String {
        "Capture Area    " + HotkeyFormat.label(modifiers: settings.hotkeyModifiers, keyCode: settings.hotkeyKeyCode)
    }

    private func reloadHotkey() {
        hotkey = nil  // unregister old via deinit
        hotkey = GlobalHotkey(keyCode: settings.hotkeyKeyCode, modifiers: settings.hotkeyModifiers) { [weak self] in
            self?.capture()
        }
        captureMenuItem?.title = captureMenuTitle
    }

    @objc func capture() {
        Task { @MainActor in
            if let shot = await ScreenCapturer.captureInteractive() {
                overlay.add(shot)
                MultiFormatPasteboard.writeToClipboard(shot)
            }
        }
    }

    @objc func clearStack() {
        overlay.clear()
    }

    private static func makeStatusIcon() -> NSImage {
        if let image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "ContextSnap") {
            image.isTemplate = true
            return image
        }

        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let s = rect.width
            NSColor.black.setStroke()
            NSColor.black.setFill()
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)

            // Viewfinder brackets
            let inset = s * 0.06
            let bracketLen = s * 0.26
            ctx.setLineWidth(s * 0.11)
            let r = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
            func corner(_ ax: CGFloat, _ ay: CGFloat, _ bx: CGFloat, _ by: CGFloat, _ cx: CGFloat, _ cy: CGFloat) {
                ctx.move(to: CGPoint(x: ax, y: ay))
                ctx.addLine(to: CGPoint(x: bx, y: by))
                ctx.addLine(to: CGPoint(x: cx, y: cy))
            }
            corner(r.minX, r.maxY - bracketLen, r.minX, r.maxY, r.minX + bracketLen, r.maxY)
            corner(r.maxX - bracketLen, r.maxY, r.maxX, r.maxY, r.maxX, r.maxY - bracketLen)
            corner(r.minX, r.minY + bracketLen, r.minX, r.minY, r.minX + bracketLen, r.minY)
            corner(r.maxX - bracketLen, r.minY, r.maxX, r.minY, r.maxX, r.minY + bracketLen)
            ctx.strokePath()

            // Center filled card (echoes the stack motif from app icon)
            let cardSize = s * 0.40
            let cx = s / 2, cy = s / 2
            let cardRect = CGRect(x: cx - cardSize / 2, y: cy - cardSize / 2,
                                  width: cardSize, height: cardSize)
            let cardPath = CGPath(roundedRect: cardRect,
                                  cornerWidth: cardSize * 0.22,
                                  cornerHeight: cardSize * 0.22,
                                  transform: nil)
            ctx.addPath(cardPath)
            ctx.fillPath()
            return true
        }
        image.isTemplate = true
        return image
    }

    @objc func showSettings() {
        if settingsWindow == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 330),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            w.title = "ContextSnap Settings"
            w.contentView = NSHostingView(rootView: SettingsView(store: settings))
            w.center()
            w.isReleasedWhenClosed = false
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
