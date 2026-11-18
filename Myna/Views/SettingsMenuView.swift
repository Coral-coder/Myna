import SwiftUI

/// Settings: one plain menu for how Myna works — engines, devices, appearance.
/// Picking a row replaces the menu with that page; a back row returns.
struct SettingsMenuView: View {
    enum Page: String, CaseIterable, Identifiable {
        case transcription = "Transcription"
        case general = "Listening, bracelet & appearance"
        case models = "AI models"

        var id: String { rawValue }

        var blurb: String {
            switch self {
            case .transcription: return "Choose, download and test the engine that turns bracelet audio into text."
            case .general: return "Microphone, Bee bracelet, voices, automation, Daylight / Dusk, diagnostics."
            case .models: return "The on-device language models Myna thinks with."
            }
        }
    }

    @State private var page: Page?
    @ObservedObject private var lab = TranscriptionLab.shared

    var body: some View {
        if let page {
            VStack(spacing: 0) {
                Button {
                    self.page = nil
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 13, weight: .regular))
                        Text("Settings")
                            .font(MynaTheme.mono(12))
                            .tracking(1.4)
                            .textCase(.uppercase)
                        Spacer()
                        Text(page.rawValue)
                            .font(MynaTheme.mono(12))
                            .tracking(1)
                            .lineLimit(1)
                            .foregroundStyle(MynaTheme.faint)
                    }
                    .foregroundStyle(MynaTheme.ink)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Rectangle().fill(MynaTheme.hair).frame(height: 1)

                Group {
                    switch page {
                    case .transcription: TranscriptionLabView()
                    case .general: SettingsView()
                    case .models: ModelHubView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            menu
        }
    }

    private var menu: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Settings")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(MynaTheme.ink)
                    .padding(.top, 18)
                    .padding(.bottom, 14)

                ForEach(Page.allCases) { item in
                    Button {
                        page = item
                    } label: {
                        HStack(alignment: .center, spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.rawValue)
                                    .font(.system(size: 17, weight: .regular))
                                    .foregroundStyle(MynaTheme.ink)
                                Text(item == .transcription ? "In use: \(lab.activeEngine.name)" : item.blurb)
                                    .font(.system(size: 13, weight: .light))
                                    .foregroundStyle(MynaTheme.muted)
                                    .multilineTextAlignment(.leading)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .regular))
                                .foregroundStyle(MynaTheme.faint)
                        }
                        .padding(.vertical, 16)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Rectangle().fill(MynaTheme.hairSoft).frame(height: 1)
                }
            }
            .padding(.horizontal, 20)
        }
        .scrollIndicators(.hidden)
    }
}
