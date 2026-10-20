import Foundation
import SwiftData
import SwiftUI
import UIKit

/// The conductor: watches the live transcript stream, decides when a
/// conversation has ended, hands it to the notes engine, files the note,
/// and (optionally) schedules any meetings it heard being planned.
///
/// When the model can't run (the phone is locked and only an MLX model is
/// installed), finished conversations wait in a queue and are composed the
/// moment Myna is back on screen — nothing heard is ever dropped.
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
    @Published private(set) var queuedCount = 0
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

    let listener: SpeechListener
    let scheduler = EventScheduler()
    weak var brain: MynaBrain?
    /// When set and enabled, finished conversations are transcribed with Whisper.
    var whisper: WhisperTranscriber?
    private let notesEngine: NotesEngine
    private var modelContext: ModelContext?
    private let contextHub: ContextHub
    private var isDraining = false
    private var lastSpeechAt: Date = .distantPast
    private var watchdog: Timer?

    init(listener: SpeechListener, modelManager: ModelManager, contextHub: ContextHub) {
        self.listener = listener
        self.contextHub = contextHub
        self.notesEngine = NotesEngine(modelManager: modelManager)

        listener.onFinalText = { [weak self] text, heardAt in
            guard let self else { return }
            if self.segmentStartedAt == nil {
                self.segmentStartedAt = heardAt
                // Start capturing this conversation's audio for Whisper.
                if self.whisper?.isEnabled == true { self.listener.beginSegmentCapture() }
            }
            self.segmentLines.append(TranscriptLine(text: text, heardAt: heardAt))
            self.lastSpeechAt = heardAt
        }
    }

    func attach(modelContext: ModelContext) {
        self.modelContext = modelContext
        refreshQueueCount()
    }

    // MARK: - Controls

    func startListening() {
        guard phase == .idle || phase == .composing else { return }
        listener.start()
        if listener.isListening {
            phase = .listening
            lastSpeechAt = .now
            startWatchdog()
        } else if let error = listener.lastError {
            banner = error
        }
    }

    func stopListening(composeRemainder: Bool = true) {
        watchdog?.invalidate()
        watchdog = nil
        listener.stop()
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
        let audioURL = listener.takeSegmentAudioURL()
        clearSegment()

        let transcript = lines.map(\.text).joined(separator: "\n")
        guard transcript.count > 40 else {
            if let audioURL { try? FileManager.default.removeItem(at: audioURL) }
            return
        }
        compose(transcript: transcript, startedAt: startedAt, endedAt: endedAt, sourceRef: "", audioPath: audioURL?.path)
    }

    private func compose(transcript: String, startedAt: Date, endedAt: Date, sourceRef: String, audioPath: String? = nil) {
        let wasListening = listener.isListening
        phase = .composing

        Task {
            // Where you are as the conversation ends — captured now, because a
            // queued conversation may be composed hours later somewhere else.
            let place = await contextHub.placeName()
            defer { if let audioPath { try? FileManager.default.removeItem(atPath: audioPath) } }
            do {
                try await composeAndFile(transcript: transcript, startedAt: startedAt, endedAt: endedAt, sourceRef: sourceRef, place: place, audioPath: audioPath)
            } catch MynaModelError.needsForeground {
                enqueue(transcript: transcript, startedAt: startedAt, endedAt: endedAt, sourceRef: sourceRef, place: place)
            } catch MynaModelError.noModelInstalled {
                enqueue(transcript: transcript, startedAt: startedAt, endedAt: endedAt, sourceRef: sourceRef, place: place)
                banner = "Heard a conversation — it'll become a note once a model is installed."
            } catch {
                if UIApplication.shared.applicationState == .background {
                    // e.g. Apple Intelligence's background budget ran out — try again later.
                    enqueue(transcript: transcript, startedAt: startedAt, endedAt: endedAt, sourceRef: sourceRef, place: place)
                } else {
                    fileTranscriptOnly(transcript: transcript, startedAt: startedAt, endedAt: endedAt, sourceRef: sourceRef, place: place, error: error)
                }
            }
            phase = wasListening && listener.isListening ? .listening : .idle
        }
    }

    private func composeAndFile(transcript rawTranscript: String, startedAt: Date, endedAt: Date, sourceRef: String, place: String, audioPath: String? = nil) async throws {
        var transcript = rawTranscript
        // Prefer Whisper's transcript of the captured audio when it's enabled and
        // produced something; otherwise keep Apple's live transcript.
        if let audioPath, let whisper, whisper.isEnabled, let better = await whisper.transcribe(path: audioPath) {
            transcript = better
        }
        let context = await contextHub.noteContext(transcript: transcript, startedAt: startedAt, endedAt: endedAt, place: place)
        let result = try await notesEngine.composeNote(
            transcript: transcript,
            startedAt: startedAt,
            endedAt: endedAt,
            sourceRef: sourceRef,
            context: context
        )
        let note = result.note
        if autoSchedule {
            scheduleEvents(in: note)
        }
        modelContext?.insert(note)
        try? modelContext?.save()
        brain?.absorb(result)
        notesComposedToday += 1
        banner = "✨ Note composed: \(note.title)"
        brain?.speakProactively("I just captured a note: \(note.title).")
    }

    /// Never lose what was heard — file the raw transcript as a note.
    private func fileTranscriptOnly(transcript: String, startedAt: Date, endedAt: Date, sourceRef: String, place: String, error: Error) {
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
            modelName: "",
            sourceRef: sourceRef
        )
        fallback.placeName = place
        modelContext?.insert(fallback)
        try? modelContext?.save()
        banner = "Saved the transcript — \(error.localizedDescription)"
    }

    // MARK: - Queue

    private func enqueue(transcript: String, startedAt: Date, endedAt: Date, sourceRef: String, place: String) {
        guard let modelContext else { return }
        modelContext.insert(PendingConversation(transcript: transcript, startedAt: startedAt, endedAt: endedAt, sourceRef: sourceRef, placeName: place))
        try? modelContext.save()
        refreshQueueCount()
    }

    /// Composes everything heard while the model couldn't run. Call when the
    /// app comes to the foreground.
    func drainQueue() {
        guard !isDraining, let modelContext else { return }
        let descriptor = FetchDescriptor<PendingConversation>(sortBy: [SortDescriptor(\.startedAt)])
        let pending = (try? modelContext.fetch(descriptor)) ?? []
        guard !pending.isEmpty else { return }
        isDraining = true
        let wasListening = listener.isListening
        phase = .composing
        Task {
            defer {
                isDraining = false
                refreshQueueCount()
                phase = wasListening && listener.isListening ? .listening : .idle
            }
            queue: for item in pending {
                do {
                    try await composeAndFile(transcript: item.transcript, startedAt: item.startedAt, endedAt: item.endedAt, sourceRef: item.sourceRef, place: item.placeName)
                    modelContext.delete(item)
                } catch MynaModelError.needsForeground {
                    break queue
                } catch MynaModelError.noModelInstalled {
                    break queue
                } catch {
                    item.attempts += 1
                    if item.attempts >= 2 {
                        fileTranscriptOnly(transcript: item.transcript, startedAt: item.startedAt, endedAt: item.endedAt, sourceRef: item.sourceRef, place: item.placeName, error: error)
                        modelContext.delete(item)
                    }
                }
                try? modelContext.save()
            }
        }
    }

    private func refreshQueueCount() {
        queuedCount = (try? modelContext?.fetchCount(FetchDescriptor<PendingConversation>())) ?? 0
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
