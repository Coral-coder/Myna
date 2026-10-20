import SwiftUI

/// Backstage card: bring your Bee conversations into Myna. Bee does the room
/// recording and speaker separation; Myna files each conversation as a note.
struct BeeCloudCard: View {
    @EnvironmentObject private var importer: BeeCloudImporter
    @State private var token = ""
    @State private var tokenVisible = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeading(icon: "arrow.down.circle.fill", title: "Import from Bee", tint: MynaTheme.magenta)
            Text("Pull your Bee conversations in as notes — Bee's far-field recording and speaker labels, kept in Myna. Read-only; your token stays on this iPhone.")
                .cloudCaption()

            VStack(alignment: .leading, spacing: 6) {
                Text("Bee API token").cloudLabel()
                HStack {
                    Group {
                        if tokenVisible {
                            TextField("Paste your token", text: $token)
                        } else {
                            SecureField(importer.hasToken ? "••••••••  (saved)" : "Paste your token", text: $token)
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

                HStack {
                    Button("Save token") {
                        importer.saveToken(token)
                        token = ""
                    }
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .tint(MynaTheme.magenta)
                    .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty)

                    if importer.hasToken {
                        Button("Remove", role: .destructive) { importer.saveToken("") }
                            .font(.system(size: 13, design: .rounded))
                    }
                }
                Text("Get a token from your Bee account at developer.bee.computer.").cloudCaption()
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

    @ViewBuilder
    private var statusLine: some View {
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
