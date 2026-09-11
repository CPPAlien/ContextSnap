import Foundation

/// Thin wrapper around `codex exec` (the Codex CLI's non-interactive mode).
///
/// The first turn attaches the screenshot with `--image`; later turns go
/// through `codex exec resume <thread-id>` so the image stays in context.
/// `--json` is only used to pick up the thread id and any error event — the
/// answer itself is read from `--output-last-message`, which is plain text.
enum CodexCLI {
    static func ask(prompt: String,
                    imagePath: String?,
                    sessionID: String?,
                    workingDirectory: URL,
                    command: String) async throws -> AIReply {
        try await Task.detached(priority: .userInitiated) {
            try run(prompt: prompt, imagePath: imagePath, sessionID: sessionID,
                    workingDirectory: workingDirectory, command: command)
        }.value
    }

    private static func run(prompt: String,
                            imagePath: String?,
                            sessionID: String?,
                            workingDirectory: URL,
                            command: String) throws -> AIReply {
        let lastMessageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("contextsnap-codex-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: lastMessageURL) }

        var args = ["exec"]
        if let sessionID, !sessionID.isEmpty {
            args += ["resume", sessionID]
        }
        args += ["--skip-git-repo-check",
                 "--sandbox", "read-only",
                 "--json",
                 "--output-last-message", lastMessageURL.path,
                 "--cd", workingDirectory.path]
        // `--image` only applies to a fresh session; a resumed thread already
        // has the screenshot in its history.
        if sessionID == nil, let imagePath {
            args += ["--image", imagePath]
        }
        // `--image` is variadic, so without this separator it swallows the
        // prompt and codex falls back to reading one from stdin.
        args += ["--", prompt]

        // Same login-shell trick as ClaudeCLI: launchd's PATH would not find
        // a codex installed under ~/.local/bin, nvm or Homebrew.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", "exec \(command) \"$@\"", "codex"] + args
        process.currentDirectoryURL = workingDirectory

        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "CLAUDECODE")
        env.removeValue(forKey: "CLAUDE_CODE_ENTRYPOINT")
        process.environment = env

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        // Without this codex waits on stdin for "additional input".
        process.standardInput = FileHandle.nullDevice

        try process.run()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let stdout = String(decoding: outData, as: UTF8.self)
        let stderr = String(decoding: errData, as: UTF8.self)

        if process.terminationStatus == 127 {
            throw AIFailure(message: "`\(command)` not found. \(AIBackend.codex.installHint)")
        }

        let events = parseEvents(stdout)
        let thread = events.threadID ?? sessionID

        if let message = events.errorMessage {
            throw AIFailure(message: message)
        }

        let lastMessage = (try? String(contentsOf: lastMessageURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !lastMessage.isEmpty {
            return AIReply(text: lastMessage, sessionID: thread)
        }
        if let text = events.agentMessage, !text.isEmpty {
            return AIReply(text: text, sessionID: thread)
        }

        guard process.terminationStatus == 0 else {
            let detail = stderr
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .last(where: { !$0.isEmpty && !$0.hasPrefix("Reading additional input") }) ?? ""
            throw AIFailure(message: detail.isEmpty
                            ? "\(command) exited with status \(process.terminationStatus)."
                            : detail)
        }
        throw AIFailure(message: "Codex returned an empty answer.")
    }

    private struct Events {
        var threadID: String?
        var agentMessage: String?
        var errorMessage: String?
    }

    /// `--json` prints one JSON object per line, e.g.
    /// `{"type":"thread.started","thread_id":"…"}`,
    /// `{"type":"item.completed","item":{"type":"agent_message","text":"…"}}`,
    /// `{"type":"error","message":"…"}`.
    private static func parseEvents(_ stdout: String) -> Events {
        var events = Events()
        for line in stdout.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            if let id = obj["thread_id"] as? String { events.threadID = id }

            switch obj["type"] as? String {
            case "error":
                events.errorMessage = obj["message"] as? String ?? "Codex reported an error."
            case "turn.failed":
                let error = obj["error"] as? [String: Any]
                events.errorMessage = error?["message"] as? String ?? events.errorMessage
                    ?? "Codex could not finish the turn."
            case "item.completed":
                if let item = obj["item"] as? [String: Any],
                   item["type"] as? String == "agent_message",
                   let text = item["text"] as? String {
                    events.agentMessage = text
                }
            default:
                break
            }
        }
        return events
    }
}
