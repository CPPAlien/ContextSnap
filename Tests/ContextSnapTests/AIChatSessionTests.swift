import XCTest
@testable import ContextSnap

final class AIChatSessionTests: XCTestCase {
    func testClaudeUnknownSessionIsDetected() {
        let error = AIFailure(message: "No conversation found with session ID: 01a0b21d-b931-7542-b1dd-f125db13abec")
        XCTAssertTrue(AIChatModel.isUnknownSession(error))
    }

    func testCodexUnknownThreadIsDetected() {
        XCTAssertTrue(AIChatModel.isUnknownSession(AIFailure(message: "thread not found")))
        XCTAssertTrue(AIChatModel.isUnknownSession(AIFailure(message: "Invalid thread id")))
    }

    func testOrdinaryFailuresAreNotTreatedAsStaleSessions() {
        XCTAssertFalse(AIChatModel.isUnknownSession(AIFailure(message: "`codex` not found. Install the Codex CLI or set the command in Settings.")))
        XCTAssertFalse(AIChatModel.isUnknownSession(AIFailure(message: "error: unexpected argument '--sandbox' found")))
        XCTAssertFalse(AIChatModel.isUnknownSession(AIFailure(message: "Credit balance is too low")))
    }
}
