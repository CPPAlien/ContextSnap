import AppKit

/// What the user asked for after settling on a region.
enum SelectionAction {
    /// Plain capture: copy to clipboard and add to the stack.
    case capture
    /// Capture, then open an AI chat about the region.
    case askAI
}

struct SelectionResult {
    let rect: NSRect
    let action: SelectionAction
}

@MainActor
final class SelectionOverlay {
    private static var active: SelectionOverlay?

    static func select() async -> SelectionResult? {
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
    private var continuation: CheckedContinuation<SelectionResult?, Never>?
    private var localEscapeMonitor: Any?
    private var globalEscapeMonitor: Any?

    private init(continuation: CheckedContinuation<SelectionResult?, Never>) {
        self.continuation = continuation
        self.screen = NSScreen.screenContainingMouse() ?? NSScreen.main!
        window = KeyableOverlayWindow(contentRect: screen.frame,
                                      styleMask: [.nonactivatingPanel, .borderless],
                                      backing: .buffered,
                                      defer: false,
                                      screen: screen)
        window.level = .screenSaver
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        view = SelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
        window.contentView = view
    }

    private func present() {
        view.onComplete = { [weak self] rect, action in
            self?.finish(rect, action: action)
        }
        startEscapeMonitoring()
        // Don't NSApp.activate — that yanks the user out of any active
        // fullscreen Space. The nonactivating panel can still receive
        // mouse + key events without us becoming frontmost.
        window.setFrame(screen.frame, display: true)
        window.orderFrontRegardless()
        window.makeKey()
        window.makeFirstResponder(view)
        NSCursor.crosshair.set()
    }

    private func finish(_ rect: NSRect?, action: SelectionAction = .capture) {
        guard let continuation else { return }

        NSCursor.arrow.set()
        stopEscapeMonitoring()
        view.onComplete = nil
        window.orderOut(nil)
        window.close()

        let result: SelectionResult?
        if let r = rect {
            let global = NSRect(x: screen.frame.origin.x + r.origin.x,
                                y: screen.frame.origin.y + r.origin.y,
                                width: r.width, height: r.height)
            result = SelectionResult(rect: global, action: action)
        } else {
            result = nil
        }
        self.continuation = nil
        continuation.resume(returning: result)
        Self.active = nil
    }

    private func startEscapeMonitoring() {
        localEscapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            self?.finish(nil)
            return nil
        }

        globalEscapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return }
            Task { @MainActor in
                self?.finish(nil)
            }
        }
    }

    private func stopEscapeMonitoring() {
        if let localEscapeMonitor {
            NSEvent.removeMonitor(localEscapeMonitor)
            self.localEscapeMonitor = nil
        }

        if let globalEscapeMonitor {
            NSEvent.removeMonitor(globalEscapeMonitor)
            self.globalEscapeMonitor = nil
        }
    }
}

private extension NSScreen {
    static func screenContainingMouse() -> NSScreen? {
        let point = NSEvent.mouseLocation
        return screens.first { $0.frame.contains(point) }
    }
}

private final class KeyableOverlayWindow: NSPanel {
    // Borderless / nonactivating panels return false from canBecomeKey
    // by default, which prevents keyDown events (incl. Esc) from reaching
    // the view. Force it on so Esc still cancels the selection.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class SelectionView: NSView {
    var onComplete: ((NSRect?, SelectionAction) -> Void)?

    private enum Phase {
        /// Nothing selected yet, or the user is dragging out a new region.
        case drawing
        /// A region is selected and waiting for ✓ / ✕ / AI; can still be
        /// moved by dragging inside it or replaced by dragging outside.
        case pending
    }

    private var phase: Phase = .drawing
    private var startPoint: NSPoint?
    private var currentPoint: NSPoint?
    private var pendingRect: NSRect = .zero
    private var moveAnchor: NSPoint?
    private var moveOrigin: NSPoint?

    private let toolbar = SelectionToolbar()

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        toolbar.isHidden = true
        toolbar.onCancel = { [weak self] in self?.onComplete?(nil, .capture) }
        toolbar.onConfirm = { [weak self] in self?.confirm(.capture) }
        toolbar.onAskAI = { [weak self] in self?.confirm(.askAI) }
        addSubview(toolbar)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func confirm(_ action: SelectionAction) {
        guard phase == .pending, !pendingRect.isEmpty else { return }
        onComplete?(pendingRect, action)
    }

    override func mouseDown(with event: NSEvent) {
        let p = event.locationInWindow
        if phase == .pending, pendingRect.contains(p) {
            moveAnchor = p
            moveOrigin = pendingRect.origin
            return
        }
        phase = .drawing
        toolbar.isHidden = true
        pendingRect = .zero
        startPoint = p
        currentPoint = p
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = event.locationInWindow
        if let anchor = moveAnchor, let origin = moveOrigin {
            var r = pendingRect
            r.origin = NSPoint(x: origin.x + (p.x - anchor.x), y: origin.y + (p.y - anchor.y))
            // Keep the region on screen.
            r.origin.x = min(max(r.origin.x, 0), bounds.width - r.width)
            r.origin.y = min(max(r.origin.y, 0), bounds.height - r.height)
            pendingRect = r
            layoutToolbar()
            needsDisplay = true
            return
        }
        currentPoint = p
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if moveAnchor != nil {
            moveAnchor = nil
            moveOrigin = nil
            return
        }
        let rect = currentSelection
        startPoint = nil
        currentPoint = nil
        if rect.width < 4 || rect.height < 4 {
            // A stray click without a drag: keep waiting for a real drag.
            pendingRect = .zero
            phase = .drawing
            toolbar.isHidden = true
        } else {
            pendingRect = rect
            phase = .pending
            toolbar.isHidden = false
            layoutToolbar()
        }
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: // Escape
            onComplete?(nil, .capture)
        case 36, 76: // Return / keypad Enter
            confirm(.capture)
        default:
            super.keyDown(with: event)
        }
    }

    /// Places the ✕ / AI / ✓ pill just below the selection, right-aligned,
    /// flipping above it when there is no room underneath.
    private func layoutToolbar() {
        let size = toolbar.fittingSize
        let gap: CGFloat = 8
        var x = pendingRect.maxX - size.width
        x = min(max(x, 4), bounds.width - size.width - 4)
        var y = pendingRect.minY - gap - size.height
        if y < 4 {
            y = pendingRect.maxY + gap
            if y + size.height > bounds.height - 4 {
                y = pendingRect.maxY - gap - size.height
            }
        }
        toolbar.frame = NSRect(origin: NSPoint(x: x, y: y), size: size)
    }

    private var currentSelection: NSRect {
        if phase == .pending { return pendingRect }
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
        if phase == .pending {
            // Toolbar owns the bottom-right corner; tuck the tag on the left.
            labelOrigin.x = sel.minX + pad
        }
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

/// Dark floating pill with three big round buttons — ✕ / ✦ Ask AI / ✓ —
/// plus a one-line key hint. Custom drawn so it reads clearly over any
/// screen content instead of relying on system button bezels.
private final class SelectionToolbar: NSView {
    var onCancel: (() -> Void)?
    var onAskAI: (() -> Void)?
    var onConfirm: (() -> Void)?

    private let stack = NSStackView()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.88).cgColor
        layer?.cornerRadius = 14
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        shadow = NSShadow()
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.45
        layer?.shadowRadius = 10
        layer?.shadowOffset = CGSize(width: 0, height: -3)

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        stack.addArrangedSubview(RoundButton(symbol: "xmark", title: nil,
                                             tint: NSColor(white: 1, alpha: 0.16), fg: .white,
                                             tip: "Cancel  (Esc)") { [weak self] in self?.onCancel?() })
        stack.addArrangedSubview(RoundButton(symbol: "sparkles", title: "Ask AI",
                                             tint: NSColor(srgbRed: 0.55, green: 0.36, blue: 0.96, alpha: 1), fg: .white,
                                             tip: "Ask Claude about this region") { [weak self] in self?.onAskAI?() })
        stack.addArrangedSubview(RoundButton(symbol: "checkmark", title: nil,
                                             tint: NSColor(srgbRed: 0.20, green: 0.72, blue: 0.40, alpha: 1), fg: .white,
                                             tip: "Capture  (⏎)") { [weak self] in self?.onConfirm?() })
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // Swallow clicks so they never fall through to the selection view
    // (which would otherwise start a fresh drag).
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}
}

/// A pill/circle button with a filled tint, hover brightening and press dimming.
private final class RoundButton: NSView {
    private let action: () -> Void
    private let tint: NSColor
    private var hovering = false { didSet { refresh() } }
    private var pressed = false { didSet { refresh() } }
    private let height: CGFloat = 36

    init(symbol: String, title: String?, tint: NSColor, fg: NSColor, tip: String, action: @escaping () -> Void) {
        self.action = action
        self.tint = tint
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = height / 2
        toolTip = tip
        translatesAutoresizingMaskIntoConstraints = false

        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .bold)
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?.withSymbolConfiguration(config)
        icon.contentTintColor = fg
        icon.translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 6
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        row.addArrangedSubview(icon)
        var width: CGFloat = height
        if let title {
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 14, weight: .semibold)
            label.textColor = fg
            row.addArrangedSubview(label)
            width = 16 + 18 + 6 + label.intrinsicContentSize.width + 16
        }
        addSubview(row)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: width),
            heightAnchor.constraint(equalToConstant: height),
            row.centerXAnchor.constraint(equalTo: centerXAnchor),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    private func refresh() {
        var c = tint
        if pressed { c = tint.blended(withFraction: 0.25, of: .black) ?? tint }
        else if hovering { c = tint.blended(withFraction: 0.18, of: .white) ?? tint }
        layer?.backgroundColor = c.cgColor
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false; pressed = false }
    override func mouseDown(with event: NSEvent) { pressed = true }
    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        pressed = false
        if inside { action() }
    }
}
