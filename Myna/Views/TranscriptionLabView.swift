import SwiftUI

/// The Transcription Lab screen: record one clip from the bracelet, run it
/// through every engine, read the results side by side, and score them.
struct TranscriptionLabView: View {
    @ObservedObject private var lab = TranscriptionLab.shared
    @EnvironmentObject private var listener: SpeechListener
    @EnvironmentObject private var bee: BeeManager
    @State private var keys: [CloudVendor: String] = [:]
    @State private var sortByScore = false

    var body: some View {
        VStack(spacing: 0) {
            // Stays put: the engine in use and what it is hearing right now.
            activeCard
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 12)
            Rectangle().fill(MynaTheme.hair).frame(height: 1)
            engineList
        }
        .onAppear {
            for vendor in CloudVendor.allCases { keys[vendor] = LabKeychain.get(vendor) }
        }
    }

    /// Scrolls underneath the pinned card.
    private var engineList: some View {
        ScrollView {
            VStack(spacing: 16) {
                clipCard
                section(title: "On this iPhone", icon: "iphone", engines: sorted(LabCatalog.onDevice))
                section(title: "Cloud — audio leaves the phone", icon: "cloud", engines: sorted(LabCatalog.cloud))
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
    }

    private func sorted(_ engines: [LabEngine]) -> [LabEngine] {
        guard sortByScore else { return engines }
        return engines.sorted { (lab.ratings[$0.id] ?? 0) > (lab.ratings[$1.id] ?? 0) }
    }

    // MARK: - Active engine

    private var activeCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeading(icon: "checkmark.circle", title: "In use")
            Text(lab.activeEngine.name)
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(MynaTheme.ink)
            Text(activeNote)
                .font(.system(size: 13, weight: .light))
                .foregroundStyle(MynaTheme.muted)
            Rectangle().fill(MynaTheme.hairSoft).frame(height: 1)
            LiveTicker()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private var activeNote: String {
        let engine = lab.activeEngine
        if engine.id == TranscriptionLab.legacyID {
            return "Apple's word-by-word recognizer transcribes the bracelet. Tap Use on any engine below to switch."
        }
        if !lab.isReady(engine) {
            return "Its model isn't here yet (downloading, or no API key). Until it is, \(lab.effectiveEngine.name) fills in."
        }
        return "Bracelet audio is transcribed by this engine each time you pause. If it fails, Apple SpeechTranscriber takes that utterance."
    }

    // MARK: - Clip

    private var clipCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeading(icon: "waveform", title: "Test clip")
            Text(clipStatus)
                .font(.system(size: 13, weight: .light))
                .foregroundStyle(MynaTheme.muted)
            HStack(spacing: 10) {
                pill(lab.isRecording ? "Stop" : (lab.hasClip ? "Record again" : "Record from bracelet")) {
                    if lab.isRecording { lab.stopRecording() } else { lab.startRecording(from: listener) }
                }
                if lab.hasClip, !lab.isRecording {
                    pill("Test all ready") { lab.runAllReady() }
                }
                Spacer()
            }
            if lab.hasClip {
                Toggle(isOn: $sortByScore) {
                    Text("Sort by my score")
                        .font(.system(size: 13, weight: .light))
                        .foregroundStyle(MynaTheme.muted)
                }
                .tint(MynaTheme.signal)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private var clipStatus: String {
        if lab.isRecording {
            let flowing = bee.audioActive ? "" : " Waiting for bracelet audio — talk near it."
            return String(format: "Recording… %.0f s (stops at %.0f).", lab.clipSeconds, TranscriptionLab.maxClipSeconds) + flowing
        }
        if lab.hasClip {
            return String(format: "%.0f s recorded from the bracelet. Every engine runs on this same clip.", lab.clipSeconds)
        }
        return "Record 20–60 seconds of normal talking through the bracelet. Every engine then runs on that same clip, so the comparison is fair."
    }

    // MARK: - Engines

    private func section(title: String, icon: String, engines: [LabEngine]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeading(icon: icon, title: title)
            ForEach(engines) { engine in
                row(engine)
                if engine.id != engines.last?.id {
                    Rectangle().fill(MynaTheme.hairSoft).frame(height: 1)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    @ViewBuilder
    private func row(_ engine: LabEngine) -> some View {
        let activity = lab.activity(of: engine)
        let outcome = lab.outcomes[engine.id]
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(engine.name)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(MynaTheme.ink)
                Spacer()
                if engine.megabytes > 0 {
                    Text("\(engine.megabytes) MB")
                        .font(MynaTheme.mono(10))
                        .foregroundStyle(MynaTheme.faint)
                }
            }
            Text(engine.detail)
                .font(.system(size: 12, weight: .light))
                .foregroundStyle(MynaTheme.muted)

            if case .cloud(let vendor) = engine.kind {
                SecureField("\(vendor.label) API key", text: Binding(
                    get: { keys[vendor] ?? "" },
                    set: { keys[vendor] = $0; LabKeychain.set($0, for: vendor) }
                ))
                .font(MynaTheme.mono(12))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(9)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(MynaTheme.ink.opacity(0.05)))
            }

            HStack(spacing: 10) {
                switch activity {
                case .downloading(let fraction):
                    ProgressView(value: fraction).tint(MynaTheme.signal)
                    Text("\(Int(fraction * 100))%")
                        .font(MynaTheme.mono(10))
                        .foregroundStyle(MynaTheme.faint)
                case .running:
                    ProgressView().controlSize(.small)
                    Text("Transcribing…")
                        .font(MynaTheme.mono(10))
                        .foregroundStyle(MynaTheme.faint)
                case .idle:
                    if lab.isReady(engine) {
                        if lab.activeEngineID == engine.id {
                            Text("IN USE")
                                .font(MynaTheme.mono(10))
                                .tracking(1.5)
                                .foregroundStyle(MynaTheme.ink)
                        } else {
                            pill("Use") { lab.setActive(engine) }
                        }
                        if lab.hasClip { pill("Test") { lab.runOne(engine) } }
                        if engine.megabytes > 0 { pill("Remove") { lab.remove(engine) } }
                    } else if engine.isCloud {
                        if lab.activeEngineID != engine.id { pill("Use") { lab.setActive(engine) } }
                        Text("Add a key to run")
                            .font(MynaTheme.mono(10))
                            .foregroundStyle(MynaTheme.faint)
                    } else {
                        pill("Download") { lab.download(engine) }
                        if lab.activeEngineID == engine.id {
                            Text("CHOSEN · NOT DOWNLOADED")
                                .font(MynaTheme.mono(10))
                                .foregroundStyle(MynaTheme.faint)
                        }
                    }
                }
                Spacer()
            }

            if let outcome {
                if let error = outcome.error {
                    Text(error)
                        .font(.system(size: 12, weight: .light))
                        .foregroundStyle(MynaTheme.muted)
                } else {
                    Text(outcome.text)
                        .font(.system(size: 14, weight: .light))
                        .foregroundStyle(MynaTheme.ink)
                        .textSelection(.enabled)
                    HStack(spacing: 12) {
                        Text(timing(outcome.seconds))
                            .font(MynaTheme.mono(10))
                            .foregroundStyle(MynaTheme.faint)
                        Spacer()
                        stars(engine)
                    }
                }
            }
        }
    }

    /// Seconds taken, and how many times faster than real time that is.
    private func timing(_ seconds: Double) -> String {
        guard seconds > 0, lab.clipSeconds > 0 else { return "" }
        return String(format: "%.1f s · %.1f× real time", seconds, lab.clipSeconds / seconds)
    }

    private func stars(_ engine: LabEngine) -> some View {
        HStack(spacing: 4) {
            ForEach(1...5, id: \.self) { value in
                Button {
                    lab.ratings[engine.id] = (lab.ratings[engine.id] == value) ? 0 : value
                } label: {
                    Image(systemName: value <= (lab.ratings[engine.id] ?? 0) ? "star.fill" : "star")
                        .font(.system(size: 13))
                        .foregroundStyle(value <= (lab.ratings[engine.id] ?? 0) ? MynaTheme.ink : MynaTheme.faint)
                }
                .buttonStyle(.plain)
            }
        }
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
                .background(Capsule().fill(MynaTheme.veil))
                .overlay(Capsule().strokeBorder(MynaTheme.hair, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}
