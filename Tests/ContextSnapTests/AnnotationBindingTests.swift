import XCTest
@testable import ContextSnap

/// Regression coverage for the preview text-editor crash (EXC_BREAKPOINT in
/// Array._checkSubscript) when closing the preview while text annotations
/// were being edited.
///
/// Root cause: the TextField binding captured a stale array index. When
/// `commitTextEditing()` filtered out empty text annotations, AppKit's
/// delayed `controlTextDidEndEditing` would read `annotations[index]` after
/// the slot was gone, trapping the process.
///
/// Fix: look up annotations by id. These tests pin that behavior.
final class AnnotationBindingTests: XCTestCase {

    func testTextByIDReturnsValueWhenPresent() {
        let target = Annotation(tool: .text, points: [.zero], text: "hello")
        let list: [Annotation] = [
            Annotation(tool: .pen, points: [.zero, CGPoint(x: 1, y: 1)]),
            target,
            Annotation(tool: .arrow, points: [.zero, CGPoint(x: 2, y: 2)]),
        ]
        XCTAssertEqual(list.text(forID: target.id), "hello")
    }

    func testTextByIDReturnsEmptyAfterAnnotationRemoved() {
        let target = Annotation(tool: .text, points: [.zero], text: "draft")
        var list: [Annotation] = [
            Annotation(tool: .pen, points: [.zero, CGPoint(x: 1, y: 1)]),
            target,
        ]
        // Simulate commitTextEditing() dropping the empty/dismissed text
        // annotation out from under a live TextField binding.
        list.removeAll { $0.id == target.id }
        // The previous index (1) would now be out of bounds for the pen-only
        // list, which is what crashed the app. The by-id getter must return
        // a safe value instead of trapping.
        XCTAssertEqual(list.text(forID: target.id), "")
    }

    func testSetTextByIDUpdatesMatchingAnnotation() {
        let target = Annotation(tool: .text, points: [.zero], text: "")
        var list: [Annotation] = [target]
        list.setText("typed", forID: target.id)
        XCTAssertEqual(list[0].text, "typed")
    }

    func testSetTextByIDIsNoOpWhenAnnotationRemoved() {
        let target = Annotation(tool: .text, points: [.zero], text: "")
        var list: [Annotation] = [target]
        list.removeAll { $0.id == target.id }
        // The crash path: AppKit's delayed setter fires after the annotation
        // was filtered out. Must not trap; must not resurrect the entry.
        list.setText("late write", forID: target.id)
        XCTAssertTrue(list.isEmpty)
    }

    func testSetTextByIDIgnoresMismatchedID() {
        var list: [Annotation] = [
            Annotation(tool: .text, points: [.zero], text: "keep"),
        ]
        list.setText("clobbered", forID: UUID())
        XCTAssertEqual(list[0].text, "keep")
    }
}
