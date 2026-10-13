import XCTest
@testable import ContextSnap

final class CodexCLITests: XCTestCase {
    func testCLIErrorIncludesCauseBeforeHelpHint() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("cli.sh")
        try """
        echo "error: unexpected argument '--sandbox' found" >&2
        echo >&2
        echo "For more information, try '--help'." >&2
        exit 2
        """.write(to: script, atomically: true, encoding: .utf8)

        do {
            _ = try await CodexCLI.ask(prompt: "follow-up", imagePath: nil,
                                      sessionID: "test-session", workingDirectory: directory,
                                      command: "/bin/sh cli.sh")
            XCTFail("Expected the CLI failure to be surfaced")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("unexpected argument '--sandbox'"))
            XCTAssertTrue(error.localizedDescription.contains("For more information"))
        }
    }
}
