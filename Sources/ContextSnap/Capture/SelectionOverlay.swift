import AppKit

@MainActor
final class SelectionOverlay {
    private static var active: SelectionOverlay?

    static func selectRect() async -> NSRect? {
        if active != nil { return nil }
        return await withCheckedContinuation { cont in
            let overlay = SelectionOverlay(continuation: cont)
            active = overlay
            overlay.present()
        }
    }

    private let window: NSWindow
    private let view: SelectionView
    private let screen: NSScreen
    private var continuation: CheckedContinuation<NSRect?, Never>?

    private init(continuation: CheckedContinuation<NSRect?, Never>) {
        self.continuation = continuation
        let target = NSScreen.screenContainingMouse() ?? NSScreen.main!
        self.screen = target
        window = KeyableOverlayWindow(contentRect: target.frame,
                                      styleMask: [.nonactivatingPanel, .borderless],
                                      backing: .buffered,
                                      defer: false,
                                      screen: target)
        window.level = .screenSaver
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        view = SelectionView(frame: NSRect(origin: .zero, size: target.frame.size))
        window.contentView = view
    }

    private func present() {
        view.onComplete = { [weak self] rect in self?.finish(rect) }
        // Don't NSApp.activate — that yanks the user out of any active
        // fullscreen Space. The nonactivating panel can still receive
        // mouse + key events without us becoming frontmost.
        window.orderFrontRegardless()
        window.makeKey()
        window.makeFirstResponder(view)
        NSCursor.crosshair.set()
    }

    private func finish(_ rect: NSRect?) {
        NSCursor.arrow.set()
        window.orderOut(nil)
        let global: NSRect?
        if let r = rect {
            global = NSRect(x: screen.frame.origin.x + r.origin.x,
                            y: screen.frame.origin.y + r.origin.y,
                            width: r.width, height: r.height)
        } else {
            global = nil
        }
        continuation?.resume(returning: global)
        continuation = nil
        Self.active = nil
    }
}

private final class KeyableOverlayWindow: NSPanel {
    // Borderless / nonactivating panels return false from canBecomeKey
    // by default, which prevents keyDown events (incl. Esc) from reaching
    // the view. Force it on so Esc still cancels the selection.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private extension NSScreen {
    static func screenContainingMouse() -> NSScreen? {
        let p = NSEvent.mouseLocation
        return NSScreen.screens.first { NSPointInRect(p, $0.frame) }
    }
}

private final class SelectionView: NSView {
    var onComplete: ((NSRect?) -> Void)?
    private var startPoint: NSPoint?
    private var currentPoint: NSPoint?

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    override func mouseDown(with event: NSEvent) {
        startPoint = event.locationInWindow
        currentPoint = startPoint
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        currentPoint = event.locationInWindow
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let rect = currentSelection
        if rect.width < 4 || rect.height < 4 {
            onComplete?(nil)
        } else {
            onComplete?(rect)
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            onComplete?(nil)
        }
    }

    private var currentSelection: NSRect {
        guard let a = startPoint, let b = currentPoint else { return .zero }
        return NSRect(x: min(a.x, b.x), y: min(a.y, b.y),
                      width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    override func draw(_ dirtyRect: NSRect) {
        let sel = currentSelection

        // Dim everything except the selection (even-odd cut-out).
        let mask = NSBezierPath(rect: bounds)
        if !sel.isEmpty {
            mask.append(NSBezierPath(rect: sel))
            mask.windingRule = .evenOdd
        }
        NSColor.black.withAlphaComponent(0.35).setFill()
        mask.fill()

        guard !sel.isEmpty else { return }

        // Four-corner brackets — echoes the app icon.
        let bracketLen: CGFloat = max(14, min(min(sel.width, sel.height) * 0.18, 32))
        let lineWidth: CGFloat = 3
        let strokeColor = NSColor.white
        strokeColor.setStroke()
        let bp = NSBezierPath()
        bp.lineWidth = lineWidth
        bp.lineCapStyle = .round
        bp.lineJoinStyle = .round

        func corner(_ a: NSPoint, _ b: NSPoint, _ c: NSPoint) {
            bp.move(to: a); bp.line(to: b); bp.line(to: c)
        }
        // Cocoa Y is bottom-up: minY = bottom, maxY = top.
        corner(NSPoint(x: sel.minX, y: sel.maxY - bracketLen),
               NSPoint(x: sel.minX, y: sel.maxY),
               NSPoint(x: sel.minX + bracketLen, y: sel.maxY))
        corner(NSPoint(x: sel.maxX - bracketLen, y: sel.maxY),
               NSPoint(x: sel.maxX, y: sel.maxY),
               NSPoint(x: sel.maxX, y: sel.maxY - bracketLen))
        corner(NSPoint(x: sel.minX, y: sel.minY + bracketLen),
               NSPoint(x: sel.minX, y: sel.minY),
               NSPoint(x: sel.minX + bracketLen, y: sel.minY))
        corner(NSPoint(x: sel.maxX - bracketLen, y: sel.minY),
               NSPoint(x: sel.maxX, y: sel.minY),
               NSPoint(x: sel.maxX, y: sel.minY + bracketLen))
        bp.stroke()

        // Subtle 1px outline of the full selection (helps when brackets are far apart).
        NSColor.white.withAlphaComponent(0.35).setStroke()
        let outline = NSBezierPath(rect: sel)
        outline.lineWidth = 1
        outline.stroke()

        // Dimensions tag.
        let label = "\(Int(sel.width.rounded())) × \(Int(sel.height.rounded()))"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let attr = NSAttributedString(string: label, attributes: attrs)
        let labelSize = attr.size()
        let pad: CGFloat = 6
        var labelOrigin = NSPoint(x: sel.maxX - labelSize.width - pad,
                                  y: sel.minY - labelSize.height - 2 * pad - 4)
        if labelOrigin.y < 4 {
            labelOrigin.y = sel.maxY + 6
        }
        let bgRect = NSRect(x: labelOrigin.x - pad,
                            y: labelOrigin.y - pad / 2,
                            width: labelSize.width + 2 * pad,
                            height: labelSize.height + pad)
        NSColor.black.withAlphaComponent(0.65).setFill()
        NSBezierPath(roundedRect: bgRect, xRadius: 4, yRadius: 4).fill()
        attr.draw(at: labelOrigin)
    }
}
