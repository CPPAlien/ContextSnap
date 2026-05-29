import AppKit
import Combine
import SwiftUI

@MainActor
final class OverlayPanelController {
    private let panel: NSPanel
    private var host: NSHostingView<ShotStackView>!
    private var previewPanel: PreviewPanel?
    private var previewedShotID: Shot.ID?
    private var localPreviewEscapeMonitor: Any?
    private var globalPreviewEscapeMonitor: Any?
    let model = ShotStack()
    private var cancellables: Set<AnyCancellable> = []
    private var followTimer: Timer?
    private var lastScreenFrame: NSRect = .zero

    private static let panelWidth: CGFloat = 176
    private static let edgeInset: CGFloat = 24

    private let onCaptureRequested: () -> Void

    init(onCaptureRequested: @escaping () -> Void = {}) {
        self.onCaptureRequested = onCaptureRequested
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let rect = NSRect(
            x: screen.maxX - Self.panelWidth - Self.edgeInset,
            y: screen.maxY - 80 - Self.edgeInset,
            width: Self.panelWidth,
            height: 80
        )
        panel = NSPanel(
            contentRect: rect,
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.level = .popUpMenu  // above fullscreen window content
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        // Keep the stack present across Spaces, including fullscreen apps.
        // Its frame is still updated below to the current screen's top-right.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovableByWindowBackground = false
        panel.isMovable = true

        host = NSHostingView(
            rootView: ShotStackView(
                model: model,
                onPreview: { [weak self] shot in
                    self?.showPreview(for: shot)
                },
                onLayoutChange: { [weak self] in
                    DispatchQueue.main.async {
                        self?.resizeToFit()
                    }
                },
                onCaptureRequested: { [weak self] in
                    self?.onCaptureRequested()
                },
                onImport: { [weak self] image in
                    self?.importImage(image)
                }
            )
        )
        host.autoresizingMask = [.width, .height]
        panel.contentView = host

        // Hide the panel automatically when the stack empties (e.g. user
        // closed the last tile) so the drag-handle header doesn't linger.
        model.$shots
            .map(\.isEmpty)
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyVisibility() }
            .store(in: &cancellables)

        // Re-check when the active app/Space/display changes. If the stack is
        // already visible on any current screen, keep it where the user left it.
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didActivateApplicationNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                if self.panel.isVisible { self.scheduleScreenFollow() }
            }
            .store(in: &cancellables)

        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                if self.panel.isVisible { self.scheduleScreenFollow() }
            }
            .store(in: &cancellables)

        NotificationCenter.default
            .publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                if self.panel.isVisible { self.followCurrentScreen(force: true) }
            }
            .store(in: &cancellables)
    }

    func importImage(_ image: NSImage) {
        guard let png = pngData(for: image) else { return }
        let url = ShotStore.newURL()
        try? png.write(to: url)
        let canonical = NSImage(data: png) ?? image
        add(Shot(url: url, image: canonical))
    }

    private func pngData(for image: NSImage) -> Data? {
        if let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            return png
        }
        if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let rep = NSBitmapImageRep(cgImage: cg)
            return rep.representation(using: .png, properties: [:])
        }
        return nil
    }

    func add(_ shot: Shot) {
        model.append(shot)
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
        startScreenFollow()
        DispatchQueue.main.async { [weak self] in
            self?.followCurrentScreen(force: true)
        }
    }

    func clear() {
        model.clear()
        closePreview()
        applyVisibility()
    }

    func applyVisibility() {
        let shouldShow = !model.shots.isEmpty || SettingsStore.shared.persistentIcon
        if shouldShow {
            if !panel.isVisible { panel.orderFrontRegardless() }
            startScreenFollow()
            DispatchQueue.main.async { [weak self] in self?.followCurrentScreen(force: true) }
        } else if panel.isVisible {
            panel.orderOut(nil)
            stopScreenFollow()
        }
    }

    private func resizeToFit(anchor: NSRect? = nil) {
        let fitting = host.fittingSize
        let height = max(fitting.height, 42)
        let newFrame: NSRect

        if let anchor {
            newFrame = NSRect(
                x: anchor.maxX - Self.panelWidth - Self.edgeInset,
                y: anchor.maxY - height - Self.edgeInset,
                width: Self.panelWidth,
                height: height
            )
        } else if panelVisibleScreenFrame() != nil {
            newFrame = NSRect(
                x: panel.frame.maxX - Self.panelWidth,
                y: panel.frame.maxY - height,
                width: Self.panelWidth,
                height: height
            )
        } else {
            let anchor = anchorRect()
            newFrame = NSRect(
                x: anchor.maxX - Self.panelWidth - Self.edgeInset,
                y: anchor.maxY - height - Self.edgeInset,
                width: Self.panelWidth,
                height: height
            )
        }

        panel.setFrame(newFrame, display: true, animate: false)
    }

    private func scheduleScreenFollow() {
        // Space transitions report screen/window state in stages. Re-sample
        // through the animation instead of trusting a single early read.
        for delay in [0.02, 0.10, 0.22, 0.40, 0.70] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.panel.isVisible else { return }
                self.panel.orderFrontRegardless()
                self.followCurrentScreen(force: true)
            }
        }
    }

    private func startScreenFollow() {
        guard followTimer == nil else { return }
        let timer = Timer(timeInterval: 0.16, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.followCurrentScreen()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        followTimer = timer
    }

    private func stopScreenFollow() {
        followTimer?.invalidate()
        followTimer = nil
        lastScreenFrame = .zero
    }

    private func showPreview(for shot: Shot) {
        let isOpeningFromClosed = previewedShotID == nil
        previewedShotID = shot.id
        model.selectedID = shot.id

        let anchor = panelVisibleScreenFrame()
            ?? panel.screen?.visibleFrame
            ?? targetScreenFrame()

        let preview = previewPanel ?? makePreviewPanel()
        if isOpeningFromClosed { preview.userHasResized = false }
        preview.onClose = { [weak self] in self?.closePreview() }
        preview.onPrevious = { [weak self] in self?.showPreviousPreview() }
        preview.onNext = { [weak self] in self?.showNextPreview() }
        let hosting = NSHostingView(
            rootView: ShotPreviewView(
                model: model,
                shotID: shot.id,
                fallbackShot: shot,
                canGoPrevious: previousShot(before: shot.id) != nil,
                canGoNext: nextShot(after: shot.id) != nil,
                onPrevious: { [weak self] in self?.showPreviousPreview() },
                onNext: { [weak self] in self?.showNextPreview() },
                onClose: { [weak self] in self?.closePreview() }
            )
        )
        preview.contentView = Self.previewContentView(hosting: hosting)

        if !preview.userHasResized {
            preview.setFrame(Self.previewFrame(for: shot, anchor: anchor), display: true, animate: false)
        }
        preview.orderFrontRegardless()
        preview.makeKey()
        previewPanel = preview
        startPreviewEscapeMonitoring()
    }

    /// Natural-size frame: image's point dimensions plus the toolbar chrome,
    /// clamped to ~95% of the screen so very large captures still fit.
    private static func previewFrame(for shot: Shot, anchor: NSRect) -> NSRect {
        let imageSize = shot.image.size
        let chrome: CGFloat = 30  // 14pt image padding + 1pt outer ring, both sides
        let availableWidth = max(anchor.width * 0.95 - chrome, 1)
        let availableHeight = max(anchor.height * 0.95 - chrome, 1)
        let scale = min(
            1.0,
            availableWidth / max(imageSize.width, 1),
            availableHeight / max(imageSize.height, 1)
        )
        let imageDisplaySize = CGSize(
            width: imageSize.width * scale,
            height: imageSize.height * scale
        )
        let panelSize = CGSize(
            width: max(imageDisplaySize.width + chrome, 360),
            height: max(imageDisplaySize.height + chrome, 260)
        )
        return NSRect(
            x: anchor.midX - panelSize.width / 2,
            y: anchor.midY - panelSize.height / 2,
            width: panelSize.width,
            height: panelSize.height
        )
    }

    /// Wraps the SwiftUI hosting view with a transparent edge overlay that
    /// provides resize cursors and drives the actual resize. We do it
    /// ourselves rather than relying on NSWindow's `.resizable` machinery
    /// because borderless panels don't get edge-cursor feedback from AppKit.
    private static func previewContentView(hosting: NSView) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = true
        container.autoresizingMask = [.width, .height]

        hosting.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hosting)

        let resizer = EdgeResizeAffordance()
        resizer.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(resizer)  // above the hosting view

        NSLayoutConstraint.activate([
            hosting.topAnchor.constraint(equalTo: container.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            hosting.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            resizer.topAnchor.constraint(equalTo: container.topAnchor),
            resizer.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            resizer.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            resizer.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        return container
    }

    private func makePreviewPanel() -> PreviewPanel {
        let panel = PreviewPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 260),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.level = .popUpMenu
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovable = true
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentMinSize = NSSize(width: 360, height: 260)
        return panel
    }

    private func closePreview() {
        previewPanel?.orderOut(nil)
        previewPanel?.resignKey()
        previewedShotID = nil
        stopPreviewEscapeMonitoring()
    }

    private func showPreviousPreview() {
        guard let previewedShotID, let shot = previousShot(before: previewedShotID) else { return }
        showPreview(for: shot)
    }

    private func showNextPreview() {
        guard let previewedShotID, let shot = nextShot(after: previewedShotID) else { return }
        showPreview(for: shot)
    }

    private func previousShot(before id: Shot.ID) -> Shot? {
        guard let index = model.shots.firstIndex(where: { $0.id == id }), index > 0 else { return nil }
        return model.shots[index - 1]
    }

    private func nextShot(after id: Shot.ID) -> Shot? {
        guard let index = model.shots.firstIndex(where: { $0.id == id }),
              index < model.shots.index(before: model.shots.endIndex)
        else { return nil }
        return model.shots[index + 1]
    }

    private func startPreviewEscapeMonitoring() {
        guard localPreviewEscapeMonitor == nil, globalPreviewEscapeMonitor == nil else { return }

        localPreviewEscapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // While a text field is first responder (editing an annotation),
            // let the field handle navigation/escape itself.
            if event.window?.firstResponder is NSText { return event }
            switch event.keyCode {
            case 53:
                self?.closePreview()
                return nil
            case 123:
                self?.showPreviousPreview()
                return nil
            case 124:
                self?.showNextPreview()
                return nil
            default:
                return event
            }
        }

        globalPreviewEscapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return }
            Task { @MainActor in
                self?.closePreview()
            }
        }
    }

    private func stopPreviewEscapeMonitoring() {
        if let localPreviewEscapeMonitor {
            NSEvent.removeMonitor(localPreviewEscapeMonitor)
            self.localPreviewEscapeMonitor = nil
        }

        if let globalPreviewEscapeMonitor {
            NSEvent.removeMonitor(globalPreviewEscapeMonitor)
            self.globalPreviewEscapeMonitor = nil
        }
    }

    private func followCurrentScreen(force: Bool = false) {
        guard panel.isVisible else {
            stopScreenFollow()
            return
        }

        if let visibleScreenFrame = panelVisibleScreenFrame() {
            lastScreenFrame = visibleScreenFrame
            if force { resizeToFit() }
            return
        }

        let screenFrame = targetScreenFrame()
        guard force || !lastScreenFrame.nearlyEquals(screenFrame) else { return }

        lastScreenFrame = screenFrame
        resizeToFit(anchor: screenFrame)
    }

    /// The rectangle the panel anchors its top-right corner to: the current
    /// screen's visible frame, not an app/window frame.
    private func anchorRect() -> NSRect {
        targetScreenFrame()
    }

    private func targetScreenFrame() -> NSRect {
        frontmostWindowScreenFrame()
            ?? screenContainingMouse()?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? panel.screen?.visibleFrame
            ?? .zero
    }

    private func panelVisibleScreenFrame() -> NSRect? {
        let center = CGPoint(x: panel.frame.midX, y: panel.frame.midY)
        return NSScreen.screens.first { screen in
            screen.visibleFrame.insetBy(dx: -20, dy: -20).contains(center)
        }?.visibleFrame
    }

    private func frontmostWindowScreenFrame() -> NSRect? {
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.bundleIdentifier != Bundle.main.bundleIdentifier
        else { return nil }
        let pid = front.processIdentifier

        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
        else { return nil }

        // CGWindowList returns front-to-back. Use the top normal window only
        // to infer the active display; the stack still anchors to the screen.
        for entry in info {
            guard (entry[kCGWindowOwnerPID as String] as? pid_t) == pid else { continue }
            guard (entry[kCGWindowLayer as String] as? Int) == 0 else { continue }
            guard let b = entry[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = b["X"], let y = b["Y"],
                  let w = b["Width"], let h = b["Height"],
                  w > 100, h > 100
            else { continue }

            let center = CGPoint(x: x + w / 2, y: y + h / 2)
            return screenContainingCGPoint(center)?.visibleFrame
        }
        return nil
    }

    private func screenContainingMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) }
    }

    private func screenContainingCGPoint(_ point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
                return false
            }
            return CGDisplayBounds(id).contains(point)
        }
    }
}

private final class PreviewPanel: NSPanel, NSWindowDelegate {
    var onClose: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onNext: (() -> Void)?
    /// True once the user has live-resized this panel — used to skip the
    /// auto-fit when navigating to a sibling shot in the same session.
    var userHasResized = false

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing backingStoreType: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        delegate = self
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        userHasResized = true
    }

    override func sendEvent(_ event: NSEvent) {
        guard event.type == .keyDown else {
            super.sendEvent(event)
            return
        }
        if firstResponder is NSTextView {
            super.sendEvent(event)
            return
        }

        switch event.keyCode {
        case 53:
            onClose?()
        case 123:
            onPrevious?()
        case 124:
            onNext?()
        default:
            super.sendEvent(event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        onClose?()
    }
}

private extension NSRect {
    func nearlyEquals(_ other: NSRect) -> Bool {
        abs(origin.x - other.origin.x) < 1 &&
        abs(origin.y - other.origin.y) < 1 &&
        abs(size.width - other.size.width) < 1 &&
        abs(size.height - other.size.height) < 1
    }
}

/// Transparent overlay that owns the panel's edges + corners: shows the
/// correct resize cursor on hover and drives the actual resize via setFrame.
/// Hit-test returns nil for the interior, so toolbar buttons and the markup
/// canvas underneath still receive their own clicks.
private final class EdgeResizeAffordance: NSView {
    private enum Edge {
        case top, bottom, left, right
        case topLeft, topRight, bottomLeft, bottomRight
    }

    private let edgeWidth: CGFloat = 6

    private var activeEdge: Edge?
    private var dragStartFrame: NSRect = .zero
    private var dragStartMouse: NSPoint = .zero

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return edge(at: local) == nil ? nil : self
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        for (edge, rect) in edgeRects() {
            addCursorRect(rect, cursor: Self.cursor(for: edge))
        }
    }

    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        guard let edge = edge(at: local), let window else {
            super.mouseDown(with: event)
            return
        }
        activeEdge = edge
        dragStartFrame = window.frame
        dragStartMouse = NSEvent.mouseLocation
        Self.cursor(for: edge).set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, let edge = activeEdge else {
            super.mouseDragged(with: event)
            return
        }
        let current = NSEvent.mouseLocation
        let dx = current.x - dragStartMouse.x
        let dy = current.y - dragStartMouse.y
        let f = dragStartFrame
        let minW = window.contentMinSize.width
        let minH = window.contentMinSize.height
        var newFrame = f

        switch edge {
        case .top:
            newFrame.size.height = max(minH, f.height + dy)
        case .bottom:
            let h = max(minH, f.height - dy)
            newFrame.size.height = h
            newFrame.origin.y = f.maxY - h
        case .left:
            let w = max(minW, f.width - dx)
            newFrame.size.width = w
            newFrame.origin.x = f.maxX - w
        case .right:
            newFrame.size.width = max(minW, f.width + dx)
        case .topLeft:
            let w = max(minW, f.width - dx)
            newFrame.size.width = w
            newFrame.origin.x = f.maxX - w
            newFrame.size.height = max(minH, f.height + dy)
        case .topRight:
            newFrame.size.width = max(minW, f.width + dx)
            newFrame.size.height = max(minH, f.height + dy)
        case .bottomLeft:
            let w = max(minW, f.width - dx)
            newFrame.size.width = w
            newFrame.origin.x = f.maxX - w
            let h = max(minH, f.height - dy)
            newFrame.size.height = h
            newFrame.origin.y = f.maxY - h
        case .bottomRight:
            newFrame.size.width = max(minW, f.width + dx)
            let h = max(minH, f.height - dy)
            newFrame.size.height = h
            newFrame.origin.y = f.maxY - h
        }
        window.setFrame(newFrame, display: true)
    }

    override func mouseUp(with event: NSEvent) {
        guard activeEdge != nil else {
            super.mouseUp(with: event)
            return
        }
        activeEdge = nil
        (window as? PreviewPanel)?.userHasResized = true
        NSCursor.arrow.set()
    }

    /// Edge + corner rects in view coordinates. Corners are listed first so
    /// `edge(at:)` finds them before falling through to the longer edges.
    private func edgeRects() -> [(Edge, NSRect)] {
        let r = bounds
        let w = edgeWidth
        let c = edgeWidth  // corner size matches edge width
        return [
            (.bottomLeft,  NSRect(x: 0,            y: 0,            width: c, height: c)),
            (.bottomRight, NSRect(x: r.width - c,  y: 0,            width: c, height: c)),
            (.topLeft,     NSRect(x: 0,            y: r.height - c, width: c, height: c)),
            (.topRight,    NSRect(x: r.width - c,  y: r.height - c, width: c, height: c)),
            (.bottom,      NSRect(x: c,            y: 0,            width: max(r.width  - 2 * c, 0), height: w)),
            (.top,         NSRect(x: c,            y: r.height - w, width: max(r.width  - 2 * c, 0), height: w)),
            (.left,        NSRect(x: 0,            y: c,            width: w, height: max(r.height - 2 * c, 0))),
            (.right,       NSRect(x: r.width - w,  y: c,            width: w, height: max(r.height - 2 * c, 0))),
        ]
    }

    private func edge(at point: NSPoint) -> Edge? {
        for (edge, rect) in edgeRects() where rect.contains(point) {
            return edge
        }
        return nil
    }

    private static func cursor(for edge: Edge) -> NSCursor {
        switch edge {
        case .top, .bottom: return .resizeUpDown
        case .left, .right: return .resizeLeftRight
        case .topLeft, .topRight, .bottomLeft, .bottomRight: return .crosshair
        }
    }
}
