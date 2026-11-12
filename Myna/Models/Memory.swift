import Foundation
import SwiftData

/// A durable fact Myna keeps about you — distinct from a conversation. Omi's
/// "second brain": short, timeless statements distilled from what you talk
/// about, so Myna actually knows you over time. Two kinds, following Omi's
/// split: facts about you (`system`) and useful outside wisdom (`interesting`).
@Model
final class Memory {
    var id: UUID = UUID()
    var createdAt: Date = Date.now
    /// "system" (a fact about the user) or "interesting" (external wisdom).
    var categoryRaw: String = MemoryCategory.system.rawValue
    var content: String = ""
    /// The conversation this was distilled from, if any.
    var sourceNoteID: UUID?
    var pinned: Bool = false
    /// Omi keeps a short-term → long-term promotion; `archived` is our "set
    /// aside" so a memory leaves the main list without being lost.
    var archived: Bool = false
    var manuallyAdded: Bool = false

    init(content: String, category: MemoryCategory, sourceNoteID: UUID? = nil, manuallyAdded: Bool = false) {
        self.content = content
        self.categoryRaw = category.rawValue
        self.sourceNoteID = sourceNoteID
        self.manuallyAdded = manuallyAdded
    }

    var category: MemoryCategory {
        get { MemoryCategory(rawValue: categoryRaw) ?? .system }
        set { categoryRaw = newValue.rawValue }
    }
}

enum MemoryCategory: String, CaseIterable {
    case system       // a fact about the user
    case interesting  // external wisdom/advice the user could learn from

    var title: String {
        switch self {
        case .system: return "About you"
        case .interesting: return "Worth remembering"
        }
    }

    var icon: String {
        switch self {
        case .system: return "person.text.rectangle"
        case .interesting: return "lightbulb"
        }
    }
}
