import AppKit
import ScreenCaptureKit

struct Shot: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    var image: NSImage
    let originalImage: NSImage
    var isEdited = false

    init(url: URL, image: NSImage, originalImage: NSImage? = nil, isEdited: Bool = false) {
        self.url = url
        self.image = image
        self.originalImage = originalImage ?? image
        self.isEdited = isEdited
    }

    static func == (lhs: Shot, rhs: Shot) -> Bool { lhs.id == rhs.id }
}

@MainActor
enum ScreenCapturer {
    static func captureInteractive() async -> Shot? {
        guard let cocoaRect = await SelectionOverlay.selectRect() else { return nil }
        // Give the overlay one runloop tick to fully order out before we
        // ask the WindowServer for a screenshot — otherwise the dim layer
        // can sneak into the capture on slower machines.
        try? await Task.sleep(nanoseconds: 30_000_000)

        guard let cgImage = await capture(cocoaRect: cocoaRect) else { return nil }
        let nsImage = NSImage(cgImage: cgImage, size: cocoaRect.size)

        let url = ShotStore.newURL()
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
        try? png.write(to: url)
        return Shot(url: url, image: nsImage)
    }

    /// Captures a global Cocoa rect using ScreenCaptureKit. CGWindowListCreateImage
    /// is deprecated on macOS 14 and on macOS 15 it returns only the desktop
    /// wallpaper (windows stripped) regardless of TCC grant.
    private static func capture(cocoaRect: NSRect) async -> CGImage? {
        guard let screen = screen(containing: cocoaRect),
              let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        else { return nil }

        // SCStreamConfiguration.sourceRect uses display-local points with a
        // top-left origin; convert from the global bottom-left Cocoa rect.
        let localX = cocoaRect.minX - screen.frame.minX
        let localYFromTop = screen.frame.height - (cocoaRect.minY - screen.frame.minY) - cocoaRect.height
        let sourceRect = CGRect(x: localX, y: localYFromTop, width: cocoaRect.width, height: cocoaRect.height)

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true
            )
            guard let scDisplay = content.displays.first(where: { $0.displayID == displayID }) else {
                return nil
            }

            let filter = SCContentFilter(display: scDisplay, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.sourceRect = sourceRect
            let scale = screen.backingScaleFactor
            config.width = max(1, Int(cocoaRect.width * scale))
            config.height = max(1, Int(cocoaRect.height * scale))
            config.showsCursor = false
            config.capturesAudio = false
            config.ignoreShadowsDisplay = true

            return try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: config
            )
        } catch {
            return nil
        }
    }

    private static func screen(containing rect: NSRect) -> NSScreen? {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        return NSScreen.screens.first { $0.frame.contains(center) }
    }
}
