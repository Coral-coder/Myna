import SwiftUI

/// Settings › Home server: pair with the computer at home, see whether it's
/// answering, and which of the two did the last job.
struct HomeServerView: View {
    @ObservedObject private var server = HomeServer.shared
    @State private var link = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Your computer at home does the heavy work — transcription and note-writing — when it can be reached. When it can't, this iPhone does the same job itself and hands back as soon as the computer answers again.")
                    .font(.system(size: 14, weight: .light))
                    .foregroundStyle(MynaTheme.muted)

                if server.isPaired {
                    paired
                } else {
                    unpaired
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
    }

    private var paired: some View {
        VStack(alignment: .leading, spacing: 14) {
            row("Status", statusText)
            row("Address", server.address)
            if !server.info.transcriber.isEmpty { row("Transcription", server.info.transcriber) }
            if !server.info.writer.isEmpty { row("Writing", server.info.writer) }
            if let ms = server.latencyMs { row("Round trip", "\(ms) ms") }
            if !server.lastRoute.isEmpty { row("Last job", server.lastRoute) }
            if let error = server.lastError { row("Last problem", error) }

            Toggle(isOn: $server.enabled) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Use the home server when it answers")
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(MynaTheme.ink)
                    Text("Off: everything is done on this iPhone.")
                        .font(.system(size: 12, weight: .light))
                        .foregroundStyle(MynaTheme.muted)
                }
            }
            .tint(MynaTheme.signal)

            HStack(spacing: 10) {
                pill("Check now") { Task { await server.check() } }
                pill("Unpair") { server.unpair() }
                Spacer()
            }
        }
    }

    private var statusText: String {
        if !server.enabled { return "Paired · switched off" }
        switch server.reachable {
        case .some(true): return "Answering"
        case .some(false): return "Not answering — this iPhone is doing the work"
        case .none: return "Checking…"
        }
    }

    private var unpaired: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("PAIR")
                .font(MynaTheme.mono(11))
                .tracking(2)
                .foregroundStyle(MynaTheme.faint)
            Text("Start Myna Server on the computer. It shows a pairing link and a QR code. Scan the code with the iPhone camera, or paste the link here.")
                .font(.system(size: 13, weight: .light))
                .foregroundStyle(MynaTheme.muted)
            TextField("myna://pair?…", text: $link, axis: .vertical)
                .font(MynaTheme.mono(12))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .lineLimit(1...4)
                .padding(10)
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(MynaTheme.hair, lineWidth: 1))
            HStack {
                pill("Pair") {
                    if server.pair(link: link) { link = "" }
                }
                Spacer()
            }
            if let error = server.lastError {
                Text(error)
                    .font(.system(size: 12, weight: .light))
                    .foregroundStyle(MynaTheme.muted)
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(MynaTheme.mono(10))
                .tracking(1.5)
                .foregroundStyle(MynaTheme.faint)
            Text(value)
                .font(.system(size: 15, weight: .light))
                .foregroundStyle(MynaTheme.ink)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 8)
        .overlay(alignment: .bottom) { Rectangle().fill(MynaTheme.hairSoft).frame(height: 1) }
    }

    private func pill(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(MynaTheme.mono(11))
                .tracking(1)
                .textCase(.uppercase)
                .foregroundStyle(MynaTheme.ink)
                .padding(.horizontal, 13)
                .padding(.vertical, 7)
                .overlay(Capsule().strokeBorder(MynaTheme.hair, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}
