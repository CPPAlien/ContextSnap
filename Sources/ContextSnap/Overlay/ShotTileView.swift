import SwiftUI

struct ShotTileView: View {
    let shot: Shot
    let isSelected: Bool
    let onSelect: () -> Void
    let onPreview: () -> Void
    let onClose: () -> Void
    @State private var hovering = false
    @State private var longPressPreviewed = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Image(nsImage: shot.image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 156, maxHeight: 156)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(.white.opacity(0.18), lineWidth: 0.5)
                )
                .overlay(
                    CornerBrackets()
                        .stroke(Color.white, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                        .padding(-3)
                        .opacity(isSelected ? 1 : 0)
                        .animation(.easeInOut(duration: 0.12), value: isSelected)
                )
                .shadow(
                    color: isSelected ? .black.opacity(0.55) : .black.opacity(0.35),
                    radius: isSelected ? 10 : 8,
                    x: 0,
                    y: 2
                )
                .onDrag {
                    onSelect()
                    return MultiFormatPasteboard.makeItemProvider(for: shot)
                }
                .onTapGesture {
                    guard !longPressPreviewed else {
                        longPressPreviewed = false
                        return
                    }
                    if isSelected {
                        onPreview()
                        return
                    }
                    onSelect()
                    MultiFormatPasteboard.writeToClipboard(shot)
                }
                .onLongPressGesture(minimumDuration: 2) {
                    longPressPreviewed = true
                    onSelect()
                    onPreview()
                }

            if hovering {
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.7))
                        .font(.system(size: 18, weight: .bold))
                }
                .buttonStyle(.plain)
                .padding(6)
                .transition(.opacity)
            }
        }
        .onHover { hovering = $0 }
        .help("Drag to attach · Click to copy · Click selected item or hold 2s to preview · Hover ✕ to remove")
    }
}

private struct CornerBrackets: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let len = min(rect.width, rect.height) * 0.22
        let cap = max(14, min(len, 28))
        // Top-left
        p.move(to: CGPoint(x: rect.minX, y: rect.minY + cap))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + cap, y: rect.minY))
        // Top-right
        p.move(to: CGPoint(x: rect.maxX - cap, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + cap))
        // Bottom-left
        p.move(to: CGPoint(x: rect.minX, y: rect.maxY - cap))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX + cap, y: rect.maxY))
        // Bottom-right
        p.move(to: CGPoint(x: rect.maxX - cap, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - cap))
        return p
    }
}
