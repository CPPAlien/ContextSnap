import AppKit
import UniformTypeIdentifiers

/// Writes screenshots to the pasteboard and drag sessions in multiple
/// representations at once. The receiving app picks whichever flavor it
/// understands:
///
///   - Terminals (Terminal.app, iTerm2, Claude Code) accept the plain-text path.
///   - Chat apps (iMessage, Slack, WeChat) accept the file URL and attach.
///   - Image-aware editors (Preview, Notes) accept the raw PNG bytes.
enum MultiFormatPasteboard {

    static func makeItemProvider(for shot: Shot) -> NSItemProvider {
        // `NSItemProvider(contentsOf:)` already vends the file URL plus auto-
        // derived UTI representations (public.png, public.file-url, …) which
        // covers the drag case for almost every target app.
        let provider = NSItemProvider(contentsOf: shot.url) ?? NSItemProvider()
        provider.suggestedName = shot.url.lastPathComponent
        return provider
    }

    static func writeToClipboard(_ shot: Shot) {
        let pb = NSPasteboard.general
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString(shot.url.path, forType: .string)
        item.setString(shot.url.absoluteString, forType: .fileURL)
        if let data = try? Data(contentsOf: shot.url) {
            item.setData(data, forType: .png)
            item.setData(data, forType: NSPasteboard.PasteboardType(UTType.png.identifier))
        }
        pb.writeObjects([item])
    }

    static func writeImageToClipboard(_ image: NSImage, fallbackPath: URL) {
        let pb = NSPasteboard.general
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString(fallbackPath.path, forType: .string)
        if let data = pngData(from: image) {
            item.setData(data, forType: .png)
            item.setData(data, forType: NSPasteboard.PasteboardType(UTType.png.identifier))
        }
        pb.writeObjects([item])
    }

    private static func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff)
        else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}
