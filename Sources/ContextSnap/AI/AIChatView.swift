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

    private var sessionID: String?

    init(shot: Shot) {
        self.shot = shot
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

        let prompt = buildPrompt(question)
        let session = sessionID
        let dir = shot.url.deletingLastPathComponent()
        let command = SettingsStore.shared.claudeCommand

        Task { [weak self] in
            do {
                let reply = try await ClaudeCLI.ask(prompt: prompt, sessionID: session,
                                                    workingDirectory: dir, command: command)
                guard let self else { return }
                if let id = reply.sessionID { self.sessionID = id }
                self.messages.append(ChatMessage(role: .assistant, text: reply.text))
            } catch {
                self?.messages.append(ChatMessage(role: .error, text: error.localizedDescription))
            }
            self?.busy = false
        }
    }

    /// The first turn tells Claude where the screenshot lives; later turns
    /// ride on the resumed session, which already has the image in context.
    private func buildPrompt(_ question: String) -> String {
        guard sessionID == nil else { return question }
        return """
        Use the Read tool to view the screenshot at \(shot.url.path), then answer the user's question about it. \
        Reply in the same language the user writes in. Be concise.

        User's question: \(question)
        """
    }
}

private let accent = Color(red: 0.55, green: 0.36, blue: 0.96)

struct AIChatView: View {
    @ObservedObject var model: AIChatModel
    @FocusState private var inputFocused: Bool

    private let suggestions = ["解释这张图", "翻译成中文", "总结要点", "这个报错怎么修？"]

    var body: some View {
        VStack(spacing: 0) {
            header
            transcript
            composer
        }
        .frame(minWidth: 460, minHeight: 480)
        .background(.regularMaterial)
        .onAppear { inputFocused = true }
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
                HStack(spacing: 6) {
                    Image(systemName: "sparkles").foregroundStyle(accent)
                    Text("Ask Claude").font(.title3.weight(.semibold))
                }
                Text("\(Int(model.shot.image.size.width)) × \(Int(model.shot.image.size.height))  ·  \(model.shot.url.lastPathComponent)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
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
                .disabled(model.busy)
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
