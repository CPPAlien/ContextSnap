import AppKit
import SwiftUI

enum AnnotationTool {
    case pen
    case arrow
    case text
}

struct Annotation: Identifiable, Equatable {
    let id = UUID()
    let tool: AnnotationTool
    var points: [CGPoint]
    var text: String
    let lineWidth: CGFloat
    let fontSize: CGFloat

    init(
        tool: AnnotationTool,
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

enum AnnotationStyle {
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

/// SwiftUI Canvas renderer — shared by preview and tile.
struct AnnotationCanvas: View {
    let imageSize: CGSize
    let annotations: [Annotation]
    let draftAnnotation: Annotation?
    let hiddenID: UUID?

    init(imageSize: CGSize, annotations: [Annotation], draftAnnotation: Annotation? = nil, hiddenID: UUID? = nil) {
        self.imageSize = imageSize
        self.annotations = annotations
        self.draftAnnotation = draftAnnotation
        self.hiddenID = hiddenID
    }

    var body: some View {
        GeometryReader { proxy in
            let imageRect = AnnotationGeometry.fittedRect(imageSize: imageSize, containerSize: proxy.size)
            Canvas { context, _ in
                for annotation in annotations where annotation.id != hiddenID {
                    annotation.draw(in: &context, imageRect: imageRect, imageSize: imageSize)
                }
                if let draftAnnotation {
                    draftAnnotation.draw(in: &context, imageRect: imageRect, imageSize: imageSize)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
}

enum AnnotationGeometry {
    static func fittedRect(imageSize: CGSize, containerSize: CGSize) -> CGRect {
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

    static func imagePoint(from location: CGPoint, imageRect: CGRect, imageSize: CGSize) -> CGPoint? {
        guard imageRect.contains(location), imageRect.width > 0, imageRect.height > 0 else { return nil }
        return CGPoint(
            x: (location.x - imageRect.minX) / imageRect.width * imageSize.width,
            y: (location.y - imageRect.minY) / imageRect.height * imageSize.height
        )
    }

    static func viewPoint(from imagePoint: CGPoint, imageRect: CGRect, imageSize: CGSize) -> CGPoint {
        CGPoint(
            x: imageRect.minX + imagePoint.x / max(imageSize.width, 1) * imageRect.width,
            y: imageRect.minY + imagePoint.y / max(imageSize.height, 1) * imageRect.height
        )
    }

    static func viewScale(imageRect: CGRect, imageSize: CGSize) -> CGFloat {
        imageRect.width / max(imageSize.width, 1)
    }
}

extension Annotation {
    /// Draw into a SwiftUI Canvas. Coordinates are in image (logical) space —
    /// the caller passes the on-screen rect the image is fitted into.
    func draw(in context: inout GraphicsContext, imageRect: CGRect, imageSize: CGSize) {
        let points = self.points.map { AnnotationGeometry.viewPoint(from: $0, imageRect: imageRect, imageSize: imageSize) }
        let scale = AnnotationGeometry.viewScale(imageRect: imageRect, imageSize: imageSize)

        if tool == .text, let point = points.first {
            let fontSize = self.fontSize > 0
                ? self.fontSize * scale
                : AnnotationStyle.textFontSize(for: imageRect.size)
            context.draw(
                Text(text)
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

        let lineWidth = self.lineWidth > 0
            ? self.lineWidth * scale
            : AnnotationStyle.lineWidth(for: imageRect.size)
        context.stroke(path, with: .color(.red), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))

        if tool == .arrow, let start = points.first, let end = points.last {
            drawArrowHead(from: start, to: end, in: &context, lineWidth: lineWidth)
        }
    }

    private func drawArrowHead(from start: CGPoint, to end: CGPoint, in context: inout GraphicsContext, lineWidth: CGFloat) {
        let angle = atan2(end.y - start.y, end.x - start.x)
        let length = AnnotationStyle.arrowHeadLength(lineWidth: lineWidth)
        let spread = CGFloat.pi / 7
        let p1 = CGPoint(x: end.x - cos(angle - spread) * length, y: end.y - sin(angle - spread) * length)
        let p2 = CGPoint(x: end.x - cos(angle + spread) * length, y: end.y - sin(angle + spread) * length)

        var head = Path()
        head.move(to: p1)
        head.addLine(to: end)
        head.addLine(to: p2)
        context.stroke(head, with: .color(.red), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
    }
}

extension Annotation {
    /// Bitmap-space rasterization for export. Coordinates are in image
    /// logical points; this maps them to the pixel context.
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
            let fontSize = (self.fontSize > 0 ? self.fontSize : AnnotationStyle.textFontSize(for: logicalSize)) * scale
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

        context.setLineWidth((self.lineWidth > 0 ? self.lineWidth : AnnotationStyle.lineWidth(for: logicalSize)) * scale)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.beginPath()
        context.move(to: convertedPoints[0])
        for point in convertedPoints.dropFirst() {
            context.addLine(to: point)
        }
        context.strokePath()

        if tool == .arrow, let start = convertedPoints.first, let end = convertedPoints.last {
            drawPixelArrowHead(from: start, to: end, lineWidth: (self.lineWidth > 0 ? self.lineWidth : AnnotationStyle.lineWidth(for: logicalSize)) * scale, in: context)
        }

        context.restoreGState()
    }

    private func drawPixelArrowHead(from start: CGPoint, to end: CGPoint, lineWidth: CGFloat, in context: CGContext) {
        let angle = atan2(end.y - start.y, end.x - start.x)
        let length = AnnotationStyle.arrowHeadLength(lineWidth: lineWidth)
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

extension NSImage {
    /// Composites `annotations` onto a copy of this image and returns the
    /// flattened result. Returns self if `annotations` is empty.
    func flattening(_ annotations: [Annotation]) -> NSImage? {
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

    func pngData() -> Data? {
        guard let tiff = tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff)
        else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}
