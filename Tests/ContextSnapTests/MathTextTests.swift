import XCTest
@testable import ContextSnap

/// Agents answer with LaTeX ("$v_i = \omega \times X_i$"); the chat renders
/// Markdown only, so the math is rewritten to Unicode before parsing.
final class MathTextTests: XCTestCase {
    func testInlineMathBecomesUnicode() {
        XCTAssertEqual(MathText.render("$v_i = \\omega \\times X_i$"), "vᵢ = ω × Xᵢ")
        XCTAssertEqual(MathText.render("平移: $\\partial/\\partial t$ 作用"), "平移: ∂/∂t 作用")
        XCTAssertEqual(MathText.render("尺度: $v_i = X_i$"), "尺度: vᵢ = Xᵢ")
    }

    func testDisplayAndBracketDelimiters() {
        XCTAssertEqual(MathText.render("$$E = mc^2$$"), "E = mc²")
        XCTAssertEqual(MathText.render("\\[a \\leq b\\]"), "a ≤ b")
        XCTAssertEqual(MathText.render("\\(x \\in S\\)"), "x ∈ S")
    }

    func testFractionsRootsAndBraces() {
        XCTAssertEqual(MathText.render("$\\frac{a}{b}$"), "a/b")
        XCTAssertEqual(MathText.render("$\\frac{x + 1}{2}$"), "(x + 1)/2")
        XCTAssertEqual(MathText.render("$\\sqrt{2}$"), "√(2)")
        XCTAssertEqual(MathText.render("$v_{max}$"), "vₘₐₓ")
    }

    func testUnmappableScriptKeepsMarker() {
        // No Unicode subscript for "q", so the meaning must survive as-is.
        XCTAssertEqual(MathText.render("$X_{qz}$"), "X_(qz)")
    }

    func testMoneyAndShellAreLeftAlone() {
        XCTAssertEqual(MathText.render("It costs $100 and the other $200."),
                       "It costs $100 and the other $200.")
        XCTAssertEqual(MathText.render("Run `echo $HOME` first"), "Run `echo $HOME` first")
        XCTAssertEqual(MathText.render("no math here"), "no math here")
    }

    func testUnknownCommandStaysReadable() {
        XCTAssertEqual(MathText.render("$\\foo x$"), "foo x")
    }
}
