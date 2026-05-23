import AppKit
import SwiftUI

struct ShotPreviewView: View {
    let shot: Shot
    let canGoPrevious: Bool
    let canGoNext: Bool
    let onCopy: () -> Void
    let onImageChanged: (NSImage) -> Void
    let onImageReset: () -> Void
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onClose: () -> Void
    @State private var showCopiedToast = false
    @State private var activeTool: PreviewMarkupTool = .pen
    @State private var annotations: [PreviewAnnotation] = []
    @State private var draftAnnotation: PreviewAnnotation?
    @State private var textDraft: PreviewTextDraft?
    @State private var editedImage: NSImage?
    @State private var imageHistory: [NSImage] = []

    private var previewImage: NSImage {
        editedImage ?? shot.image
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(.black.opacity(0.72))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(.white.opacity(0.16), lineWidth: 0.5)
                )

            MarkupImageView(
                image: previewImage,
                annotations: annotations,
                draftAnnotation: draftAnnotation,
                textDraft: $textDraft,
                activeTool: activeTool,
                onDraftChanged: { draftAnnotation = $0 },
                onDraftFinished: { annotation in
                    applyAnnotationsAfterClearingDraft([annotation])
                },
                onTextFinished: { draft in
                    textDraft = nil
                    let text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return }
                    applyAnnotations([PreviewAnnotation(
                        tool: .text,
                        points: [draft.point],
                        text: text,
                        fontSize: draft.fontSize
                    )])
                }
            )
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
                        toolButton(.pen, systemName: "pencil.tip", help: "Pen")
                        toolButton(.arrow, systemName: "arrow.up.right", help: "Arrow")
                        toolButton(.text, systemName: "textformat", help: "Text")
                        iconButton(
                            systemName: "arrow.uturn.backward",
                            action: undoAnnotation,
                            help: "Undo",
                            isEnabled: !annotations.isEmpty || draftAnnotation != nil || textDraft != nil || !imageHistory.isEmpty
                        )
                        iconButton(
                            systemName: "trash",
                            action: clearAnnotations,
                            help: "Clear",
                            isEnabled: !annotations.isEmpty || draftAnnotation != nil || textDraft != nil || !imageHistory.isEmpty || shot.isEdited
                        )
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

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
        let visibleAnnotations = annotations
            + [draftAnnotation].compactMap { $0 }
            + [textDraft?.annotation].compactMap { $0 }

        if visibleAnnotations.isEmpty {
            onCopy()
        } else if let image = previewImage.renderedWithPreviewAnnotations(visibleAnnotations) {
            MultiFormatPasteboard.writeImageToClipboard(image, fallbackPath: shot.url)
        } else {
            onCopy()
        }
        withAnimation(.easeOut(duration: 0.12)) {
            showCopiedToast = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.15) {
            withAnimation(.easeIn(duration: 0.18)) {
                showCopiedToast = false
            }
        }
    }

    private func undoAnnotation() {
        if textDraft != nil {
            textDraft = nil
            return
        }
        if draftAnnotation != nil {
            draftAnnotation = nil
            return
        }
        if !annotations.isEmpty {
            _ = annotations.popLast()
            return
        }
        guard let previous = imageHistory.popLast() else { return }
        editedImage = previous
        onImageChanged(previous)
    }

    private func clearAnnotations() {
        draftAnnotation = nil
        textDraft = nil
        annotations.removeAll()
        guard shot.isEdited || !imageHistory.isEmpty else { return }
        imageHistory.removeAll()
        editedImage = shot.originalImage
        onImageReset()
    }

    private func toolButton(_ tool: PreviewMarkupTool, systemName: String, help: String) -> some View {
        Button(action: {
            commitTextDraft()
            activeTool = tool
        }) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .background(activeTool == tool ? Color.accentColor.opacity(0.9) : .black.opacity(0.58), in: Circle())
        .help(help)
    }

    private func commitTextDraft() {
        guard let draft = textDraft else { return }
        textDraft = nil
        let text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        applyAnnotations([PreviewAnnotation(
            tool: .text,
            points: [draft.point],
            text: text,
            fontSize: draft.fontSize
        )])
    }

    private func applyAnnotationsAfterClearingDraft(_ newAnnotations: [PreviewAnnotation]) {
        draftAnnotation = nil
        DispatchQueue.main.async {
            applyAnnotations(newAnnotations)
        }
    }

    private func applyAnnotations(_ newAnnotations: [PreviewAnnotation]) {
        guard let image = previewImage.renderedWithPreviewAnnotations(newAnnotations) else { return }
        imageHistory.append(previewImage)
        editedImage = image
        annotations.removeAll()
        draftAnnotation = nil
        textDraft = nil
        onImageChanged(image)
    }

    private func iconButton(
        systemName: String,
        action: @escaping () -> Void,
        help: String,
        isEnabled: Bool = true
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(isEnabled ? 1 : 0.35))
        .background(.black.opacity(isEnabled ? 0.58 : 0.24), in: Circle())
        .disabled(!isEnabled)
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

private enum PreviewMarkupTool {
    case pen
    case arrow
    case text
}

private struct PreviewAnnotation: Identifiable {
    let id = UUID()
    let tool: PreviewMarkupTool
    let points: [CGPoint]
    let text: String
    let lineWidth: CGFloat
    let fontSize: CGFloat

    init(
        tool: PreviewMarkupTool,
        points: [CGPoint],
        text: String = "",
        lineWidth: CGFloat = 0,
        fontSize: CGFloat = 0
    ) {
        self.tool = tool
        self.points = points
        self.text = text
        self.lineWidth = lineWidth
        self.fontSize = fontSize
    }
}

private struct PreviewTextDraft {
    var point: CGPoint
    var text: String
    var fontSize: CGFloat

    var annotation: PreviewAnnotation? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return PreviewAnnotation(tool: .text, points: [point], text: trimmed, fontSize: fontSize)
    }
}

private enum PreviewMarkupStyle {
    static func lineWidth(for size: CGSize) -> CGFloat {
        max(3, min(size.width, size.height) * 0.006)
    }

    static func imageLineWidth(imageSize: CGSize, imageRect: CGRect) -> CGFloat {
        lineWidth(for: imageRect.size) / max(imageRect.width / max(imageSize.width, 1), 0.0001)
    }

    static func arrowHeadLength(lineWidth: CGFloat) -> CGFloat {
        max(16, lineWidth * 5)
    }

    static func textFontSize(for size: CGSize) -> CGFloat {
        max(15, min(size.width, size.height) * 0.038)
    }

    static func imageTextFontSize(imageSize: CGSize, imageRect: CGRect) -> CGFloat {
        textFontSize(for: imageRect.size) / max(imageRect.width / max(imageSize.width, 1), 0.0001)
    }
}

private struct MarkupImageView: View {
    let image: NSImage
    let annotations: [PreviewAnnotation]
    let draftAnnotation: PreviewAnnotation?
    @Binding var textDraft: PreviewTextDraft?
    let activeTool: PreviewMarkupTool
    let onDraftChanged: (PreviewAnnotation?) -> Void
    let onDraftFinished: (PreviewAnnotation) -> Void
    let onTextFinished: (PreviewTextDraft) -> Void
    @FocusState private var textFieldFocused: Bool

    var body: some View {
        GeometryReader { proxy in
            let imageRect = fittedImageRect(imageSize: image.size, containerSize: proxy.size)
            ZStack(alignment: .topLeading) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: proxy.size.width, height: proxy.size.height)

                Canvas { context, _ in
                    for annotation in annotations {
                        draw(annotation, in: &context, imageRect: imageRect, imageSize: image.size)
                    }
                    if let draftAnnotation {
                        draw(draftAnnotation, in: &context, imageRect: imageRect, imageSize: image.size)
                    }
                    if let annotation = textDraft?.annotation {
                        draw(annotation, in: &context, imageRect: imageRect, imageSize: image.size)
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)

                if let draft = textDraft {
                    textInput(draft: draft, imageRect: imageRect, imageSize: image.size)
                }
            }
            .contentShape(Rectangle())
            .gesture(markupGesture(imageRect: imageRect, imageSize: image.size))
            .onChange(of: textDraft?.point) { _ in
                textFieldFocused = textDraft != nil
            }
        }
    }

    private func textInput(draft: PreviewTextDraft, imageRect: CGRect, imageSize: CGSize) -> some View {
        let point = viewPoint(from: draft.point, imageRect: imageRect, imageSize: imageSize)
        return HStack(spacing: 6) {
            TextField("", text: Binding(
                get: { textDraft?.text ?? "" },
                set: { textDraft?.text = $0 }
            ))
            .textFieldStyle(.plain)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .focused($textFieldFocused)
            .onSubmit { finishTextDraft() }
            .frame(width: 170)

            Button(action: finishTextDraft) {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .background(Color.accentColor.opacity(0.9), in: Circle())
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(.white.opacity(0.18), lineWidth: 0.5)
        )
        .position(x: min(max(point.x + 96, imageRect.minX + 104), imageRect.maxX - 104),
                  y: min(max(point.y - 22, imageRect.minY + 18), imageRect.maxY - 18))
        .onAppear { textFieldFocused = true }
    }

    private func markupGesture(imageRect: CGRect, imageSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard activeTool != .text else { return }
                guard let point = imagePoint(from: value.location, imageRect: imageRect, imageSize: imageSize) else {
                    return
                }

                switch activeTool {
                case .pen:
                    var points = draftAnnotation?.points ?? []
                    if points.isEmpty || points.last.map({ distance($0, point) > 1.5 }) == true {
                        points.append(point)
                    }
                    onDraftChanged(PreviewAnnotation(
                        tool: .pen,
                        points: points,
                        lineWidth: PreviewMarkupStyle.imageLineWidth(imageSize: imageSize, imageRect: imageRect)
                    ))
                case .arrow:
                    guard let start = imagePoint(from: value.startLocation, imageRect: imageRect, imageSize: imageSize) else {
                        return
                    }
                    onDraftChanged(PreviewAnnotation(
                        tool: .arrow,
                        points: [start, point],
                        lineWidth: PreviewMarkupStyle.imageLineWidth(imageSize: imageSize, imageRect: imageRect)
                    ))
                case .text:
                    break
                }
            }
            .onEnded { value in
                if activeTool == .text {
                    guard distance(value.startLocation, value.location) < 6,
                          let point = imagePoint(from: value.location, imageRect: imageRect, imageSize: imageSize)
                    else { return }
                    finishTextDraft()
                    textDraft = PreviewTextDraft(
                        point: point,
                        text: "",
                        fontSize: PreviewMarkupStyle.imageTextFontSize(imageSize: imageSize, imageRect: imageRect)
                    )
                    textFieldFocused = true
                    return
                }

                guard let draft = draftAnnotation else { return }
                let annotation: PreviewAnnotation
                if activeTool == .arrow,
                   let end = imagePoint(from: value.location, imageRect: imageRect, imageSize: imageSize),
                   let start = draft.points.first {
                    annotation = PreviewAnnotation(
                        tool: .arrow,
                        points: [start, end],
                        lineWidth: draft.lineWidth
                    )
                } else {
                    annotation = draft
                }
                guard annotation.points.count >= 2 else {
                    onDraftChanged(nil)
                    return
                }
                onDraftFinished(annotation)
            }
    }

    private func finishTextDraft() {
        guard let draft = textDraft else { return }
        onTextFinished(draft)
    }

    private func fittedImageRect(imageSize: CGSize, containerSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, containerSize.width > 0, containerSize.height > 0 else {
            return .zero
        }
        let scale = min(containerSize.width / imageSize.width, containerSize.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: (containerSize.width - size.width) / 2,
            y: (containerSize.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    private func imagePoint(from location: CGPoint, imageRect: CGRect, imageSize: CGSize) -> CGPoint? {
        guard imageRect.contains(location), imageRect.width > 0, imageRect.height > 0 else { return nil }
        return CGPoint(
            x: (location.x - imageRect.minX) / imageRect.width * imageSize.width,
            y: (location.y - imageRect.minY) / imageRect.height * imageSize.height
        )
    }

    private func viewPoint(from imagePoint: CGPoint, imageRect: CGRect, imageSize: CGSize) -> CGPoint {
        CGPoint(
            x: imageRect.minX + imagePoint.x / max(imageSize.width, 1) * imageRect.width,
            y: imageRect.minY + imagePoint.y / max(imageSize.height, 1) * imageRect.height
        )
    }

    private func viewScale(imageRect: CGRect, imageSize: CGSize) -> CGFloat {
        imageRect.width / max(imageSize.width, 1)
    }

    private func draw(_ annotation: PreviewAnnotation, in context: inout GraphicsContext, imageRect: CGRect, imageSize: CGSize) {
        let points = annotation.points.map { viewPoint(from: $0, imageRect: imageRect, imageSize: imageSize) }
        let scale = viewScale(imageRect: imageRect, imageSize: imageSize)
        if annotation.tool == .text, let point = points.first {
            let fontSize = annotation.fontSize > 0
                ? annotation.fontSize * scale
                : PreviewMarkupStyle.textFontSize(for: imageRect.size)
            context.draw(
                Text(annotation.text)
                    .font(.system(size: fontSize, weight: .bold))
                    .foregroundColor(.red),
                at: point,
                anchor: .topLeading
            )
            return
        }

        guard points.count >= 2 else { return }

        var path = Path()
        path.move(to: points[0])
        for point in points.dropFirst() {
            path.addLine(to: point)
        }

        let lineWidth = annotation.lineWidth > 0
            ? annotation.lineWidth * scale
            : PreviewMarkupStyle.lineWidth(for: imageRect.size)
        context.stroke(path, with: .color(.red), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))

        if annotation.tool == .arrow, let start = points.first, let end = points.last {
            drawArrowHead(from: start, to: end, in: &context, lineWidth: lineWidth)
        }
    }

    private func drawArrowHead(from start: CGPoint, to end: CGPoint, in context: inout GraphicsContext, lineWidth: CGFloat) {
        let angle = atan2(end.y - start.y, end.x - start.x)
        let length = PreviewMarkupStyle.arrowHeadLength(lineWidth: lineWidth)
        let spread = CGFloat.pi / 7
        let p1 = CGPoint(x: end.x - cos(angle - spread) * length, y: end.y - sin(angle - spread) * length)
        let p2 = CGPoint(x: end.x - cos(angle + spread) * length, y: end.y - sin(angle + spread) * length)

        var head = Path()
        head.move(to: p1)
        head.addLine(to: end)
        head.addLine(to: p2)
        context.stroke(head, with: .color(.red), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
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

private extension NSImage {
    func renderedWithPreviewAnnotations(_ annotations: [PreviewAnnotation]) -> NSImage? {
        guard !annotations.isEmpty else { return self }

        var proposedRect = NSRect(origin: .zero, size: size)
        guard let cgImage = cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) else { return nil }
        let pixelSize = CGSize(width: cgImage.width, height: cgImage.height)
        let colorSpace = cgImage.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let cgContext = CGContext(
            data: nil,
            width: cgImage.width,
            height: cgImage.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return nil }

        cgContext.interpolationQuality = .none
        cgContext.draw(cgImage, in: CGRect(origin: .zero, size: pixelSize))
        for annotation in annotations {
            annotation.drawInPixelContext(cgContext, logicalSize: size, pixelSize: pixelSize)
        }

        guard let rendered = cgContext.makeImage() else { return nil }
        return NSImage(cgImage: rendered, size: size)
    }
}

private extension PreviewAnnotation {
    func drawInPixelContext(_ context: CGContext, logicalSize: CGSize, pixelSize: CGSize) {
        let scaleX = pixelSize.width / max(logicalSize.width, 1)
        let scaleY = pixelSize.height / max(logicalSize.height, 1)
        let scale = (scaleX + scaleY) / 2
        let convertedPoints = points.map {
            CGPoint(x: $0.x * scaleX, y: pixelSize.height - ($0.y * scaleY))
        }

        context.saveGState()
        context.setStrokeColor(NSColor.systemRed.cgColor)
        context.setFillColor(NSColor.systemRed.cgColor)

        if tool == .text, let point = convertedPoints.first {
            let fontSize = (self.fontSize > 0 ? self.fontSize : PreviewMarkupStyle.textFontSize(for: logicalSize)) * scale
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
                .foregroundColor: NSColor.systemRed,
                .strokeColor: NSColor.white.withAlphaComponent(0.55),
                .strokeWidth: -2.0,
            ]
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            NSAttributedString(string: text, attributes: attrs).draw(at: point)
            NSGraphicsContext.restoreGraphicsState()
            context.restoreGState()
            return
        }

        guard convertedPoints.count >= 2 else {
            context.restoreGState()
            return
        }

        context.setLineWidth((self.lineWidth > 0 ? self.lineWidth : PreviewMarkupStyle.lineWidth(for: logicalSize)) * scale)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.beginPath()
        context.move(to: convertedPoints[0])
        for point in convertedPoints.dropFirst() {
            context.addLine(to: point)
        }
        context.strokePath()

        if tool == .arrow, let start = convertedPoints.first, let end = convertedPoints.last {
            drawArrowHead(from: start, to: end, lineWidth: (self.lineWidth > 0 ? self.lineWidth : PreviewMarkupStyle.lineWidth(for: logicalSize)) * scale, in: context)
        }

        context.restoreGState()
    }

    private func drawArrowHead(from start: CGPoint, to end: CGPoint, lineWidth: CGFloat, in context: CGContext) {
        let angle = atan2(end.y - start.y, end.x - start.x)
        let length = PreviewMarkupStyle.arrowHeadLength(lineWidth: lineWidth)
        let spread = CGFloat.pi / 7
        let p1 = CGPoint(x: end.x - cos(angle - spread) * length, y: end.y - sin(angle - spread) * length)
        let p2 = CGPoint(x: end.x - cos(angle + spread) * length, y: end.y - sin(angle + spread) * length)

        context.setLineWidth(lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.beginPath()
        context.move(to: p1)
        context.addLine(to: end)
        context.addLine(to: p2)
        context.strokePath()
    }
}
