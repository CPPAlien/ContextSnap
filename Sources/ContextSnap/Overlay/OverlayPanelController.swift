import AppKit
import Combine
import SwiftUI

@MainActor
final class OverlayPanelController {
    private let panel: NSPanel
    private let host: NSHostingView<ShotStackView>
    let model = ShotStack()
    private var cancellables: Set<AnyCancellable> = []
    private var followTimer: Timer?
    private var lastScreenFrame: NSRect = .zero

    private static let panelWidth: CGFloat = 220
    private static let edgeInset: CGFloat = 24

    init() {
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

        host = NSHostingView(rootView: ShotStackView(model: model))
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

        // Re-anchor immediately when the active app/Space/display changes.
        // The visible-only timer below keeps multi-display focus changes smooth.
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

    func add(_ shot: Shot) {
        model.append(shot)
        if SettingsStore.shared.showStack {
            if !panel.isVisible {
                panel.orderFrontRegardless()
            }
            startScreenFollow()
            DispatchQueue.main.async { [weak self] in
                self?.followCurrentScreen(force: true)
            }
        } else if panel.isVisible {
            panel.orderOut(nil)
            stopScreenFollow()
        }
    }

    func clear() {
        model.clear()
        panel.orderOut(nil)
        stopScreenFollow()
    }

    func applyVisibility() {
        let shouldShow = SettingsStore.shared.showStack && !model.shots.isEmpty
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
        let height = max(fitting.height, 80)
        let anchor = anchor ?? anchorRect()
        let newFrame = NSRect(
            x: anchor.maxX - Self.panelWidth - Self.edgeInset,
            y: anchor.maxY - height - Self.edgeInset,
            width: Self.panelWidth,
            height: height
        )
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

    private func followCurrentScreen(force: Bool = false) {
        guard panel.isVisible else {
            stopScreenFollow()
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
        NSScreen.main?.visibleFrame
            ?? frontmostWindowScreenFrame()
            ?? screenContainingMouse()?.visibleFrame
            ?? panel.screen?.visibleFrame
            ?? .zero
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

private extension NSRect {
    func nearlyEquals(_ other: NSRect) -> Bool {
        abs(origin.x - other.origin.x) < 1 &&
        abs(origin.y - other.origin.y) < 1 &&
        abs(size.width - other.size.width) < 1 &&
        abs(size.height - other.size.height) < 1
    }
}
