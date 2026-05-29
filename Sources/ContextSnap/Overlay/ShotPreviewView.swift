import AppKit
import SwiftUI

struct ShotPreviewView: View {
    @ObservedObject var model: ShotStack
    let shotID: Shot.ID
    let fallbackShot: Shot
    let canGoPrevious: Bool
    let canGoNext: Bool
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onClose: () -> Void
    @State private var showCopiedToast = false
    @State private var activeTool: AnnotationTool = .pen
    @State private var draftAnnotation: Annotation?
    @State private var editingTextID: UUID?

    private var shot: Shot { model.shots.first(where: { $0.id == shotID }) ?? fallbackShot }

    private var annotations: Binding<[Annotation]> {
        Binding(
            get: { shot.annotations },
            set: { model.updateAnnotations(for: shotID, $0) }
        )
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
                image: shot.image,
                annotations: annotations,
                draftAnnotation: draftAnnotation,
                editingTextID: $editingTextID,
                activeTool: activeTool,
                onDraftChanged: { draftAnnotation = $0 },
                onDraftFinished: { annotation in
                    appendAnnotation(annotation)
                    draftAnnotation = nil
                },
                onTextCreated: { annotation in
                    commitTextEditing()
                    appendAnnotation(annotation)
                    editingTextID = annotation.id
                },
                onEndEditing: { commitTextEditing() }
            )
            .padding(14)

            HStack {
                navigationButton(
                    systemName: "chevron.left",
                    action: { commitTextEditing(); onPrevious() },
                    isEnabled: canGoPrevious,
                    help: "Previous"
                )

                Spacer()

                navigationButton(
                    systemName: "chevron.right",
                    action: { commitTextEditing(); onNext() },
                    isEnabled: canGoNext,
                    help: "Next"
                )
            }
            .padding(.horizontal, 14)

            VStack(spacing: 6) {
                PreviewDragHandle()
                    .frame(width: 74, height: 18)

                ZStack {
                    HStack(spacing: 8) {
                        toolButton(.pen, systemName: "pencil.tip", help: "Pen")
                        toolButton(.arrow, systemName: "arrow.up.right", help: "Arrow")
                        toolButton(.text, systemName: "textformat", help: "Text")
                        iconButton(
                            systemName: "arrow.uturn.backward",
                            action: undoAnnotation,
                            help: "Undo",
                            isEnabled: !shot.annotations.isEmpty || draftAnnotation != nil
                        )
                        iconButton(
                            systemName: "trash",
                            action: clearAnnotations,
                            help: "Clear",
                            isEnabled: !shot.annotations.isEmpty || draftAnnotation != nil
                        )
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: 8) {
                        iconButton(systemName: "doc.on.doc.fill", action: copyWithToast, help: "Copy")
                        iconButton(systemName: "xmark", action: { commitTextEditing(); onClose() }, help: "Close")
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
        commitTextEditing()
        MultiFormatPasteboard.writeToClipboard(shot)
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
        if editingTextID != nil {
            commitTextEditing()
            return
        }
        if draftAnnotation != nil {
            draftAnnotation = nil
            return
        }
        var list = shot.annotations
        _ = list.popLast()
        model.updateAnnotations(for: shotID, list)
    }

    private func clearAnnotations() {
        draftAnnotation = nil
        editingTextID = nil
        model.updateAnnotations(for: shotID, [])
    }

    /// Drops any in-flight text editor; removes empty text annotations.
    private func commitTextEditing() {
        editingTextID = nil
        let filtered = shot.annotations.filter { ann in
            !(ann.tool == .text && ann.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        if filtered.count != shot.annotations.count {
            model.updateAnnotations(for: shotID, filtered)
        }
    }

    private func appendAnnotation(_ annotation: Annotation) {
        model.updateAnnotations(for: shotID, shot.annotations + [annotation])
    }

    private func toolButton(_ tool: AnnotationTool, systemName: String, help: String) -> some View {
        Button(action: {
            commitTextEditing()
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

private struct MarkupImageView: View {
    let image: NSImage
    @Binding var annotations: [Annotation]
    let draftAnnotation: Annotation?
    @Binding var editingTextID: UUID?
    let activeTool: AnnotationTool
    let onDraftChanged: (Annotation?) -> Void
    let onDraftFinished: (Annotation) -> Void
    let onTextCreated: (Annotation) -> Void
    let onEndEditing: () -> Void
    @FocusState private var textFieldFocused: Bool

    var body: some View {
        GeometryReader { proxy in
            let imageRect = AnnotationGeometry.fittedRect(imageSize: image.size, containerSize: proxy.size)
            let scale = AnnotationGeometry.viewScale(imageRect: imageRect, imageSize: image.size)
            ZStack(alignment: .topLeading) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: proxy.size.width, height: proxy.size.height)

                AnnotationCanvas(
                    imageSize: image.size,
                    annotations: annotations,
                    draftAnnotation: draftAnnotation,
                    hiddenID: editingTextID
                )
                .allowsHitTesting(false)
                .frame(width: proxy.size.width, height: proxy.size.height)

                ForEach(annotations) { annotation in
                    if annotation.tool == .text, annotation.id != editingTextID {
                        textHitTarget(for: annotation, imageRect: imageRect, scale: scale)
                    }
                }

                if let id = editingTextID,
                   let index = annotations.firstIndex(where: { $0.id == id }) {
                    textEditor(at: index, imageRect: imageRect, scale: scale)
                }
            }
            .contentShape(Rectangle())
            .gesture(markupGesture(imageRect: imageRect, imageSize: image.size))
        }
    }

    private func textHitTarget(for annotation: Annotation, imageRect: CGRect, scale: CGFloat) -> some View {
        let point = AnnotationGeometry.viewPoint(from: annotation.points[0], imageRect: imageRect, imageSize: image.size)
        let fontSize = (annotation.fontSize > 0 ? annotation.fontSize : AnnotationStyle.imageTextFontSize(imageSize: image.size, imageRect: imageRect)) * scale
        let size = measure(annotation.text, fontSize: fontSize)
        return Color.clear
            .frame(width: size.width, height: size.height)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                editingTextID = annotation.id
                textFieldFocused = true
            }
            .offset(x: point.x, y: point.y)
    }

    private func textEditor(at index: Int, imageRect: CGRect, scale: CGFloat) -> some View {
        let annotation = annotations[index]
        let id = annotation.id
        let point = AnnotationGeometry.viewPoint(from: annotation.points[0], imageRect: imageRect, imageSize: image.size)
        let fontSize = (annotation.fontSize > 0 ? annotation.fontSize : AnnotationStyle.imageTextFontSize(imageSize: image.size, imageRect: imageRect)) * scale
        return TextField("", text: Binding(
            get: { annotations.text(forID: id) },
            set: { newValue in
                guard let i = annotations.firstIndex(where: { $0.id == id }) else { return }
                annotations[i].text = newValue
            }
        ))
        .textFieldStyle(.plain)
        .font(.system(size: fontSize, weight: .bold))
        .foregroundStyle(.red)
        .focused($textFieldFocused)
        .fixedSize()
        .onSubmit { onEndEditing() }
        .onExitCommand { onEndEditing() }
        .offset(x: point.x, y: point.y)
        .onAppear { textFieldFocused = true }
    }

    private func markupGesture(imageRect: CGRect, imageSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard editingTextID == nil else { return }
                guard activeTool != .text else { return }
                guard let point = AnnotationGeometry.imagePoint(from: value.location, imageRect: imageRect, imageSize: imageSize) else {
                    return
                }

                switch activeTool {
                case .pen:
                    var points = draftAnnotation?.points ?? []
                    if points.isEmpty || points.last.map({ distance($0, point) > 1.5 }) == true {
                        points.append(point)
                    }
                    onDraftChanged(Annotation(
                        tool: .pen,
                        points: points,
                        lineWidth: AnnotationStyle.imageLineWidth(imageSize: imageSize, imageRect: imageRect)
                    ))
                case .arrow:
                    guard let start = AnnotationGeometry.imagePoint(from: value.startLocation, imageRect: imageRect, imageSize: imageSize) else {
                        return
                    }
                    onDraftChanged(Annotation(
                        tool: .arrow,
                        points: [start, point],
                        lineWidth: AnnotationStyle.imageLineWidth(imageSize: imageSize, imageRect: imageRect)
                    ))
                case .text:
                    break
                }
            }
            .onEnded { value in
                if activeTool == .text {
                    guard distance(value.startLocation, value.location) < 6,
                          let point = AnnotationGeometry.imagePoint(from: value.location, imageRect: imageRect, imageSize: imageSize)
                    else { return }
                    onTextCreated(Annotation(
                        tool: .text,
                        points: [point],
                        text: "",
                        fontSize: AnnotationStyle.imageTextFontSize(imageSize: imageSize, imageRect: imageRect)
                    ))
                    return
                }

                if editingTextID != nil { return }
                guard let draft = draftAnnotation else { return }
                let annotation: Annotation
                if activeTool == .arrow,
                   let end = AnnotationGeometry.imagePoint(from: value.location, imageRect: imageRect, imageSize: imageSize),
                   let start = draft.points.first {
                    annotation = Annotation(
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

    private func measure(_ string: String, fontSize: CGFloat) -> CGSize {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .bold)
        ]
        let s = (string.isEmpty ? " " : string) as NSString
        let size = s.size(withAttributes: attrs)
        return CGSize(width: ceil(size.width) + 4, height: ceil(size.height) + 2)
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
