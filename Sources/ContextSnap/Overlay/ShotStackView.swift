import AppKit
import SwiftUI

struct ShotStackView: View {
    @ObservedObject var model: ShotStack
    let onPreview: (Shot) -> Void
    let onLayoutChange: () -> Void
    @State private var isCollapsed = false

    private func requestLayoutUpdate() {
        DispatchQueue.main.async {
            onLayoutChange()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            onLayoutChange()
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            StackHeader(
                count: model.shots.count,
                isCollapsed: isCollapsed,
                onToggle: {
                    isCollapsed.toggle()
                    requestLayoutUpdate()
                }
            )
                .frame(height: 22)
            if !isCollapsed {
                ForEach(model.shots.reversed()) { shot in
                    ShotTileView(
                        shot: shot,
                        isSelected: model.selectedID == shot.id,
                        onSelect: { model.selectedID = shot.id },
                        onPreview: { onPreview(shot) },
                        onClose: { model.remove(shot) }
                    )
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .top)
        .animation(.easeInOut(duration: 0.18), value: model.shots.count)
        .animation(.easeInOut(duration: 0.18), value: isCollapsed)
        .onChange(of: model.shots.count) { _ in
            requestLayoutUpdate()
        }
    }
}

private struct StackHeader: View {
    let count: Int
    let isCollapsed: Bool
    let onToggle: () -> Void

    var body: some View {
        ZStack {
            DragHandle()

            HStack(spacing: 6) {
                if isCollapsed {
                    Text("\(count)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.86))
                        .frame(minWidth: 18, minHeight: 18)
                        .background(.black.opacity(0.38), in: Capsule())
                }

                Spacer()

                Button(action: onToggle) {
                    Image(systemName: isCollapsed ? "chevron.down" : "chevron.up")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.9))
                .background(.black.opacity(0.35), in: Circle())
                .help(isCollapsed ? "Expand stack" : "Collapse stack")
            }
            .padding(.horizontal, 4)
        }
    }
}

/// A slim pill at the top of the panel — the only region that drags the
/// window. Lets tile clicks/drags flow to their own handlers without the
/// background-drag fighting them.
private struct DragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragHandleView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class DragHandleView: NSView {
    private var trackingArea: NSTrackingArea?
    private var insideCursor = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        NSCursor.closedHand.set()
        // Reliable for non-activating panels where mouseDownCanMoveWindow
        // sometimes gets swallowed on the first click.
        window?.performDrag(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        (insideCursor ? NSCursor.openHand : NSCursor.arrow).set()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let old = trackingArea { removeTrackingArea(old) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        insideCursor = true
        NSCursor.openHand.set()
    }

    override func mouseExited(with event: NSEvent) {
        insideCursor = false
        NSCursor.arrow.set()
    }

    override func draw(_ dirtyRect: NSRect) {
        // Dark translucent header capsule
        let bg = NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8)
        NSColor.black.withAlphaComponent(0.55).setFill()
        bg.fill()
        NSColor.white.withAlphaComponent(0.12).setStroke()
        bg.lineWidth = 0.5
        bg.stroke()

        // 6-dot grip (3 columns × 2 rows) — universal drag affordance.
        let dotSize: CGFloat = 3
        let spacing: CGFloat = 5
        let cols = 3
        let rows = 2
        let totalW = CGFloat(cols) * dotSize + CGFloat(cols - 1) * spacing
        let totalH = CGFloat(rows) * dotSize + CGFloat(rows - 1) * spacing
        let originX = (bounds.width - totalW) / 2
        let originY = (bounds.height - totalH) / 2
        NSColor.white.withAlphaComponent(0.75).setFill()
        for r in 0..<rows {
            for c in 0..<cols {
                let dot = NSRect(
                    x: originX + CGFloat(c) * (dotSize + spacing),
                    y: originY + CGFloat(r) * (dotSize + spacing),
                    width: dotSize, height: dotSize
                )
                NSBezierPath(ovalIn: dot).fill()
            }
        }
    }
}
