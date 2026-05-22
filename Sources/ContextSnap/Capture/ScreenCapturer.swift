import AppKit

struct Shot: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let image: NSImage

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

        guard let cgImage = capture(cocoaRect: cocoaRect) else { return nil }
        let nsImage = NSImage(cgImage: cgImage, size: cocoaRect.size)

        let url = ShotStore.newURL()
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
        try? png.write(to: url)
        return Shot(url: url, image: nsImage)
    }

    /// Converts a Cocoa global rect (origin bottom-left of primary screen) to
    /// CoreGraphics global coordinates (top-left of primary screen) and
    /// captures that region from on-screen windows.
    private static func capture(cocoaRect: NSRect) -> CGImage? {
        guard let display = displayInfo(containing: cocoaRect) else { return nil }
        let localX = cocoaRect.minX - display.screenFrame.minX
        let localY = cocoaRect.minY - display.screenFrame.minY
        let cgRect = CGRect(
            x: display.cgBounds.minX + localX,
            y: display.cgBounds.minY + display.screenFrame.height - localY - cocoaRect.height,
            width: cocoaRect.width,
            height: cocoaRect.height
        )
        return CGWindowListCreateImage(cgRect,
                                       .optionOnScreenOnly,
                                       kCGNullWindowID,
                                       [.bestResolution, .boundsIgnoreFraming])
    }

    private static func displayInfo(containing rect: NSRect) -> (screenFrame: NSRect, cgBounds: CGRect)? {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        for screen in NSScreen.screens {
            guard screen.frame.contains(center),
                  let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            else { continue }
            return (screen.frame, CGDisplayBounds(id))
        }
        return nil
    }
}
