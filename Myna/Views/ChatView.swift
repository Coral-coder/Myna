import SwiftUI

/// Ask Myna anything about your life — it answers from your conversations,
/// lists, calendar and reminders, all on-device. A calm, minimal chat surface:
/// your words and Myna's, nothing else competing for attention.
struct ChatView: View {
    @EnvironmentObject private var brain: MynaBrain

    @State private var messages: [Message] = []
    @State private var draft = ""
    @State private var sending = false
    @FocusState private var inputFocused: Bool

    struct Message: Identifiable, Equatable {
        enum Role { case me, myna }
        let id = UUID()
        let role: Role
        var text: String
    }

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
            Text("Ask Myna")
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
            Spacer()
            if !messages.isEmpty {
                Button {
                    withAnimation { messages.removeAll() }
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
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
                .foregroundStyle(.white.opacity(0.85))
            Text("Everything you've talked about, kept on this phone. Ask and it answers — no cloud.")
                .font(.system(size: 14, design: .rounded))
                .foregroundStyle(.white.opacity(0.45))
            VStack(spacing: 10) {
                ForEach(suggestions, id: \.self) { s in
                    Button { send(s) } label: {
                        HStack {
                            Text(s)
                                .font(.system(size: 14, design: .rounded))
                                .foregroundStyle(.white.opacity(0.8))
                                .multilineTextAlignment(.leading)
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(MynaTheme.cyan.opacity(0.7))
                        }
                        .padding(.horizontal, 15)
                        .padding(.vertical, 13)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.05)))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 4)
        }
    }

    private func bubble(_ m: Message) -> some View {
        HStack {
            if m.role == .me { Spacer(minLength: 40) }
            Text(m.text)
                .font(.system(size: 15, design: .rounded))
                .foregroundStyle(m.role == .me ? .white : .white.opacity(0.9))
                .padding(.horizontal, 15)
                .padding(.vertical, 11)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(m.role == .me ? MynaTheme.cyan.opacity(0.18) : .white.opacity(0.06))
                )
                .frame(maxWidth: .infinity, alignment: m.role == .me ? .trailing : .leading)
                .textSelection(.enabled)
            if m.role == .myna { Spacer(minLength: 40) }
        }
        .id(m.id)
    }

    private var thinking: some View {
        HStack(spacing: 5) {
            ForEach(0..<3) { i in
                Circle()
                    .fill(.white.opacity(0.4))
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
                .foregroundStyle(.white)
                .lineLimit(1...5)
                .focused($inputFocused)
                .onSubmit { send(draft) }
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.white.opacity(0.07)))
            Button { send(draft) } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(MynaTheme.void)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(canSend ? MynaTheme.cyan : .white.opacity(0.2)))
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
        messages.append(Message(role: .me, text: trimmed))
        sending = true
        Task {
            let reply = await brain.handleTyped(trimmed)
            await MainActor.run {
                sending = false
                messages.append(Message(role: .myna, text: reply.isEmpty ? "…" : reply))
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
