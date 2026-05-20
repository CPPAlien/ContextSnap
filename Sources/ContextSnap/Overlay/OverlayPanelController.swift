import AppKit
import Combine
import SwiftUI

@MainActor
final class OverlayPanelController {
    private let panel: NSPanel
    private let host: NSHostingView<ShotStackView>
    let model = ShotStack()
    private var cancellables: Set<AnyCancellable> = []

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
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
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
    }

    func add(_ shot: Shot) {
        model.append(shot)
        if SettingsStore.shared.showStack {
            if !panel.isVisible {
                panel.orderFrontRegardless()
            }
            DispatchQueue.main.async { [weak self] in
                self?.resizeToFit()
            }
        } else if panel.isVisible {
            panel.orderOut(nil)
        }
    }

    func clear() {
        model.clear()
        panel.orderOut(nil)
    }

    func applyVisibility() {
        let shouldShow = SettingsStore.shared.showStack && !model.shots.isEmpty
        if shouldShow {
            if !panel.isVisible { panel.orderFrontRegardless() }
            DispatchQueue.main.async { [weak self] in self?.resizeToFit() }
        } else if panel.isVisible {
            panel.orderOut(nil)
        }
    }

    private func resizeToFit() {
        let fitting = host.fittingSize
        let height = max(fitting.height, 80)
        let screen = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let newFrame = NSRect(
            x: screen.maxX - Self.panelWidth - Self.edgeInset,
            y: screen.maxY - height - Self.edgeInset,
            width: Self.panelWidth,
            height: height
        )
        panel.setFrame(newFrame, display: true, animate: false)
    }
}
