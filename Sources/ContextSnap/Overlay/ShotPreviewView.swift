import AppKit
import SwiftUI

struct ShotPreviewView: View {
    let shot: Shot
    let canGoPrevious: Bool
    let canGoNext: Bool
    let onCopy: () -> Void
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onClose: () -> Void
    @State private var showCopiedToast = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(.black.opacity(0.72))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(.white.opacity(0.16), lineWidth: 0.5)
                )

            Image(nsImage: shot.image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .padding(14)

            HStack {
                navigationButton(
                    systemName: "chevron.left",
                    action: onPrevious,
                    isEnabled: canGoPrevious,
                    help: "Previous"
                )

                Spacer()

                navigationButton(
                    systemName: "chevron.right",
                    action: onNext,
                    isEnabled: canGoNext,
                    help: "Next"
                )
            }
            .padding(.horizontal, 14)

            VStack {
                ZStack {
                    PreviewDragHandle()
                        .frame(width: 74, height: 24)

                    HStack(spacing: 8) {
                        iconButton(systemName: "doc.on.doc.fill", action: copyWithToast, help: "Copy")
                        iconButton(systemName: "xmark", action: onClose, help: "Close")
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }

                Spacer()
            }
            .padding(12)

            if showCopiedToast {
                Text("Copied")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.72), in: Capsule())
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .padding(1)
    }

    private func copyWithToast() {
        onCopy()
        withAnimation(.easeOut(duration: 0.12)) {
            showCopiedToast = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.15) {
            withAnimation(.easeIn(duration: 0.18)) {
                showCopiedToast = false
            }
        }
    }

    private func iconButton(systemName: String, action: @escaping () -> Void, help: String) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .background(.black.opacity(0.58), in: Circle())
        .help(help)
    }

    private func navigationButton(
        systemName: String,
        action: @escaping () -> Void,
        isEnabled: Bool,
        help: String
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 22, weight: .bold))
                .frame(width: 38, height: 56)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(isEnabled ? 0.96 : 0.28))
        .background(.black.opacity(isEnabled ? 0.42 : 0.18), in: Capsule())
        .disabled(!isEnabled)
        .help(help)
    }
}

private struct PreviewDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { PreviewDragHandleView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class PreviewDragHandleView: NSView {
    private var trackingArea: NSTrackingArea?
    private var insideCursor = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        NSCursor.closedHand.set()
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
        let bg = NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10)
        NSColor.black.withAlphaComponent(0.46).setFill()
        bg.fill()
        NSColor.white.withAlphaComponent(0.16).setStroke()
        bg.lineWidth = 0.5
        bg.stroke()

        let dotSize: CGFloat = 3
        let spacing: CGFloat = 5
        let cols = 3
        let rows = 2
        let totalW = CGFloat(cols) * dotSize + CGFloat(cols - 1) * spacing
        let totalH = CGFloat(rows) * dotSize + CGFloat(rows - 1) * spacing
        let originX = (bounds.width - totalW) / 2
        let originY = (bounds.height - totalH) / 2
        NSColor.white.withAlphaComponent(0.78).setFill()

        for r in 0..<rows {
            for c in 0..<cols {
                let dot = NSRect(
                    x: originX + CGFloat(c) * (dotSize + spacing),
                    y: originY + CGFloat(r) * (dotSize + spacing),
                    width: dotSize,
                    height: dotSize
                )
                NSBezierPath(ovalIn: dot).fill()
            }
        }
    }
}
