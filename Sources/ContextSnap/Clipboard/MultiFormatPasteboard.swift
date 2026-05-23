import AppKit
import UniformTypeIdentifiers

/// Writes screenshots to the pasteboard and drag sessions in multiple
/// representations at once. The receiving app picks whichever flavor it
/// understands:
///
///   - Terminals (Terminal.app, iTerm2, Claude Code) accept the plain-text path.
///   - Chat apps (iMessage, Slack, WeChat) accept the file URL and attach.
///   - Image-aware editors (Preview, Notes) accept the raw PNG bytes.
///
/// Annotations live on `Shot` as a parameterized list; this layer composites
/// them onto the base image on demand. The on-disk PNG at `shot.url` is the
/// untouched capture; when annotations exist, a flattened copy is written to a
/// per-shot cache file so the file-URL/drag flavor reflects the edits too.
enum MultiFormatPasteboard {

    static func makeItemProvider(for shot: Shot) -> NSItemProvider {
        let url = exportURL(for: shot) ?? shot.url
        let provider = NSItemProvider(contentsOf: url) ?? NSItemProvider()
        provider.suggestedName = shot.url.lastPathComponent
        return provider
    }

    static func writeToClipboard(_ shot: Shot) {
        let pb = NSPasteboard.general
        pb.clearContents()
        let item = NSPasteboardItem()
        let url = exportURL(for: shot) ?? shot.url
        item.setString(url.path, forType: .string)
        item.setString(url.absoluteString, forType: .fileURL)
        if let data = try? Data(contentsOf: url) {
            item.setData(data, forType: .png)
            item.setData(data, forType: NSPasteboard.PasteboardType(UTType.png.identifier))
        }
        pb.writeObjects([item])
    }

    /// Returns the on-disk URL of the image that should be vended for this
    /// shot — the original PNG if there are no annotations, otherwise a
    /// flattened copy written to a per-session cache. Nil on render failure.
    static func exportURL(for shot: Shot) -> URL? {
        if shot.annotations.isEmpty { return shot.url }
        guard let flattened = shot.image.flattening(shot.annotations),
              let data = flattened.pngData()
        else { return nil }
        let url = flattenedCacheURL(for: shot)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    private static func flattenedCacheURL(for shot: Shot) -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ContextSnap-flattened", isDirectory: true)
        return dir.appendingPathComponent("\(shot.id.uuidString).png")
    }
}
