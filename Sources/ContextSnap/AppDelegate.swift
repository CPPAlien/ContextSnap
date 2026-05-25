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
        overlay = OverlayPanelController(onCaptureRequested: { [weak self] in
            self?.capture()
        })
        overlay.applyVisibility()
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

        settings.$persistentIcon
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

    /// Status-bar icon that mirrors the app icon's structure: two tilted
    /// stacked cards inside four viewfinder corner brackets. Drawn as a
    /// template so macOS recolors it for light/dark menu bars.
    private static func makeStatusIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let s = rect.width

            // Two stacked rounded-square cards, rotations mirroring the
            // app icon (+0.20 / -0.08 rad). Back card lighter via alpha so
            // it reads as a stack even in a tiny template glyph.
            let cardSize = s * 0.46
            let cardRadius = cardSize * 0.20
            let center = CGPoint(x: s / 2, y: s / 2)

            func drawCard(rotation: CGFloat, alpha: CGFloat) {
                ctx.saveGState()
                ctx.translateBy(x: center.x, y: center.y)
                ctx.rotate(by: rotation)
                let r = CGRect(x: -cardSize / 2, y: -cardSize / 2, width: cardSize, height: cardSize)
                ctx.addPath(CGPath(roundedRect: r, cornerWidth: cardRadius, cornerHeight: cardRadius, transform: nil))
                ctx.setFillColor(CGColor(gray: 0, alpha: alpha))
                ctx.fillPath()
                ctx.restoreGState()
            }
            drawCard(rotation: 0.20, alpha: 0.45)
            drawCard(rotation: -0.08, alpha: 1.0)

            // Viewfinder corner brackets, sized so the brackets just clear
            // the tilted front card.
            let inset = s * 0.04
            let bracketLen = s * 0.22
            let bracketWidth = s * 0.10
            ctx.setStrokeColor(CGColor(gray: 0, alpha: 1))
            ctx.setLineWidth(bracketWidth)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
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
