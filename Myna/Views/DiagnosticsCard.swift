import SwiftUI
import UIKit

/// Backstage card: crashes, unexpected exits and the event log, captured on
/// the phone so a failure is never invisible. "Copy all" puts everything on
/// the clipboard for a bug report.
struct DiagnosticsCard: View {
    @State private var reports: [CrashReporter.Report] = []
    @State private var expanded: String?
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeading(icon: "stethoscope", title: "Diagnostics", tint: MynaTheme.magenta)
            Text(reports.isEmpty
                 ? "No crashes or unexpected exits recorded. Build \(CrashReporter.buildString)."
                 : "\(reports.count) report\(reports.count == 1 ? "" : "s") — tap one to read it.")
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(.white.opacity(0.5))

            ForEach(reports.prefix(12)) { report in
                VStack(alignment: .leading, spacing: 4) {
                    Button {
                        expanded = expanded == report.id ? nil : report.id
                    } label: {
                        HStack(alignment: .top) {
                            Image(systemName: report.title.hasPrefix("CRASH") ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(report.title.hasPrefix("CRASH") ? MynaTheme.magenta : MynaTheme.gold)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(report.title)
                                    .font(.system(size: 13, weight: .medium, design: .rounded))
                                    .foregroundStyle(.white.opacity(0.9))
                                    .multilineTextAlignment(.leading)
                                Text(report.date.formatted(date: .abbreviated, time: .shortened))
                                    .font(.system(size: 11, design: .rounded))
                                    .foregroundStyle(.white.opacity(0.4))
                            }
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                    if expanded == report.id {
                        Text(String(report.body.prefix(6000)))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.6))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

            HStack(spacing: 18) {
                Button {
                    UIPasteboard.general.string = CrashReporter.fullText()
                    copied = true
                } label: {
                    Label(copied ? "Copied" : "Copy all", systemImage: "doc.on.doc")
                }
                ShareLink(item: CrashReporter.fullText()) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                if !reports.isEmpty {
                    Button {
                        CrashReporter.clearReports()
                        reports = []
                    } label: {
                        Label("Clear", systemImage: "trash")
                    }
                }
            }
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .buttonStyle(.plain)
            .foregroundStyle(MynaTheme.cyan)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(glow: MynaTheme.magenta)
        .onAppear {
            reports = CrashReporter.reports()
            copied = false
        }
    }
}
