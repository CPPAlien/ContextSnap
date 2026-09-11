import Foundation

/// Thin wrapper around `claude -p` (Claude Code's print mode).
///
/// Each call is one turn. The first turn returns a session id which is fed
/// back via `--resume` so follow-up questions keep the screenshot context.
enum ClaudeCLI {
    typealias Reply = AIReply
    typealias Failure = AIFailure

    static func ask(prompt: String,
                    sessionID: String?,
                    workingDirectory: URL,
                    command: String) async throws -> Reply {
        try await Task.detached(priority: .userInitiated) {
            try run(prompt: prompt, sessionID: sessionID,
                    workingDirectory: workingDirectory, command: command)
        }.value
    }

    private static func run(prompt: String,
                            sessionID: String?,
                            workingDirectory: URL,
                            command: String) throws -> Reply {
        var args = ["-p", prompt, "--output-format", "json", "--allowedTools", "Read"]
        if let sessionID, !sessionID.isEmpty {
            args += ["--resume", sessionID]
        }

        // A GUI app inherits launchd's tiny PATH, so `claude` installed via
        // nvm / Homebrew / npm -g would not resolve. A login shell sources
        // the user's profile and finds it the same way Terminal does.
        // Positional args are passed through "$@" so nothing gets re-quoted.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", "exec \(command) \"$@\"", "claude"] + args
        process.currentDirectoryURL = workingDirectory

        var env = ProcessInfo.processInfo.environment
        // Stop the CLI from thinking it is nested inside another Claude Code.
        env.removeValue(forKey: "CLAUDECODE")
        env.removeValue(forKey: "CLAUDE_CODE_ENTRYPOINT")
        process.environment = env

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice

        try process.run()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let stdout = String(decoding: outData, as: UTF8.self)
        let stderr = String(decoding: errData, as: UTF8.self)

        if process.terminationStatus == 127 {
            throw Failure(message: "`\(command)` not found. \(AIBackend.claude.installHint)")
        }

        if let parsed = parse(stdout) {
            if parsed.isError {
                throw Failure(message: parsed.text.isEmpty ? "Claude returned an error." : parsed.text)
            }
            return Reply(text: parsed.text, sessionID: parsed.sessionID)
        }

        guard process.terminationStatus == 0 else {
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure(message: detail.isEmpty
                          ? "\(command) exited with status \(process.terminationStatus)."
                          : detail)
        }
        // Fallback: treat raw stdout as the answer.
        return Reply(text: stdout.trimmingCharacters(in: .whitespacesAndNewlines), sessionID: sessionID)
    }

    private struct Parsed {
        let text: String
        let sessionID: String?
        let isError: Bool
    }

    /// `--output-format json` prints a single JSON object such as
    /// `{"type":"result","subtype":"success","is_error":false,"result":"…","session_id":"…"}`.
    private static func parse(_ stdout: String) -> Parsed? {
        // Be lenient: the CLI can prefix warnings on stdout, so find the
        // last line that is a JSON object.
        for line in stdout.split(separator: "\n").reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            let text = (obj["result"] as? String) ?? ""
            // JSONSerialization maps JSON null to NSNull, so a present-but-null
            // key must not count as "has an error status".
            let apiStatus = obj["api_error_status"] as? Int
            let isError = (obj["is_error"] as? Bool) ?? false
                || apiStatus != nil
                || (obj["terminal_reason"] as? String) == "api_error"
            return Parsed(text: text, sessionID: obj["session_id"] as? String, isError: isError)
        }
        return nil
    }
}
