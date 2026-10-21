import SwiftUI

/// Backstage card: bring your Bee conversations into Myna. Bee does the room
/// recording and speaker separation; Myna files each conversation as a note.
struct BeeCloudCard: View {
    @EnvironmentObject private var importer: BeeCloudImporter
    @State private var token = ""
    @State private var tokenVisible = false
    @State private var showAdvanced = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeading(icon: "arrow.down.circle.fill", title: "Connect Bee", tint: MynaTheme.magenta)
            Text("Works alongside the Bee app: Bee does the far-field recording and speaker labels, and Myna pulls your conversations in as notes and learns what Bee knows about you. Read-only; nothing leaves this iPhone.")
                .cloudCaption()

            if importer.hasToken {
                connected
            } else {
                connectButton
                advanced
            }

            if importer.hasToken {
                Toggle(isOn: Binding(get: { importer.isEnabled }, set: { importer.setEnabled($0) })) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Auto-import").cloudLabel()
                        Text("Check for new Bee conversations whenever Myna opens.").cloudCaption()
                    }
                }
                .tint(MynaTheme.magenta)

                Button {
                    Task { await importer.importRecent() }
                } label: {
                    HStack(spacing: 8) {
                        if importer.status == .importing { ProgressView().controlSize(.small).tint(MynaTheme.magenta) }
                        Text(importer.status == .importing ? "Importing…" : "Import now")
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(MynaTheme.magenta)
                .disabled(importer.status == .importing)

                statusLine
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(glow: MynaTheme.magenta)
    }

    private var connectButton: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { importer.connect() } label: {
                Label("Connect Bee", systemImage: "link")
                    .font(MynaTheme.display(14, weight: .semibold))
                    .foregroundStyle(MynaTheme.void)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(MynaTheme.auroraGradient))
            }
            .buttonStyle(.plain)
            .disabled(importer.pairing.isBusy)

            pairingStatus
            Text("Approve Myna in your Bee account. If it won't connect, turn on Developer Mode in the Bee app (Settings → tap the version 5 times) and try again.")
                .cloudCaption()
        }
    }

    @ViewBuilder
    private var pairingStatus: some View {
        switch importer.pairing.state {
        case .requesting:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).tint(MynaTheme.magenta)
                Text("Starting…").cloudCaption()
            }
        case .awaitingApproval(let url):
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).tint(MynaTheme.magenta)
                    Text("Approve Myna in the browser, then come back here.").cloudCaption()
                }
                HStack(spacing: 14) {
                    Link("Open again", destination: url)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(MynaTheme.cyan)
                    Button("Cancel") { importer.pairing.cancel() }
                        .buttonStyle(.plain)
                        .font(.system(size: 13, design: .rounded))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
        case .failed(let message):
            Text(message).font(.system(size: 12, design: .rounded)).foregroundStyle(MynaTheme.gold)
        default:
            EmptyView()
        }
    }

    private var connected: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                GlowChip(text: importer.accountName.map { "Connected · \($0)" } ?? "Connected",
                         icon: "checkmark.circle.fill", tint: MynaTheme.mint)
                if !importer.facts.isEmpty {
                    GlowChip(text: "\(importer.facts.count) facts", icon: "sparkles", tint: MynaTheme.cyan)
                }
            }
            Button("Disconnect", role: .destructive) { importer.disconnect() }
                .buttonStyle(.plain)
                .font(.system(size: 13, design: .rounded))
                .foregroundStyle(.red.opacity(0.8))
        }
    }

    private var advanced: some View {
        DisclosureGroup(isExpanded: $showAdvanced) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Group {
                        if tokenVisible {
                            TextField("Paste a token", text: $token)
                        } else {
                            SecureField("Paste a token", text: $token)
                        }
                    }
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.white)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)

                    Button { tokenVisible.toggle() } label: {
                        Image(systemName: tokenVisible ? "eye.slash" : "eye").font(.system(size: 13))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.5))
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.06)))

                Button("Save token") {
                    importer.saveToken(token)
                    token = ""
                }
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .tint(MynaTheme.magenta)
                .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty)

                Text("Or paste a developer token from developer.bee.computer.").cloudCaption()
            }
            .padding(.top, 6)
        } label: {
            Text("Enter a token manually")
                .font(.system(size: 13, design: .rounded))
                .foregroundStyle(.white.opacity(0.6))
        }
        .tint(.white.opacity(0.6))
    }

    @ViewBuilder
    private var statusLine: some View {
        VStack(alignment: .leading, spacing: 4) {
            importStatus
            if let report = importer.lastReport {
                Text(report).cloudCaption()
            }
            if let reason = AppleIntelligenceEngine.unavailableReason {
                Text("Apple Intelligence off — using keyword matching. \(reason)")
                    .font(.system(size: 12, design: .rounded)).foregroundStyle(MynaTheme.gold)
            } else {
                Text("Apple Intelligence on — conversations are read in context.").cloudCaption()
            }
        }
    }

    @ViewBuilder
    private var importStatus: some View {
        switch importer.status {
        case .done(let added):
            Text(added == 0 ? "Up to date — nothing new." : "Imported \(added) conversation\(added == 1 ? "" : "s").")
                .cloudCaption()
        case .failed(let message):
            Text(message).font(.system(size: 12, design: .rounded)).foregroundStyle(MynaTheme.gold)
        default:
            if let last = importer.lastImport {
                Text("Last checked \(last.formatted(date: .abbreviated, time: .shortened)).").cloudCaption()
            }
        }
    }
}

private extension Text {
    func cloudLabel() -> Text {
        font(.system(size: 14, weight: .medium, design: .rounded)).foregroundColor(.white.opacity(0.9))
    }
    func cloudCaption() -> Text {
        font(.system(size: 12, design: .rounded)).foregroundColor(.white.opacity(0.5))
    }
}
