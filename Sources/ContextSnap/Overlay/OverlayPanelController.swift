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
        previewedShotID = shot.id
        model.selectedID = shot.id

        let anchor = panelVisibleScreenFrame()
            ?? panel.screen?.visibleFrame
            ?? targetScreenFrame()
        let imageSize = shot.image.size
        let maxSize = CGSize(width: anchor.width * 0.82, height: anchor.height * 0.82)
        let imageAspect = imageSize.width / max(imageSize.height, 1)
        let maxAspect = maxSize.width / max(maxSize.height, 1)
        let previewSize: CGSize

        if imageAspect > maxAspect {
            previewSize = CGSize(width: maxSize.width, height: maxSize.width / imageAspect)
        } else {
            previewSize = CGSize(width: maxSize.height * imageAspect, height: maxSize.height)
        }

        let panelSize = CGSize(
            width: max(previewSize.width + 28, 360),
            height: max(previewSize.height + 28, 260)
        )
        let frame = NSRect(
            x: anchor.midX - panelSize.width / 2,
            y: anchor.midY - panelSize.height / 2,
            width: panelSize.width,
            height: panelSize.height
        )

        let preview = previewPanel ?? makePreviewPanel()
        preview.onClose = { [weak self] in self?.closePreview() }
        preview.onPrevious = { [weak self] in self?.showPreviousPreview() }
        preview.onNext = { [weak self] in self?.showNextPreview() }
        preview.contentView = NSHostingView(
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
        preview.setFrame(frame, display: true, animate: false)
        preview.orderFrontRegardless()
        preview.makeKey()
        previewPanel = preview
        startPreviewEscapeMonitoring()
    }

    private func makePreviewPanel() -> PreviewPanel {
        let panel = PreviewPanel(
            contentRect: .zero,
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
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

private final class PreviewPanel: NSPanel {
    var onClose: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onNext: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

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
