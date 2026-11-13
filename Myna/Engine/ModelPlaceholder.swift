import Foundation

/// Did a local model echo a prompt's schema placeholder (`"..."`, `"<title>"`,
/// a field description) instead of producing real content? Weaker on-device
/// models do this, and it must never reach a saved note, task or memory.
///
/// Shared by every extractor (notes, action items, memories) and the assistant,
/// so one definition guards them all. Pure string work — no model dependency —
/// so it lives apart from the engine and is unit-testable on any platform.
enum ModelPlaceholder {
    static func looksLikePlaceholder(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return true }
        if t.allSatisfy({ $0 == "." || $0 == "…" }) { return true }   // "...", "…"
        // EXACT match only — a weak model that echoes a template copies the
        // placeholder verbatim, so exact matching catches the real failure mode
        // with zero risk of wiping a legitimate note that merely *mentions* one
        // of these phrases (substring matching did exactly that and lost data).
        return exactPlaceholders.contains(t.lowercased())
    }

    /// The verbatim placeholder values used in the prompts across NotesEngine,
    /// ConversationExtractor and MynaBrain. Owner-interpolated fields list the
    /// "the user" default; short "..." placeholders are caught above.
    private static let exactPlaceholders: Set<String> = [
        "short, vivid title for this conversation",
        "2-3 sentence summary",
        "thorough narrative notes covering everything substantive that was discussed, organized into short paragraphs; preserve names, numbers, dates and context",
        "the most important takeaways",
        "decisions that were made, empty array if none",
        "a short to-do the owner committed to",
        "something the owner needs to buy",
        "what the owner should be reminded of",
        "the item to check off",
        "what you say back, spoken aloud",
        "<write one to three spoken sentences that actually answer the user — real words, never this placeholder>",
    ]
}
