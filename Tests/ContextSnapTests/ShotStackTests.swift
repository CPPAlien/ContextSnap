import XCTest
import AppKit
@testable import ContextSnap

/// Behaviour the overlay panel relies on when reacting to model changes
/// (visibility toggling, preview navigation, annotation edits).
@MainActor
final class ShotStackTests: XCTestCase {

    private func makeShot() -> Shot {
        Shot(url: URL(fileURLWithPath: "/tmp/contextsnap-test.png"),
             image: NSImage(size: NSSize(width: 1, height: 1)))
    }

    func testAppendSelectsNewShot() {
        let stack = ShotStack()
        let shot = makeShot()
        stack.append(shot)
        XCTAssertEqual(stack.shots.count, 1)
        XCTAssertEqual(stack.selectedID, shot.id)
    }

    func testRemoveAdvancesSelectionToLastRemaining() {
        let stack = ShotStack()
        let a = makeShot(), b = makeShot()
        stack.append(a)
        stack.append(b)
        stack.remove(b)
        XCTAssertEqual(stack.shots.map(\.id), [a.id])
        XCTAssertEqual(stack.selectedID, a.id)
    }

    func testRemoveLastClearsSelection() {
        let stack = ShotStack()
        let a = makeShot()
        stack.append(a)
        stack.remove(a)
        XCTAssertTrue(stack.shots.isEmpty)
        XCTAssertNil(stack.selectedID)
    }

    func testUpdateAnnotationsReplacesList() {
        let stack = ShotStack()
        let shot = makeShot()
        stack.append(shot)
        let pen = Annotation(tool: .pen, points: [.zero, CGPoint(x: 5, y: 5)])
        stack.updateAnnotations(for: shot.id, [pen])
        XCTAssertEqual(stack.shots[0].annotations.count, 1)
        XCTAssertEqual(stack.shots[0].annotations[0].id, pen.id)
    }

    func testUpdateAnnotationsForMissingShotIsNoOp() {
        let stack = ShotStack()
        let shot = makeShot()
        stack.append(shot)
        stack.updateAnnotations(for: UUID(), [
            Annotation(tool: .pen, points: [.zero, .zero])
        ])
        XCTAssertTrue(stack.shots[0].annotations.isEmpty)
    }

    func testClearRemovesEverything() {
        let stack = ShotStack()
        stack.append(makeShot())
        stack.append(makeShot())
        stack.clear()
        XCTAssertTrue(stack.shots.isEmpty)
        XCTAssertNil(stack.selectedID)
    }

    /// Mirrors `ShotPreviewView.commitTextEditing()`: filtering empty text
    /// annotations must shrink the array, which is the precondition for the
    /// captured-index crash that the by-id binding now guards against.
    func testCommitFilterDropsEmptyTextAnnotation() {
        let kept = Annotation(tool: .text, points: [.zero], text: "real")
        let dropped = Annotation(tool: .text, points: [.zero], text: "   ")
        let list: [Annotation] = [kept, dropped]
        let filtered = list.filter { ann in
            !(ann.tool == .text && ann.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        XCTAssertEqual(filtered.map(\.id), [kept.id])
    }
}
