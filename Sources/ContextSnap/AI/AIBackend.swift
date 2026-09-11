import Foundation

/// Which CLI agent answers questions about a screenshot.
enum AIBackend: String, CaseIterable, Identifiable, Codable {
    case claude
    case codex

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        }
    }

    /// Title shown in the chat header, e.g. "Ask Codex".
    var askTitle: String { "Ask \(displayName)" }

    var defaultCommand: String { rawValue }

    var installHint: String {
        switch self {
        case .claude: return "Install Claude Code or set the command in Settings."
        case .codex: return "Install the Codex CLI or set the command in Settings."
        }
    }
}

/// Reply shape shared by every backend.
struct AIReply {
    let text: String
    /// Opaque handle the backend uses to continue this conversation.
    let sessionID: String?
}

struct AIFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Tracks which agent CLIs are actually installed. A GUI app inherits
/// launchd's minimal PATH, so the probe runs through a login shell — the same
/// way the agents themselves are launched.
@MainActor
final class AIBackendAvailability: ObservableObject {
    static let shared = AIBackendAvailability()

    @Published private(set) var installed: Set<AIBackend> = [.claude]

    private init() {}

    func refresh() {
        let commands = Dictionary(uniqueKeysWithValues: AIBackend.allCases.map {
            ($0, SettingsStore.shared.command(for: $0))
        })
        Task.detached(priority: .utility) {
            var found: Set<AIBackend> = []
            for (backend, command) in commands where Self.isInstalled(command) {
                found.insert(backend)
            }
            await MainActor.run { [found] in
                // Never hide every option: if nothing resolved (odd shell
                // setup), keep Claude selectable so the error is actionable.
                self.installed = found.isEmpty ? [.claude] : found
            }
        }
    }

    nonisolated private static func isInstalled(_ command: String) -> Bool {
        let name = command.split(separator: " ").first.map(String.init) ?? command
        guard !name.isEmpty else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", "command -v \"$1\" >/dev/null 2>&1", "zsh", name]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
