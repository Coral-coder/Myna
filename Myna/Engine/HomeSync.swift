import Foundation
import SwiftData

/// Keeps this iPhone and the home computer's database in step. Every minute or
/// so, while the home server answers, it sends what changed here (transcript
/// lines, notes, memories, list items, people) and takes in what changed there.
/// The newest edit of a record wins. Nothing here depends on the server: if it
/// is away, the phone carries on and catches up later.
@MainActor
final class HomeSync: ObservableObject {
    static let shared = HomeSync()

    @Published private(set) var lastSync: Date?
    @Published private(set) var lastError: String?
    /// How many records the home computer holds a copy of.
    @Published private(set) var syncedCount = 0
    @Published private(set) var isSyncing = false

    private var container: ModelContainer?
    private var loop: Task<Void, Never>?

    private init() {}

    func start(container: ModelContainer) {
        self.container = container
        guard loop == nil else { return }
        loop = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            while !Task.isCancelled {
                await self?.syncNow()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    func syncNow() async {
        let server = HomeServer.shared
        guard let container, !isSyncing, server.isPaired, server.enabled, server.reachable == true else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            let count = try await Task.detached(priority: .utility) {
                try await HomeSyncRun.run(container: container)
            }.value
            syncedCount = count
            lastSync = Date()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Forget what has been sent, so the next sync compares everything again.
    /// Used when pairing with a different computer.
    func reset() {
        HomeSyncState.erase()
        lastSync = nil
        syncedCount = 0
    }
}

// MARK: - What is remembered between syncs

/// For each record already on the home computer, a fingerprint of what was
/// sent, so only records that are new or changed are sent again.
struct HomeSyncState: Codable {
    var cursor = 0
    var sent: [String: [String: String]] = [:]

    private static var file: URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("home-sync.json")
    }

    static func load() -> HomeSyncState {
        guard let data = try? Data(contentsOf: file),
              let state = try? JSONDecoder().decode(HomeSyncState.self, from: data) else { return HomeSyncState() }
        return state
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { try? data.write(to: Self.file, options: .atomic) }
    }

    static func erase() {
        try? FileManager.default.removeItem(at: file)
    }

    var total: Int { sent.values.reduce(0) { $0 + $1.count } }
}

// MARK: - Records that sync

/// A kind of record that is copied to the home computer.
protocol HomeSyncRecord: PersistentModel {
    static var syncKind: String { get }
    var syncID: String { get }
    /// The record as plain values (text, numbers, lists) for JSON.
    func syncData() -> [String: Any]
    /// Take on the values of a copy that came from the home computer.
    func syncApply(_ data: [String: Any])
    /// A new, empty record with this identity.
    static func syncMake(id: String) -> Self?
}

private func syncSeconds(_ value: Date?) -> Any {
    if let value { return value.timeIntervalSince1970 }
    return NSNull()
}

private func syncDate(_ value: Any?) -> Date? {
    guard let number = value as? Double else { return nil }
    return Date(timeIntervalSince1970: number)
}

private func syncText(_ value: Any?) -> String { (value as? String) ?? "" }
private func syncTexts(_ value: Any?) -> [String] { (value as? [String]) ?? [] }

extension Utterance: HomeSyncRecord {
    static var syncKind: String { "utterance" }
    var syncID: String { id.uuidString }

    func syncData() -> [String: Any] {
        ["heardAt": syncSeconds(heardAt), "text": text, "duration": duration, "engine": engine, "speaker": speakerKey,
         "context": context, "segment": segment]
    }

    func syncApply(_ data: [String: Any]) {
        heardAt = syncDate(data["heardAt"]) ?? heardAt
        text = syncText(data["text"])
        duration = data["duration"] as? Double ?? 0
        engine = syncText(data["engine"])
        speakerKey = syncText(data["speaker"])
        context = syncText(data["context"])
        segment = syncText(data["segment"])
    }

    static func syncMake(id: String) -> Utterance? {
        guard let uuid = UUID(uuidString: id) else { return nil }
        let record = Utterance(text: "", heardAt: .now, duration: 0, engine: "", speakerKey: "", embedding: nil)
        record.id = uuid
        return record
    }
}

extension Memory: HomeSyncRecord {
    static var syncKind: String { "memory" }
    var syncID: String { id.uuidString }

    func syncData() -> [String: Any] {
        ["createdAt": syncSeconds(createdAt), "category": categoryRaw, "content": content,
         "sourceNoteID": sourceNoteID?.uuidString ?? "", "pinned": pinned, "archived": archived,
         "manuallyAdded": manuallyAdded]
    }

    func syncApply(_ data: [String: Any]) {
        createdAt = syncDate(data["createdAt"]) ?? createdAt
        categoryRaw = data["category"] as? String ?? categoryRaw
        content = syncText(data["content"])
        sourceNoteID = UUID(uuidString: syncText(data["sourceNoteID"]))
        pinned = data["pinned"] as? Bool ?? false
        archived = data["archived"] as? Bool ?? false
        manuallyAdded = data["manuallyAdded"] as? Bool ?? false
    }

    static func syncMake(id: String) -> Memory? {
        guard let uuid = UUID(uuidString: id) else { return nil }
        let record = Memory(content: "", category: .system)
        record.id = uuid
        return record
    }
}

extension MynaItem: HomeSyncRecord {
    static var syncKind: String { "item" }
    var syncID: String { id.uuidString }

    func syncData() -> [String: Any] {
        ["kind": kindRaw, "text": text, "detail": detail, "dueDate": syncSeconds(dueDate), "isDone": isDone,
         "createdAt": syncSeconds(createdAt), "completedAt": syncSeconds(completedAt), "source": sourceRaw,
         "noteID": noteID?.uuidString ?? ""]
    }

    func syncApply(_ data: [String: Any]) {
        kindRaw = data["kind"] as? String ?? kindRaw
        text = syncText(data["text"])
        detail = syncText(data["detail"])
        dueDate = syncDate(data["dueDate"])
        isDone = data["isDone"] as? Bool ?? false
        createdAt = syncDate(data["createdAt"]) ?? createdAt
        completedAt = syncDate(data["completedAt"])
        sourceRaw = data["source"] as? String ?? sourceRaw
        noteID = UUID(uuidString: syncText(data["noteID"]))
    }

    static func syncMake(id: String) -> MynaItem? {
        guard let uuid = UUID(uuidString: id) else { return nil }
        let record = MynaItem(kind: .todo, text: "", source: .typed)
        record.id = uuid
        return record
    }
}

extension HeardSong: HomeSyncRecord {
    static var syncKind: String { "song" }
    var syncID: String { id.uuidString }

    func syncData() -> [String: Any] {
        ["shazamID": shazamID, "title": title, "artist": artist, "appleMusicURL": appleMusicURL,
         "artworkURL": artworkURL, "isrc": isrc, "firstHeard": syncSeconds(firstHeard),
         "lastHeard": syncSeconds(lastHeard), "timesHeard": timesHeard]
    }

    func syncApply(_ data: [String: Any]) {
        shazamID = syncText(data["shazamID"])
        title = syncText(data["title"])
        artist = syncText(data["artist"])
        appleMusicURL = syncText(data["appleMusicURL"])
        artworkURL = syncText(data["artworkURL"])
        isrc = syncText(data["isrc"])
        firstHeard = syncDate(data["firstHeard"]) ?? firstHeard
        lastHeard = syncDate(data["lastHeard"]) ?? lastHeard
        timesHeard = data["timesHeard"] as? Int ?? timesHeard
    }

    static func syncMake(id: String) -> HeardSong? {
        guard let uuid = UUID(uuidString: id) else { return nil }
        let record = HeardSong(shazamID: "", title: "", artist: "", appleMusicURL: "", artworkURL: "", isrc: "")
        record.id = uuid
        return record
    }
}

extension VoicePerson: HomeSyncRecord {
    static var syncKind: String { "person" }
    var syncID: String { key }

    func syncData() -> [String: Any] {
        ["name": name, "createdAt": syncSeconds(createdAt), "sampleCount": sampleCount, "isNamed": isNamed,
         "voice": centroid.base64EncodedString()]
    }

    func syncApply(_ data: [String: Any]) {
        name = syncText(data["name"])
        createdAt = syncDate(data["createdAt"]) ?? createdAt
        sampleCount = data["sampleCount"] as? Int ?? sampleCount
        isNamed = data["isNamed"] as? Bool ?? false
        if let voice = Data(base64Encoded: syncText(data["voice"])), !voice.isEmpty { centroid = voice }
    }

    static func syncMake(id: String) -> VoicePerson? {
        let record = VoicePerson(name: "", centroid: Data())
        record.key = id
        return record
    }
}

extension ConversationNote: HomeSyncRecord {
    static var syncKind: String { "note" }
    var syncID: String { id.uuidString }

    private static func plain<T: Encodable>(_ value: T) -> Any {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value),
              let object = try? JSONSerialization.jsonObject(with: data) else { return [Any]() }
        return object
    }

    private static func typed<T: Decodable>(_ type: T.Type, _ value: Any?) -> T? {
        guard let value, JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(type, from: data)
    }

    func syncData() -> [String: Any] {
        ["createdAt": syncSeconds(createdAt), "startedAt": syncSeconds(startedAt), "endedAt": syncSeconds(endedAt),
         "title": title, "overview": overview, "detailedNotes": detailedNotes, "keyPoints": keyPoints,
         "decisions": decisions, "actionItems": Self.plain(actionItems), "detectedEvents": Self.plain(detectedEvents),
         "followUps": followUps, "transcript": transcript, "modelName": modelName, "sourceRef": sourceRef,
         "placeName": placeName, "people": people]
    }

    func syncApply(_ data: [String: Any]) {
        createdAt = syncDate(data["createdAt"]) ?? createdAt
        startedAt = syncDate(data["startedAt"]) ?? startedAt
        endedAt = syncDate(data["endedAt"]) ?? endedAt
        title = syncText(data["title"])
        overview = syncText(data["overview"])
        detailedNotes = syncText(data["detailedNotes"])
        keyPoints = syncTexts(data["keyPoints"])
        decisions = syncTexts(data["decisions"])
        actionItems = Self.typed([ActionItem].self, data["actionItems"]) ?? []
        detectedEvents = Self.typed([DetectedEvent].self, data["detectedEvents"]) ?? []
        followUps = syncTexts(data["followUps"])
        transcript = syncText(data["transcript"])
        modelName = syncText(data["modelName"])
        sourceRef = syncText(data["sourceRef"])
        placeName = syncText(data["placeName"])
        people = syncTexts(data["people"])
    }

    static func syncMake(id: String) -> ConversationNote? {
        guard let uuid = UUID(uuidString: id) else { return nil }
        let record = ConversationNote(startedAt: .now, endedAt: .now, title: "", overview: "", detailedNotes: "",
                                      keyPoints: [], decisions: [], actionItems: [], detectedEvents: [],
                                      followUps: [], transcript: "", modelName: "")
        record.id = uuid
        return record
    }
}

// MARK: - One sync

enum HomeSyncRun {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// One kind's records on this phone, with what is needed to compare, send
    /// and take in changes without knowing the concrete type.
    private struct Shelf {
        let kind: String
        let fingerprints: [String: String]
        let data: (String) -> [String: Any]?
        let apply: (String, [String: Any]) -> String?
        let remove: (String) -> Void
    }

    private static func fingerprint(_ data: [String: Any]) -> String {
        guard let bytes = try? JSONSerialization.data(withJSONObject: data, options: [.sortedKeys]) else { return "" }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in bytes {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    private static func makeShelf<T: HomeSyncRecord>(_ type: T.Type, in context: ModelContext) throws -> Shelf {
        var records: [String: T] = [:]
        for record in try context.fetch(FetchDescriptor<T>()) { records[record.syncID] = record }
        var prints: [String: String] = [:]
        for (id, record) in records { prints[id] = fingerprint(record.syncData()) }
        let box = RecordBox(records)
        return Shelf(
            kind: T.syncKind,
            fingerprints: prints,
            data: { id in box.records[id]?.syncData() },
            apply: { id, data in
                let record: T
                if let existing = box.records[id] {
                    record = existing
                } else if let made = T.syncMake(id: id) {
                    context.insert(made)
                    box.records[id] = made
                    record = made
                } else {
                    return nil
                }
                record.syncApply(data)
                return fingerprint(record.syncData())
            },
            remove: { id in
                if let record = box.records.removeValue(forKey: id) { context.delete(record) }
            }
        )
    }

    private final class RecordBox<T> {
        var records: [String: T]
        init(_ records: [String: T]) { self.records = records }
    }

    /// Sends what changed here, takes in what changed there. Returns how many
    /// records the home computer now has a copy of.
    static func run(container: ModelContainer) async throws -> Int {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        var state = HomeSyncState.load()

        var shelves: [String: Shelf] = [:]
        let all = try [makeShelf(Utterance.self, in: context), makeShelf(ConversationNote.self, in: context),
                       makeShelf(Memory.self, in: context), makeShelf(MynaItem.self, in: context),
                       makeShelf(VoicePerson.self, in: context), makeShelf(HeardSong.self, in: context)]
        for one in all { shelves[one.kind] = one }

        // What to send: new or changed records, and ones deleted here since.
        struct Outgoing {
            let kind: String
            let id: String
            let mark: String?
        }
        var outgoing: [Outgoing] = []
        for (kind, shelf) in shelves {
            let sent = state.sent[kind] ?? [:]
            for (id, mark) in shelf.fingerprints where sent[id] != mark {
                outgoing.append(Outgoing(kind: kind, id: id, mark: mark))
            }
            // If this phone suddenly has none of a kind, something is wrong
            // with its storage; don't tell the computer to delete everything.
            if !shelf.fingerprints.isEmpty {
                for id in sent.keys where shelf.fingerprints[id] == nil {
                    outgoing.append(Outgoing(kind: kind, id: id, mark: nil))
                }
            }
        }

        let now = Date().timeIntervalSince1970
        var index = 0
        var more = true
        var rounds = 0
        while (index < outgoing.count || more) && rounds < 2_000 {
            rounds += 1
            let batch = Array(outgoing[index..<min(index + 150, outgoing.count)])
            index += batch.count
            let changes: [[String: Any]] = batch.map { item in
                var change: [String: Any] = ["kind": item.kind, "id": item.id, "updated_at": now, "deleted": item.mark == nil]
                if item.mark != nil, let data = shelves[item.kind]?.data(item.id) { change["data"] = data }
                return change
            }
            let body = try JSONSerialization.data(withJSONObject: ["since": state.cursor, "changes": changes])
            let reply = try await HomeServer.shared.syncExchange(body)
            guard let json = try JSONSerialization.jsonObject(with: reply) as? [String: Any],
                  let cursor = json["cursor"] as? Int else {
                throw Failure(message: "The home server sent an answer Myna couldn't read.")
            }

            for item in batch {
                if let mark = item.mark {
                    state.sent[item.kind, default: [:]][item.id] = mark
                } else {
                    state.sent[item.kind]?.removeValue(forKey: item.id)
                }
            }
            for change in json["changes"] as? [[String: Any]] ?? [] {
                guard let kind = change["kind"] as? String, let id = change["id"] as? String,
                      let shelf = shelves[kind] else { continue }
                if change["deleted"] as? Bool == true {
                    shelf.remove(id)
                    state.sent[kind]?.removeValue(forKey: id)
                } else if let data = change["data"] as? [String: Any], let mark = shelf.apply(id, data) {
                    state.sent[kind, default: [:]][id] = mark
                }
            }
            if context.hasChanges { try context.save() }
            state.cursor = cursor
            state.save()
            more = json["more"] as? Bool ?? false
        }
        return state.total
    }
}
