import AppKit
import ScreenCaptureKit

struct Shot: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let image: NSImage
    var annotations: [Annotation] = []

    init(url: URL, image: NSImage, annotations: [Annotation] = []) {
        self.url = url
        self.image = image
        self.annotations = annotations
    }

    static func == (lhs: Shot, rhs: Shot) -> Bool {
        lhs.id == rhs.id && lhs.annotations == rhs.annotations
    }
}

struct InteractiveCapture {
    let shot: Shot
    let action: SelectionAction
}

@MainActor
enum ScreenCapturer {
    static func captureInteractive() async -> InteractiveCapture? {
        guard let selection = await SelectionOverlay.select() else { return nil }
        let nsImage = selection.image
        let url = ShotStore.newURL()
        guard let png = nsImage.pngData() else { return nil }
        do { try png.write(to: url) } catch { return nil }
        return InteractiveCapture(shot: Shot(url: url, image: nsImage, annotations: selection.annotations),
                                  action: selection.action)
    }

    /// Captures a global Cocoa rect using ScreenCaptureKit. CGWindowListCreateImage
    /// is deprecated on macOS 14 and on macOS 15 it returns only the desktop
    /// wallpaper (windows stripped) regardless of TCC grant.
    static func capture(cocoaRect: NSRect) async -> CGImage? {
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
