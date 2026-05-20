#!/usr/bin/env swift
// Renders ContextSnap.app icon set into an .iconset directory.
// Usage: swift Scripts/make-icon.swift <output-iconset-dir>
import AppKit
import CoreGraphics

func render(pixels: Int) -> Data {
    let size = CGFloat(pixels)
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext

    // Squircle background with diagonal gradient (blue → purple).
    let radius = size * 0.2237
    let bgRect = CGRect(x: 0, y: 0, width: size, height: size)
    let bgPath = CGPath(roundedRect: bgRect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.saveGState()
    ctx.addPath(bgPath); ctx.clip()
    let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            CGColor(red: 0.31, green: 0.55, blue: 1.00, alpha: 1.0),  // #4F8BFF
            CGColor(red: 0.48, green: 0.36, blue: 1.00, alpha: 1.0),  // #7B5BFF
        ] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size),
                           end: CGPoint(x: size, y: 0), options: [])
    ctx.restoreGState()

    // Stacked cards (shot stack motif) — back card rotated +, front rotated -.
    let center = CGPoint(x: size / 2, y: size / 2)
    let cardSize = size * 0.44
    let cardRadius = cardSize * 0.14

    func drawCard(rotation: CGFloat, fill: CGColor, shadow: Bool) {
        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.rotate(by: rotation)
        let rect = CGRect(x: -cardSize / 2, y: -cardSize / 2, width: cardSize, height: cardSize)
        let path = CGPath(roundedRect: rect, cornerWidth: cardRadius, cornerHeight: cardRadius, transform: nil)
        if shadow {
            ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.012),
                          blur: size * 0.025,
                          color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.35))
        }
        ctx.addPath(path)
        ctx.setFillColor(fill)
        ctx.fillPath()
        ctx.restoreGState()
    }

    drawCard(rotation:  0.20, fill: CGColor(red: 1, green: 1, blue: 1, alpha: 0.55), shadow: true)
    drawCard(rotation: -0.08, fill: CGColor(red: 1, green: 1, blue: 1, alpha: 1.00), shadow: true)

    // Viewfinder corner brackets, white, rounded caps.
    let bracketColor = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
    let bracketLength = size * 0.13
    let bracketWidth = size * 0.04
    let bracketInset = size * 0.115
    let outer = CGRect(x: bracketInset, y: bracketInset,
                       width: size - 2 * bracketInset, height: size - 2 * bracketInset)
    ctx.setStrokeColor(bracketColor)
    ctx.setLineWidth(bracketWidth)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)

    func corner(_ ax: CGFloat, _ ay: CGFloat, _ bx: CGFloat, _ by: CGFloat, _ cx: CGFloat, _ cy: CGFloat) {
        ctx.move(to: CGPoint(x: ax, y: ay))
        ctx.addLine(to: CGPoint(x: bx, y: by))
        ctx.addLine(to: CGPoint(x: cx, y: cy))
    }
    // Top-left, top-right, bottom-left, bottom-right
    corner(outer.minX, outer.maxY - bracketLength, outer.minX, outer.maxY, outer.minX + bracketLength, outer.maxY)
    corner(outer.maxX - bracketLength, outer.maxY, outer.maxX, outer.maxY, outer.maxX, outer.maxY - bracketLength)
    corner(outer.minX, outer.minY + bracketLength, outer.minX, outer.minY, outer.minX + bracketLength, outer.minY)
    corner(outer.maxX - bracketLength, outer.minY, outer.maxX, outer.minY, outer.maxX, outer.minY + bracketLength)
    ctx.strokePath()

    image.unlockFocus()

    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write("PNG encode failed\n".data(using: .utf8)!)
        exit(1)
    }
    return png
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write("usage: make-icon.swift <iconset-dir>\n".data(using: .utf8)!)
    exit(2)
}
let outDir = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let sizes: [(base: Int, scale: Int)] = [
    (16, 1), (16, 2),
    (32, 1), (32, 2),
    (128, 1), (128, 2),
    (256, 1), (256, 2),
    (512, 1), (512, 2),
]
for (base, scale) in sizes {
    let pixels = base * scale
    let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
    let data = render(pixels: pixels)
    let url = outDir.appendingPathComponent(name)
    try data.write(to: url)
    print("  \(name) (\(pixels)px)")
}
