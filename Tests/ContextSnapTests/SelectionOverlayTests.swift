import AppKit
import XCTest
@testable import ContextSnap

@MainActor
final class SelectionOverlayTests: XCTestCase {
    func testRetinaCropUsesTopLeftPixelCoordinates() {
        XCTAssertEqual(SelectionGeometry.pixelRect(
            for: CGRect(x: 100, y: 150, width: 300, height: 200),
            screenSize: CGSize(width: 1000, height: 800),
            pixelSize: CGSize(width: 2000, height: 1600)),
            CGRect(x: 200, y: 900, width: 600, height: 400))
    }

    func testAnnotationCoordinatesClampToSelection() {
        let rect = CGRect(x: 100, y: 150, width: 300, height: 200)
        XCTAssertEqual(SelectionGeometry.annotationPoint(CGPoint(x: 125, y: 320), in: rect),
                       CGPoint(x: 25, y: 30))
        XCTAssertEqual(SelectionGeometry.annotationPoint(CGPoint(x: 500, y: 100), in: rect),
                       CGPoint(x: 300, y: 200))
    }

    func testDrawUndoAndConfirmBeforeLeavingSelection() throws {
        let (window, view) = makeSelection()
        defer { window.close() }
        selectRegion(view)
        try clickTool("箭头", view: view)
        view.mouseDown(with: event(.leftMouseDown, at: CGPoint(x: 150, y: 300)))
        view.mouseDragged(with: event(.leftMouseDragged, at: CGPoint(x: 350, y: 200)))
        view.mouseUp(with: event(.leftMouseUp, at: CGPoint(x: 350, y: 200)))
        XCTAssertEqual(view.annotations.first?.tool, .arrow)
        XCTAssertEqual(view.annotations.first?.points, [CGPoint(x: 50, y: 50), CGPoint(x: 250, y: 150)])
        try clickTool("撤销 (⌘Z)", view: view)
        XCTAssertTrue(view.annotations.isEmpty)

        try clickTool("画笔", view: view)
        view.mouseDown(with: event(.leftMouseDown, at: CGPoint(x: 150, y: 300)))
        view.mouseDragged(with: event(.leftMouseDragged, at: CGPoint(x: 170, y: 280)))
        view.mouseUp(with: event(.leftMouseUp, at: CGPoint(x: 170, y: 280)))
        var result: NSRect?
        view.onComplete = { rect, _ in result = rect }
        try clickTool("Capture  (⏎)", view: view)
        XCTAssertEqual(result, CGRect(x: 100, y: 150, width: 300, height: 200))
        XCTAssertEqual(view.annotations.count, 1)
    }

    func testConfirmCommitsTextAndReselectionClearsAnnotations() throws {
        let (window, view) = makeSelection()
        defer { window.close() }
        selectRegion(view)
        try clickTool("文字", view: view)
        view.mouseDown(with: event(.leftMouseDown, at: CGPoint(x: 150, y: 300)))
        view.mouseUp(with: event(.leftMouseUp, at: CGPoint(x: 150, y: 300)))
        let editor = try XCTUnwrap(view.subviews.compactMap { $0 as? NSTextField }.first)
        editor.stringValue = "标注"
        try clickTool("Capture  (⏎)", view: view)
        XCTAssertEqual(view.annotations.first?.text, "标注")
        XCTAssertEqual(view.annotations.first?.points, [CGPoint(x: 50, y: 50)])
        view.mouseDown(with: event(.leftMouseDown, at: CGPoint(x: 500, y: 500)))
        view.mouseDragged(with: event(.leftMouseDragged, at: CGPoint(x: 650, y: 600)))
        view.mouseUp(with: event(.leftMouseUp, at: CGPoint(x: 650, y: 600)))
        XCTAssertTrue(view.annotations.isEmpty)
    }

    func testExportedTextStaysBelowItsTopLeftAnchor() throws {
        let image = NSImage(size: CGSize(width: 200, height: 160), flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            return true
        }
        let marked = try XCTUnwrap(image.flattening([
            Annotation(tool: .text, points: [CGPoint(x: 20, y: 40)], text: "Test", fontSize: 20)
        ]))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(marked.pngData())))
        var redRows: [Int] = []
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                   color.redComponent > 0.7, color.greenComponent < 0.5 {
                    redRows.append(y)
                }
            }
        }
        let scale = CGFloat(bitmap.pixelsHigh) / image.size.height
        XCTAssertTrue(CGFloat(try XCTUnwrap(redRows.min())) / scale >= 40)
        XCTAssertTrue(CGFloat(try XCTUnwrap(redRows.max())) / scale < 70)
    }

    func testMouseReleaseCompletesArrowWithoutDragEvent() throws {
        let (window, view) = makeSelection()
        defer { window.close() }
        selectRegion(view)
        try clickTool("箭头", view: view)
        view.mouseDown(with: event(.leftMouseDown, at: CGPoint(x: 150, y: 300)))
        view.mouseUp(with: event(.leftMouseUp, at: CGPoint(x: 350, y: 200)))
        XCTAssertEqual(view.annotations.first?.points, [CGPoint(x: 50, y: 50), CGPoint(x: 250, y: 150)])
    }

    func testRedoShortcutAndNewStrokeClearRedoHistory() throws {
        let (window, view) = makeSelection()
        defer { window.close() }
        selectRegion(view)
        try clickTool("画笔", view: view)
        view.mouseDown(with: event(.leftMouseDown, at: CGPoint(x: 150, y: 300)))
        view.mouseUp(with: event(.leftMouseUp, at: CGPoint(x: 170, y: 280)))
        let original = view.annotations
        try clickTool("撤销 (⌘Z)", view: view)
        let redo = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [.command, .shift], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: "Z", charactersIgnoringModifiers: "Z", isARepeat: false, keyCode: 6))
        XCTAssertTrue(view.performKeyEquivalent(with: redo))
        XCTAssertEqual(view.annotations, original)
        try clickTool("撤销 (⌘Z)", view: view)
        view.mouseDown(with: event(.leftMouseDown, at: CGPoint(x: 200, y: 250)))
        view.mouseUp(with: event(.leftMouseUp, at: CGPoint(x: 220, y: 230)))
        let replacement = view.annotations
        try clickTool("重做 (⌘⇧Z)", view: view)
        XCTAssertEqual(view.annotations, replacement)
    }

    func testTextEditorStaysInsideSelectionAtBottomRight() throws {
        let (window, view) = makeSelection()
        defer { window.close() }
        selectRegion(view)
        try clickTool("文字", view: view)
        view.mouseDown(with: event(.leftMouseDown, at: CGPoint(x: 399, y: 151)))
        view.mouseUp(with: event(.leftMouseUp, at: CGPoint(x: 399, y: 151)))
        let editor = try XCTUnwrap(view.subviews.compactMap { $0 as? NSTextField }.first)
        XCTAssertTrue(CGRect(x: 100, y: 150, width: 300, height: 200).contains(editor.frame))
        editor.stringValue = "边缘"
        try clickTool("Capture  (⏎)", view: view)
        XCTAssertEqual(view.annotations.first?.points.first?.x, editor.frame.minX - 100)
        XCTAssertEqual(view.annotations.first?.points.first?.y, 350 - editor.frame.maxY)
    }

    func testToolShortcutReturnsToMovingSelection() throws {
        let (window, view) = makeSelection()
        defer { window.close() }
        selectRegion(view)
        func key(_ character: String, code: UInt16) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                characters: character, charactersIgnoringModifiers: character, isARepeat: false, keyCode: code))
        }
        view.keyDown(with: try key("a", code: 0))
        view.mouseDown(with: event(.leftMouseDown, at: CGPoint(x: 150, y: 300)))
        view.mouseUp(with: event(.leftMouseUp, at: CGPoint(x: 350, y: 200)))
        XCTAssertEqual(view.annotations.first?.tool, .arrow)
        view.keyDown(with: try key("v", code: 9))
        view.mouseDown(with: event(.leftMouseDown, at: CGPoint(x: 200, y: 250)))
        view.mouseDragged(with: event(.leftMouseDragged, at: CGPoint(x: 250, y: 300)))
        view.mouseUp(with: event(.leftMouseUp, at: CGPoint(x: 250, y: 300)))
        var result: NSRect?
        view.onComplete = { rect, _ in result = rect }
        try clickTool("Capture  (⏎)", view: view)
        XCTAssertEqual(result, CGRect(x: 150, y: 200, width: 300, height: 200))
        XCTAssertEqual(view.annotations.count, 1)
    }

    private func makeSelection() -> (NSWindow, SelectionView) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 800),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = SelectionView(frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
                                 snapshot: NSImage(size: CGSize(width: 1000, height: 800)))
        window.contentView = view
        return (window, view)
    }

    private func selectRegion(_ view: SelectionView) {
        view.mouseDown(with: event(.leftMouseDown, at: CGPoint(x: 100, y: 150)))
        view.mouseDragged(with: event(.leftMouseDragged, at: CGPoint(x: 400, y: 350)))
        view.mouseUp(with: event(.leftMouseUp, at: CGPoint(x: 400, y: 350)))
        view.layoutSubtreeIfNeeded()
    }

    private func clickTool(_ tip: String, view: NSView) throws {
        func find(_ parent: NSView) -> NSView? {
            if parent.toolTip == tip { return parent }
            return parent.subviews.lazy.compactMap { find($0) }.first
        }
        let button = try XCTUnwrap(find(view))
        let point = button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        button.mouseDown(with: event(.leftMouseDown, at: point))
        button.mouseUp(with: event(.leftMouseUp, at: point))
    }

    private func event(_ type: NSEvent.EventType, at point: CGPoint) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                          windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }
}
