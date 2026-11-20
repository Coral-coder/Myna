import SwiftUI

/// Ask Myna anything about your life — it answers from your conversations,
/// lists, calendar and reminders, all on-device. A calm, minimal chat surface:
/// your words and Myna's, nothing else competing for attention.
struct ChatView: View {
    @EnvironmentObject private var brain: MynaBrain

    @ObservedObject private var log = ChatLog.shared
    @ObservedObject private var server = HomeServer.shared
    @AppStorage("myna.verboseThinking") private var verbose = false
    private var messages: [Message] { log.messages }
    @State private var draft = ""
    @State private var sending = false
    @FocusState private var inputFocused: Bool

    typealias Message = ChatLog.Message

    private let suggestions = [
        "What did I say I'd do today?",
        "Summarize my last conversation",
        "What have I been thinking about lately?",
        "What's on my calendar this week?",
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollViewReader { proxy in
                ScrollView {
                    if messages.isEmpty {
                        emptyState
                            .padding(.top, 40)
                            .padding(.horizontal, 24)
                    } else {
                        LazyVStack(spacing: 14) {
                            ForEach(messages) { bubble($0) }
                            if sending { thinking.id("thinking") }
                        }
                        .padding(.horizontal, 18)
                        .padding(.top, 16)
                        .padding(.bottom, 8)
                    }
                }
                .onChange(of: messages) { _, _ in scrollToEnd(proxy) }
                .onChange(of: sending) { _, _ in scrollToEnd(proxy) }
            }
            inputBar
        }
    }

    private var header: some View {
        HStack {
            Text("Ask Lumi")
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundStyle(MynaTheme.ink)
            Spacer()
            Button {
                withAnimation { verbose.toggle() }
            } label: {
                Image(systemName: verbose ? "eye.fill" : "eye")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(verbose ? MynaTheme.cyan : MynaTheme.ink.opacity(0.4))
            }
            .accessibilityLabel("Show thinking")
            if !messages.isEmpty {
                Button {
                    withAnimation { log.clear() }
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(MynaTheme.ink.opacity(0.5))
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Your memory, on call.")
                .font(.system(size: 17, weight: .medium, design: .rounded))
                .foregroundStyle(MynaTheme.ink.opacity(0.85))
            Text("Everything you've talked about, kept on this phone. Ask and it answers — no cloud.")
                .font(.system(size: 14, design: .rounded))
                .foregroundStyle(MynaTheme.ink.opacity(0.45))
            VStack(spacing: 10) {
                ForEach(suggestions, id: \.self) { s in
                    Button { send(s) } label: {
                        HStack {
                            Text(s)
                                .font(.system(size: 14, design: .rounded))
                                .foregroundStyle(MynaTheme.ink.opacity(0.8))
                                .multilineTextAlignment(.leading)
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(MynaTheme.cyan.opacity(0.7))
                        }
                        .padding(.horizontal, 15)
                        .padding(.vertical, 13)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(MynaTheme.ink.opacity(0.05)))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 4)
        }
    }

    @ViewBuilder private func bubble(_ m: Message) -> some View {
        if m.role == .me {
            HStack {
                Spacer(minLength: 40)
                Text(m.text)
                    .font(.system(size: 15, design: .rounded))
                    .foregroundStyle(MynaTheme.ink)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 11)
                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(MynaTheme.cyan.opacity(0.18)))
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .textSelection(.enabled)
            }
            .id(m.id)
        } else {
            // Lumi's answers are Markdown — code blocks, tables, lists and the
            // rest render the way they're written, not as one flat run of text.
            // When "thinking" is on, the steps it took show above the answer.
            VStack(alignment: .leading, spacing: 6) {
                if verbose, !m.think.isEmpty {
                    // The model's reasoning and tool use, streaming in live.
                    ScrollView {
                        Text(m.think + (m.streaming ? " ▋" : ""))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(MynaTheme.ink.opacity(0.5))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 220)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(MynaTheme.cyan.opacity(0.05)))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(MynaTheme.cyan.opacity(0.18)))
                }
                if verbose, !m.steps.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(m.steps.indices, id: \.self) { i in
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: "arrow.turn.down.right")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(MynaTheme.cyan.opacity(0.6))
                                Text(m.steps[i])
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(MynaTheme.ink.opacity(0.45))
                            }
                        }
                    }
                    .padding(.leading, 4)
                }
                MarkdownText(text: m.text.isEmpty ? "…" : m.text)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 11)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(MynaTheme.ink.opacity(0.06)))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 24)
            .id(m.id)
        }
    }

    private var thinking: some View {
        HStack(spacing: 5) {
            ForEach(0..<3) { i in
                Circle()
                    .fill(MynaTheme.ink.opacity(0.4))
                    .frame(width: 6, height: 6)
                    .scaleEffect(sending ? 1 : 0.6)
                    .animation(.easeInOut(duration: 0.6).repeatForever().delay(Double(i) * 0.15), value: sending)
            }
            Spacer()
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 8)
    }

    private var inputBar: some View {
        HStack(spacing: 10) {
            TextField("Ask anything…", text: $draft, axis: .vertical)
                .font(.system(size: 15, design: .rounded))
                .foregroundStyle(MynaTheme.ink)
                .lineLimit(1...5)
                .focused($inputFocused)
                .onSubmit { send(draft) }
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(MynaTheme.ink.opacity(0.07)))
            Button { send(draft) } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(MynaTheme.void)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(canSend ? MynaTheme.cyan : MynaTheme.ink.opacity(0.2)))
            }
            .disabled(!canSend)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !sending
    }

    private func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !sending else { return }
        inputFocused = false
        draft = ""
        // The turns before this question, for the server to keep context.
        let before = messages.suffix(12).map { ["role": $0.role == .me ? "me" : "myna", "text": $0.text] }
        log.add(.me, trimmed)
        sending = true
        let serverReady = server.isPaired && server.enabled && server.reachable == true

        // Verbose + server reachable over the local network: stream everything
        // live (reasoning, tool use, answer tokens) into a message in place.
        if verbose, serverReady, !server.hasPrivateAddress {
            let id = log.beginAssistant()
            Task { @MainActor in
                var steps: [String] = []
                for await event in server.askStream(question: trimmed, history: before) {
                    switch event {
                    case .thinking(let d): log.update(id) { $0.think += d }
                    case .phase(let d): log.update(id) { $0.think += "\n── \(d) ──\n" }
                    case .step(let d): steps.append(d); log.update(id) { $0.steps = steps; $0.think += "\n→ \(d)\n" }
                    case .observation(let d): log.update(id) { $0.think += "    " + d.prefix(400) + "\n" }
                    case .answer(let d): log.update(id) { $0.text += d }
                    case .done(let reply, let s, _): log.update(id) { if !reply.isEmpty { $0.text = reply }; if !s.isEmpty { $0.steps = s } }
                    case .failed(let message): log.update(id) { if $0.text.isEmpty { $0.text = "Couldn't answer: \(message)" } }
                    }
                }
                sending = false
                log.finish(id)
            }
            return
        }

        Task {
            // The server is the brain: when it's reachable, Lumi answers there,
            // with all its tools, Markdown and a trace. The phone falls back to
            // its own on-device answer only when the server can't be reached.
            if serverReady, let result = try? await server.ask(question: trimmed, history: before) {
                await MainActor.run {
                    sending = false
                    log.add(.myna, result.reply.isEmpty ? "…" : result.reply, steps: result.steps)
                }
                return
            }
            let reply = await brain.handleTyped(trimmed)
            await MainActor.run {
                sending = false
                log.add(.myna, reply.isEmpty ? "…" : reply)
            }
        }
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) {
            if sending {
                proxy.scrollTo("thinking", anchor: .bottom)
            } else if let last = messages.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }
}
