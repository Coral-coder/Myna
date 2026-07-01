import Foundation
import SwiftData
import SwiftUI

/// The conductor: watches the live transcript stream, decides when a
/// conversation has ended, hands it to the notes engine, files the note,
/// and (optionally) schedules any meetings it heard being planned.
@MainActor
final class ConversationPilot: ObservableObject {

    struct TranscriptLine: Identifiable, Equatable {
        let id = UUID()
        let text: String
        let heardAt: Date
    }

    enum Phase: Equatable {
        case idle
        case listening
        case composing
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var segmentLines: [TranscriptLine] = []
    @Published private(set) var segmentStartedAt: Date?
    @Published private(set) var notesComposedToday = 0
    @Published private(set) var eventsScheduledToday = 0
    @Published var banner: String?

    // Tunables owned by SettingsView via @AppStorage; read live so changes
    // apply to the very next tick.
    var silenceThreshold: Double {
        let value = UserDefaults.standard.double(forKey: "myna.silenceThreshold")
        return value > 0 ? value : 90
    }

    var maxSegmentMinutes: Int {
        let value = UserDefaults.standard.integer(forKey: "myna.maxSegmentMinutes")
        return value > 0 ? value : 20
    }

    var autoSchedule: Bool {
        UserDefaults.standard.object(forKey: "myna.autoSchedule") as? Bool ?? true
    }

    let capture: AudioCaptureEngine
    let transcriber: WhisperTranscriber
    let scheduler = EventScheduler()
    private let notesEngine: NotesEngine
    private var modelContext: ModelContext?
    private var lastSpeechAt: Date = .distantPast
    private var watchdog: Timer?

    init(capture: AudioCaptureEngine, transcriber: WhisperTranscriber, modelManager: ModelManager) {
        self.capture = capture
        self.transcriber = transcriber
        self.notesEngine = NotesEngine(modelManager: modelManager)

        // Each completed utterance is transcribed by Whisper, then appended to
        // the running conversation transcript.
        capture.onUtterance = { [weak self] samples, heardAt in
            guard let self else { return }
            Task { await self.handleUtterance(samples, heardAt: heardAt) }
        }
    }

    private func handleUtterance(_ samples: [Float], heardAt: Date) async {
        let text = await transcriber.transcribe(samples)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if segmentStartedAt == nil {
            segmentStartedAt = heardAt
        }
        segmentLines.append(TranscriptLine(text: trimmed, heardAt: heardAt))
        lastSpeechAt = heardAt
    }

    func attach(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    // MARK: - Controls

    func startListening() {
        guard phase == .idle || phase == .composing else { return }
        capture.start()
        if capture.isRunning {
            phase = .listening
            lastSpeechAt = .now
            startWatchdog()
        } else if let error = capture.lastError {
            banner = error
        }
    }

    func stopListening(composeRemainder: Bool = true) {
        watchdog?.invalidate()
        watchdog = nil
        capture.stop()
        if composeRemainder, hasMeaningfulContent {
            finalizeSegment()
        } else {
            clearSegment()
        }
        if phase == .listening { phase = .idle }
    }

    /// "Conclude & Compose" — wrap up the current conversation right now,
    /// keep listening for the next one.
    func composeNow() {
        guard hasMeaningfulContent else { return }
        finalizeSegment()
    }

    var hasMeaningfulContent: Bool {
        segmentLines.map(\.text).joined(separator: " ").count > 40
    }

    var liveTranscriptTail: [TranscriptLine] {
        Array(segmentLines.suffix(4))
    }

    // MARK: - Segmentation

    private func startWatchdog() {
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        guard phase == .listening, hasMeaningfulContent, let started = segmentStartedAt else { return }
        let silentFor = Date.now.timeIntervalSince(lastSpeechAt)
        let runningFor = Date.now.timeIntervalSince(started)
        // A long pause means the conversation ended; very long meetings get
        // composed in installments so notes stay timely and prompts stay small.
        if silentFor > silenceThreshold || runningFor > Double(maxSegmentMinutes * 60) {
            finalizeSegment()
        }
    }

    private func finalizeSegment() {
        let lines = segmentLines
        let startedAt = segmentStartedAt ?? .now
        let endedAt = lastSpeechAt == .distantPast ? Date.now : lastSpeechAt
        clearSegment()

        let transcript = lines.map(\.text).joined(separator: "\n")
        guard transcript.count > 40 else { return }

        let wasListening = capture.isRunning
        phase = .composing

        Task {
            do {
                let note = try await notesEngine.composeNote(
                    transcript: transcript,
                    startedAt: startedAt,
                    endedAt: endedAt
                )
                if autoSchedule {
                    scheduleEvents(in: note)
                }
                modelContext?.insert(note)
                try? modelContext?.save()
                notesComposedToday += 1
                banner = "✨ Note composed: \(note.title)"
            } catch {
                // Never lose what was heard — file the raw transcript as a note.
                let fallback = ConversationNote(
                    startedAt: startedAt,
                    endedAt: endedAt,
                    title: "Conversation (transcript only)",
                    overview: error.localizedDescription,
                    detailedNotes: "",
                    keyPoints: [],
                    decisions: [],
                    actionItems: [],
                    detectedEvents: [],
                    followUps: [],
                    transcript: transcript,
                    modelName: ""
                )
                modelContext?.insert(fallback)
                try? modelContext?.save()
                banner = "Saved the transcript — \(error.localizedDescription)"
            }
            phase = wasListening && capture.isRunning ? .listening : .idle
        }
    }

    private func scheduleEvents(in note: ConversationNote) {
        guard scheduler.hasAccess else { return }
        var events = note.detectedEvents
        for index in events.indices where events[index].startDate != nil && (events[index].confidence ?? 1.0) >= 0.6 {
            if let identifier = try? scheduler.schedule(events[index]) {
                events[index].calendarEventID = identifier
                eventsScheduledToday += 1
            }
        }
        note.detectedEvents = events
    }

    private func clearSegment() {
        segmentLines = []
        segmentStartedAt = nil
    }
}
