import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Append a line to ~/Library/Logs/ContextSnap.log. Unified logging swallows
/// output from this app for unclear reasons, so we keep a file we can tail
/// directly when triaging drag/drop issues.
private func snapLog(_ message: String) {
    NSLog("[ContextSnap] %@", message)
    let url = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Logs/ContextSnap.log")
    let line = "[\(Date())] \(message)\n"
    guard let data = line.data(using: .utf8) else { return }
    if let handle = try? FileHandle(forWritingTo: url) {
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    } else {
        try? data.write(to: url)
    }
}

struct ShotStackView: View {
    @ObservedObject var model: ShotStack
    let onPreview: (Shot) -> Void
    let onLayoutChange: () -> Void
    let onCaptureRequested: () -> Void
    let onImport: (NSImage) -> Void
    @State private var isCollapsed = false
    @State private var isDropTargeted = false

    private func requestLayoutUpdate() {
        DispatchQueue.main.async {
            onLayoutChange()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            onLayoutChange()
        }
    }

    var body: some View {
        Group {
            if model.shots.isEmpty {
                PersistentIconView(onCaptureRequested: onCaptureRequested)
                    .padding(10)
            } else {
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
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .overlay(alignment: .trailing) {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .background(
            // AppKit-level drop target. SwiftUI's .onDrop re-wraps providers
            // in a way that severs Chrome's lazy data provider, so we read
            // the original draggingPasteboard ourselves.
            DropCatcher(
                isTargeted: $isDropTargeted,
                onImport: onImport
            )
        )
        .animation(.easeInOut(duration: 0.18), value: model.shots.count)
        .animation(.easeInOut(duration: 0.18), value: isCollapsed)
        .animation(.easeInOut(duration: 0.12), value: isDropTargeted)
        .onChange(of: model.shots.count) { _ in
            requestLayoutUpdate()
        }
    }

}

// MARK: - AppKit drop catcher

/// Transparent NSView overlay that registers as an NSDraggingDestination and
/// reads directly from `sender.draggingPasteboard`. Bypassing SwiftUI's
/// `.onDrop` is necessary because that path re-wraps providers and severs
/// Chrome's lazy `public.png` data provider — by the time the rewrapped
/// NSItemProvider's load methods run, the source app's promise is gone.
private struct DropCatcher: NSViewRepresentable {
    @Binding var isTargeted: Bool
    let onImport: (NSImage) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = DropCatcherView()
        view.onTargetedChange = { targeted in
            DispatchQueue.main.async { isTargeted = targeted }
        }
        view.onImport = onImport
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let view = nsView as? DropCatcherView {
            view.onTargetedChange = { targeted in
                DispatchQueue.main.async { isTargeted = targeted }
            }
            view.onImport = onImport
        }
    }
}

private final class DropCatcherView: NSView {
    var onTargetedChange: ((Bool) -> Void)?
    var onImport: ((NSImage) -> Void)?

    private static let acceptedTypes: [NSPasteboard.PasteboardType] = [
        .png, .tiff, .fileURL, .URL, .string,
        NSPasteboard.PasteboardType("public.jpeg"),
        NSPasteboard.PasteboardType("public.heic"),
        NSPasteboard.PasteboardType("public.webp"),
        NSPasteboard.PasteboardType("com.compuserve.gif"),
        NSPasteboard.PasteboardType("public.image"),
    ]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes(Self.acceptedTypes)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes(Self.acceptedTypes)
    }

    // Transparent — let clicks and mouse events pass through to siblings.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let pb = sender.draggingPasteboard
        snapLog("dragEnter types: \(pb.types?.map(\.rawValue) ?? [])")
        guard hasUsablePayload(pb) else { return [] }
        onTargetedChange?(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        hasUsablePayload(sender.draggingPasteboard) ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onTargetedChange?(false)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        onTargetedChange?(false)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        hasUsablePayload(sender.draggingPasteboard)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        snapLog("performDrag types: \(pb.types?.map(\.rawValue) ?? [])")
        return handle(pasteboard: pb)
    }

    private func hasUsablePayload(_ pb: NSPasteboard) -> Bool {
        guard let types = pb.types else { return false }
        let usable: Set<String> = [
            "public.png", "public.jpeg", "public.tiff", "public.heic",
            "public.webp", "com.compuserve.gif", "public.image",
            "public.file-url", "public.url", "public.utf8-plain-text",
            "public.plain-text", "public.text",
        ]
        return types.contains { usable.contains($0.rawValue) }
    }

    /// Read image bytes / file / URL straight off the pasteboard. We
    /// intentionally use NSPasteboard rather than NSItemProvider so the
    /// source app's lazy data providers are still bound to fulfill.
    private func handle(pasteboard pb: NSPasteboard) -> Bool {
        let imageTypes = ["public.png", "public.jpeg", "public.tiff", "public.heic",
                          "public.webp", "com.compuserve.gif", "public.image"]
        for raw in imageTypes {
            let type = NSPasteboard.PasteboardType(raw)
            if let data = pb.data(forType: type), let image = NSImage(data: data) {
                snapLog("imported via pasteboard \(raw) (\(data.count) bytes)")
                deliver(image)
                return true
            }
        }

        if let url = readFileURL(pb), let image = NSImage(contentsOf: url) {
            snapLog("imported via file URL \(url.path)")
            deliver(image)
            return true
        }

        if let url = readWebURL(pb) {
            snapLog("fetching dropped URL: \(url)")
            fetchImage(from: url)
            return true
        }

        snapLog("drop pasteboard had no usable payload")
        return false
    }

    private func readFileURL(_ pb: NSPasteboard) -> URL? {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let url = urls.first {
            return url
        }
        if let str = pb.string(forType: .fileURL), let url = URL(string: str), url.isFileURL {
            return url
        }
        return nil
    }

    private func readWebURL(_ pb: NSPasteboard) -> URL? {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           let url = urls.first(where: { $0.scheme == "http" || $0.scheme == "https" }) {
            return url
        }
        if let str = pb.string(forType: .URL),
           let url = URL(string: str.trimmingCharacters(in: .whitespacesAndNewlines)),
           url.scheme == "http" || url.scheme == "https" {
            return url
        }
        if let str = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
           let url = URL(string: str),
           url.scheme == "http" || url.scheme == "https" {
            return url
        }
        return nil
    }

    private func fetchImage(from url: URL) {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            if let error { snapLog("fetch error: \(error.localizedDescription)") }
            if let http = response as? HTTPURLResponse { snapLog("fetch status: \(http.statusCode), bytes=\(data?.count ?? -1)") }
            guard let data, let image = NSImage(data: data) else {
                snapLog("fetch produced no usable image")
                return
            }
            self?.deliver(image)
        }.resume()
    }

    private func deliver(_ image: NSImage) {
        let handler = onImport
        DispatchQueue.main.async { handler?(image) }
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

struct PersistentIconView: View {
    let onCaptureRequested: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            DraggableClickArea(onClick: onCaptureRequested) {
                PersistentIconShape()
                    .frame(width: 44, height: 44)
                    .scaleEffect(isHovering ? 1.06 : 1.0)
                    .animation(.easeOut(duration: 0.12), value: isHovering)
            }
            .onHover { isHovering = $0 }
            .help("Click to capture · drag to move")
            .frame(width: 44, height: 44)
        }
    }
}

/// Wraps content so a short click triggers `onClick` while a drag past the
/// system threshold moves the host window. Lets the floating icon serve
/// double duty as both button and drag handle.
private struct DraggableClickArea<Content: View>: NSViewRepresentable {
    let onClick: () -> Void
    @ViewBuilder let content: () -> Content

    func makeNSView(context: Context) -> NSView {
        let host = NSHostingView(rootView: content())
        host.translatesAutoresizingMaskIntoConstraints = false
        let container = ClickOrDragView()
        container.onClick = onClick
        container.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            host.topAnchor.constraint(equalTo: container.topAnchor),
            host.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let container = nsView as? ClickOrDragView {
            container.onClick = onClick
        }
        if let host = nsView.subviews.first as? NSHostingView<Content> {
            host.rootView = content()
        }
    }
}

private final class ClickOrDragView: NSView {
    var onClick: (() -> Void)?
    private var downLocation: NSPoint = .zero
    private var dragged = false
    private let dragThreshold: CGFloat = 4

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        downLocation = event.locationInWindow
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dragged else { return }
        let dx = event.locationInWindow.x - downLocation.x
        let dy = event.locationInWindow.y - downLocation.y
        if dx * dx + dy * dy > dragThreshold * dragThreshold {
            dragged = true
            NSCursor.closedHand.set()
            window?.performDrag(with: event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        NSCursor.openHand.set()
        if !dragged { onClick?() }
    }
}

/// Logo-inspired floating glyph: gradient squircle, stacked cards, viewfinder
/// brackets. Visually echoes the app icon but smaller and slightly simplified.
private struct PersistentIconShape: View {
    var body: some View {
        Canvas { context, size in
            let s = min(size.width, size.height)
            let rect = CGRect(x: (size.width - s) / 2, y: (size.height - s) / 2, width: s, height: s)
            let radius = s * 0.2237

            // Gradient squircle background (matches app icon palette).
            let bgPath = Path(roundedRect: rect, cornerRadius: radius)
            context.fill(
                bgPath,
                with: .linearGradient(
                    Gradient(colors: [
                        Color(red: 0.31, green: 0.55, blue: 1.00),
                        Color(red: 0.48, green: 0.36, blue: 1.00),
                    ]),
                    startPoint: CGPoint(x: rect.minX, y: rect.maxY),
                    endPoint: CGPoint(x: rect.maxX, y: rect.minY)
                )
            )

            // Drop a soft outer shadow via stroke for definition on busy desktops.
            context.stroke(bgPath, with: .color(.black.opacity(0.18)), lineWidth: 0.5)

            // Two stacked cards, tilted like the app icon.
            let cardSize = s * 0.44
            let cardRadius = cardSize * 0.14
            let center = CGPoint(x: rect.midX, y: rect.midY)

            func cardPath(rotation: CGFloat) -> Path {
                let transform = CGAffineTransform.identity
                    .translatedBy(x: center.x, y: center.y)
                    .rotated(by: rotation)
                    .translatedBy(x: -cardSize / 2, y: -cardSize / 2)
                let base = Path(roundedRect: CGRect(x: 0, y: 0, width: cardSize, height: cardSize),
                                cornerRadius: cardRadius)
                return base.applying(transform)
            }
            context.fill(cardPath(rotation: 0.20), with: .color(.white.opacity(0.55)))
            context.fill(cardPath(rotation: -0.08), with: .color(.white))

            // Viewfinder corner brackets.
            let bracketLength = s * 0.16
            let bracketWidth = s * 0.05
            let bracketInset = s * 0.115
            let outer = CGRect(
                x: rect.minX + bracketInset,
                y: rect.minY + bracketInset,
                width: rect.width - 2 * bracketInset,
                height: rect.height - 2 * bracketInset
            )
            var brackets = Path()
            // Top-left
            brackets.move(to: CGPoint(x: outer.minX, y: outer.minY + bracketLength))
            brackets.addLine(to: CGPoint(x: outer.minX, y: outer.minY))
            brackets.addLine(to: CGPoint(x: outer.minX + bracketLength, y: outer.minY))
            // Top-right
            brackets.move(to: CGPoint(x: outer.maxX - bracketLength, y: outer.minY))
            brackets.addLine(to: CGPoint(x: outer.maxX, y: outer.minY))
            brackets.addLine(to: CGPoint(x: outer.maxX, y: outer.minY + bracketLength))
            // Bottom-left
            brackets.move(to: CGPoint(x: outer.minX, y: outer.maxY - bracketLength))
            brackets.addLine(to: CGPoint(x: outer.minX, y: outer.maxY))
            brackets.addLine(to: CGPoint(x: outer.minX + bracketLength, y: outer.maxY))
            // Bottom-right
            brackets.move(to: CGPoint(x: outer.maxX - bracketLength, y: outer.maxY))
            brackets.addLine(to: CGPoint(x: outer.maxX, y: outer.maxY))
            brackets.addLine(to: CGPoint(x: outer.maxX, y: outer.maxY - bracketLength))
            context.stroke(
                brackets,
                with: .color(.white),
                style: StrokeStyle(lineWidth: bracketWidth, lineCap: .round, lineJoin: .round)
            )
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
