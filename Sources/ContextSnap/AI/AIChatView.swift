import AppKit
import Combine
import SwiftUI

struct ChatMessage: Identifiable, Equatable {
    enum Role { case user, assistant, error }
    let id = UUID()
    let role: Role
    var text: String
}

@MainActor
final class AIChatModel: ObservableObject {
    let shot: Shot
    @Published var messages: [ChatMessage] = []
    @Published var draft = ""
    @Published var busy = false
    /// Keeps the window above every other app's windows and on all Spaces.
    @Published var pinned = true
    /// Which CLI agent answers. Each agent keeps its own session, so switching
    /// back and forth resumes the thread that agent already had; the
    /// transcript above stays so the user keeps the history on screen.
    @Published var backend: AIBackend {
        didSet {
            guard backend != oldValue else { return }
            SettingsStore.shared.aiBackend = backend
        }
    }

    /// Session handles are per backend: a Claude session id is meaningless to
    /// Codex and vice versa, and an in-flight turn must never park its id on
    /// whichever backend happens to be selected when it finishes.
    private var sessionIDs: [AIBackend: String] = [:]

    init(shot: Shot, backend: AIBackend = SettingsStore.shared.aiBackend) {
        self.shot = shot
        self.backend = backend
    }

    var canSend: Bool {
        !busy && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func send(_ text: String? = nil) {
        let question = (text ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !busy else { return }
        draft = ""
        messages.append(ChatMessage(role: .user, text: question))
        busy = true

        let backend = backend
        let session = sessionIDs[backend]
        let prompt = buildPrompt(question, backend: backend, resuming: session != nil)
        let dir = shot.url.deletingLastPathComponent()
        let command = SettingsStore.shared.command(for: backend)
        let imagePath = shot.url.path

        Task { [weak self] in
            do {
                var reply: AIReply
                do {
                    reply = try await Self.runTurn(backend: backend, prompt: prompt,
                                                   sessionID: session, imagePath: imagePath,
                                                   workingDirectory: dir, command: command)
                } catch where session != nil && Self.isUnknownSession(error) {
                    // The agent no longer knows this thread (expired, pruned,
                    // or a different CLI wrote its history). Start a fresh
                    // session instead of wedging the chat on a dead id.
                    self?.sessionIDs[backend] = nil
                    let fresh = self?.buildPrompt(question, backend: backend, resuming: false)
                    reply = try await Self.runTurn(backend: backend, prompt: fresh ?? question,
                                                   sessionID: nil, imagePath: imagePath,
                                                   workingDirectory: dir, command: command)
                }
                guard let self else { return }
                if let id = reply.sessionID { self.sessionIDs[backend] = id }
                self.messages.append(ChatMessage(role: .assistant, text: reply.text))
            } catch {
                self?.messages.append(ChatMessage(role: .error, text: error.localizedDescription))
            }
            self?.busy = false
        }
    }

    private nonisolated static func runTurn(backend: AIBackend,
                                            prompt: String,
                                            sessionID: String?,
                                            imagePath: String,
                                            workingDirectory: URL,
                                            command: String) async throws -> AIReply {
        switch backend {
        case .claude:
            return try await ClaudeCLI.ask(prompt: prompt, sessionID: sessionID,
                                           workingDirectory: workingDirectory, command: command)
        case .codex:
            return try await CodexCLI.ask(prompt: prompt, imagePath: imagePath,
                                          sessionID: sessionID, workingDirectory: workingDirectory,
                                          command: command)
        }
    }

    /// Both CLIs report an unusable session id as plain prose, so the message
    /// is all there is to go on: `claude --resume` prints "No conversation
    /// found with session ID: …" and `codex exec resume` prints variations on
    /// "thread not found".
    nonisolated static func isUnknownSession(_ error: Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        let mentionsSession = message.contains("session") || message.contains("thread")
                              || message.contains("conversation")
        let mentionsMissing = message.contains("no conversation found")
            || message.contains("not found") || message.contains("does not exist")
            || message.contains("unknown") || message.contains("invalid")
        return mentionsSession && mentionsMissing
    }

    /// The whole conversation as Markdown, ready to drop into notes or a PR.
    func transcriptMarkdown() -> String {
        let stamp = ISO8601DateFormatter().string(from: Date())
        var out = "# \(backend.askTitle) — \(shot.url.lastPathComponent)\n\n"
        out += "- Screenshot: `\(shot.url.path)`\n- Exported: \(stamp)\n\n---\n\n"
        for message in messages {
            switch message.role {
            case .user: out += "## You\n\n\(message.text)\n\n"
            case .assistant: out += "## \(backend.displayName)\n\n\(message.text)\n\n"
            case .error: out += "## Error\n\n> \(message.text)\n\n"
            }
        }
        return out
    }

    /// Writes the transcript wherever the user points the save panel.
    func exportTranscript() {
        guard !messages.isEmpty else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = Self.defaultExportName(for: shot)
        panel.canCreateDirectories = true
        panel.title = "Save chat transcript"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try transcriptMarkdown().write(to: url, atomically: true, encoding: .utf8)
        } catch {
            messages.append(ChatMessage(role: .error, text: "Couldn't save transcript: \(error.localizedDescription)"))
        }
    }

    private static func defaultExportName(for shot: Shot) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return "ContextSnap-Chat-\(formatter.string(from: Date())).md"
    }

    /// The first turn hands the agent the screenshot — Claude reads it from
    /// disk, Codex gets it attached via `--image`. Later turns ride on the
    /// resumed session, which already has the image in context.
    private func buildPrompt(_ question: String, backend: AIBackend, resuming: Bool) -> String {
        guard !resuming else { return question }
        let preamble = backend == .claude
            ? "Use the Read tool to view the screenshot at \(shot.url.path), then answer the user's question about it."
            : "The attached image is a screenshot. Answer the user's question about it."
        return """
        \(preamble) Reply in the same language the user writes in. Be concise.

        User's question: \(question)
        """
    }
}

private let accent = Color(red: 0.55, green: 0.36, blue: 0.96)

struct AIChatView: View {
    @ObservedObject var model: AIChatModel
    @FocusState private var inputFocused: Bool
    @ObservedObject private var availability = AIBackendAvailability.shared
    @State private var hoveredMessageID: ChatMessage.ID?
    @State private var copiedMessageID: ChatMessage.ID?

    private let suggestions = ["解释这张图", "翻译成中文", "总结要点", "这个报错怎么修？"]

    var body: some View {
        VStack(spacing: 0) {
            header
            transcript
            composer
        }
        .frame(minWidth: 460, minHeight: 480)
        .background(.regularMaterial)
        .onAppear {
            inputFocused = true
            availability.refresh()
        }
        // The composer stays editable while Claude answers, so the caret
        // never has to be clicked back into place mid-reply.
        .onChange(of: model.busy) { _ in inputFocused = true }
    }

    /// The one other installed agent, when there is exactly one to offer.
    /// With only Claude around the header stays as it was.
    private var otherBackend: AIBackend? {
        let others = AIBackend.allCases.filter { $0 != model.backend && availability.installed.contains($0) }
        return others.count == 1 ? others.first : nil
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: model.shot.image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 140, maxHeight: 84)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.primary.opacity(0.12)))
                .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles").foregroundStyle(accent)
                    Text(model.backend.askTitle).font(.title3.weight(.semibold))
                    if let other = otherBackend {
                        Button {
                            model.backend = other
                        } label: {
                            Text("Switch to \(other.displayName)")
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Capsule().fill(Color.primary.opacity(0.07)))
                                .overlay(Capsule().stroke(Color.primary.opacity(0.12)))
                        }
                        .buttonStyle(.plain)
                        .help("Answer with \(other.displayName) from here on — the transcript stays, and each agent keeps its own session")
                    }
                }
                Text("\(Int(model.shot.image.size.width)) × \(Int(model.shot.image.size.height))  ·  \(model.shot.url.lastPathComponent)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button {
                model.exportTranscript()
            } label: {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(model.messages.isEmpty ? Color.secondary.opacity(0.5) : Color.secondary)
                    .frame(width: 28, height: 28)
                    .background(Color.primary.opacity(0.06), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(model.messages.isEmpty)
            .help("Save this conversation as a Markdown file")
            Button {
                model.pinned.toggle()
            } label: {
                Image(systemName: model.pinned ? "pin.fill" : "pin")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(model.pinned ? accent : Color.secondary)
                    .frame(width: 28, height: 28)
                    .background(model.pinned ? accent.opacity(0.15) : Color.primary.opacity(0.06), in: Circle())
            }
            .buttonStyle(.plain)
            .help(model.pinned ? "Pinned above other windows — click to unpin" : "Pin above other windows")
        }
        .padding(.horizontal, 18)
        .padding(.top, 38) // under the transparent titlebar
        .padding(.bottom, 14)
    }

    // MARK: Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if model.messages.isEmpty {
                        emptyState
                    }
                    ForEach(model.messages) { message in
                        bubble(message).id(message.id)
                    }
                    if model.busy {
                        HStack(spacing: 10) {
                            avatar
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Thinking…").foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 6)
                        }
                        .id("busy")
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(NSColor.textBackgroundColor).opacity(0.5))
            .onChange(of: model.messages) { _ in
                withAnimation { proxy.scrollTo(model.messages.last?.id, anchor: .bottom) }
            }
            .onChange(of: model.busy) { busy in
                if busy { withAnimation { proxy.scrollTo("busy", anchor: .bottom) } }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What do you want to know about this region?")
                .font(.headline)
                .foregroundStyle(.secondary)
            FlowLayout(spacing: 8) {
                ForEach(suggestions, id: \.self) { s in
                    Button(s) { model.send(s) }
                        .buttonStyle(ChipStyle())
                }
            }
        }
        .padding(.top, 10)
    }

    private var avatar: some View {
        ZStack {
            Circle().fill(accent.opacity(0.18))
            Image(systemName: "sparkles").font(.system(size: 12, weight: .semibold)).foregroundStyle(accent)
        }
        .frame(width: 26, height: 26)
    }

    /// Copies one reply's raw Markdown; the icon flips to a checkmark for a
    /// beat so the click has visible feedback.
    private func copyButton(for message: ChatMessage) -> some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(message.text, forType: .string)
            copiedMessageID = message.id
            let id = message.id
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                if copiedMessageID == id { copiedMessageID = nil }
            }
        } label: {
            Image(systemName: copiedMessageID == message.id ? "checkmark" : "doc.on.doc")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(copiedMessageID == message.id ? accent : Color.secondary)
                .frame(width: 24, height: 24)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("Copy this reply")
    }

    @ViewBuilder
    private func bubble(_ message: ChatMessage) -> some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 60)
                Text(message.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(accent, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .foregroundStyle(.white)
            }
        case .assistant:
            HStack(alignment: .top, spacing: 10) {
                avatar
                MarkdownView(source: message.text)
                    .padding(.top, 3)
                Spacer(minLength: 30)
                copyButton(for: message)
                    .opacity(hoveredMessageID == message.id || copiedMessageID == message.id ? 1 : 0)
            }
            // Without an explicit shape the row only hit-tests where there is
            // content, so crossing the gap toward the button counts as "left".
            .contentShape(Rectangle())
            .onHover { inside in
                if inside {
                    hoveredMessageID = message.id
                } else if hoveredMessageID == message.id {
                    hoveredMessageID = nil
                }
            }
        case .error:
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(message.text).textSelection(.enabled).foregroundStyle(.secondary)
                Spacer(minLength: 30)
            }
            .padding(12)
            .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    // MARK: Composer

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Ask anything…  ⏎ to send", text: $model.draft, axis: .vertical)
                .lineLimit(1...6)
                .textFieldStyle(.plain)
                .font(.body)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color(NSColor.textBackgroundColor), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(inputFocused ? accent.opacity(0.7) : Color.primary.opacity(0.12), lineWidth: 1))
                .focused($inputFocused)
                .onSubmit { model.send() }
            Button { model.send() } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(model.canSend ? accent : Color.secondary.opacity(0.4), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!model.canSend)
            .keyboardShortcut(.return, modifiers: .command)
            .padding(.bottom, 2)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

private struct ChipStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(
                Capsule().fill(configuration.isPressed ? accent.opacity(0.25) : Color.primary.opacity(0.06))
            )
            .overlay(Capsule().stroke(Color.primary.opacity(0.12)))
    }
}

/// Minimal wrapping HStack for suggestion chips.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        layout(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(proposal: proposal, subviews: subviews)
        for (i, origin) in result.origins.enumerated() {
            subviews[i].place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func layout(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, width: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            width = max(width, x - spacing)
        }
        return (CGSize(width: width, height: y + rowHeight), origins)
    }
}

@MainActor
final class AIChatWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let model: AIChatModel
    private var cancellables: Set<AnyCancellable> = []
    var onClose: (() -> Void)?

    init(shot: Shot, seedReply: String? = nil) {
        model = AIChatModel(shot: shot)
        if let seedReply {
            model.messages = [ChatMessage(role: .user, text: "解释这张图"),
                              ChatMessage(role: .assistant, text: seedReply)]
        }
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 600),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Ask Claude"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: AIChatView(model: model))
        window.center()
        super.init()
        window.delegate = self

        model.$pinned
            .receive(on: DispatchQueue.main)
            .sink { [weak self] pinned in self?.applyPin(pinned) }
            .store(in: &cancellables)
    }

    private func applyPin(_ pinned: Bool) {
        window.level = pinned ? .floating : .normal
        window.collectionBehavior = pinned
            ? [.canJoinAllSpaces, .fullScreenAuxiliary]
            : [.managed]
        // hidesOnDeactivate is false by default for NSWindow, so the panel
        // stays visible when another app takes focus.
    }

    func show() {
        // Unlike the capture overlay we *do* want focus here: the user is
        // about to type a question.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}
