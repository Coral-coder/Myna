import Foundation

/// Watches a live, still-changing transcript for "Myna, …" and decides when a
/// spoken command is finished, so Myna can act a beat after you stop talking
/// instead of waiting for the speech recognizer to finalize a whole sentence.
///
/// Feed it every partial transcript of the current recognition task, call
/// `tick` on a timer, and `finish` when the task ends. Each command comes out
/// exactly once.
struct CommandSpotter {
    /// Quiet time after which a command that already makes sense is acted on.
    var settleDelay: TimeInterval = 1.4
    /// Longest wait for a command that doesn't (yet) parse as anything specific.
    var patienceDelay: TimeInterval = 3.2

    private var handledCount = 0
    private var pending: (text: String, since: Date)?

    /// Commands finished because another wake word followed them.
    mutating func observe(partial: String, at time: Date) -> [String] {
        let commands = CommandParser.commandsFollowingWakeWord(in: partial)
        guard commands.count > handledCount else {
            pending = nil
            return []
        }
        var ready: [String] = []
        for index in handledCount..<(commands.count - 1) where !commands[index].isEmpty {
            ready.append(commands[index])
        }
        handledCount = commands.count - 1
        let last = commands[commands.count - 1]
        if pending?.text != last {
            pending = (last, time)
        }
        return ready
    }

    /// The pending command, once the speaker has paused long enough.
    mutating func tick(at time: Date, now: Date = .now) -> String? {
        guard let pending, !pending.text.isEmpty else { return nil }
        let quiet = time.timeIntervalSince(pending.since)
        var looksComplete = !Self.endsMidThought(pending.text)
        if case .ask = CommandParser.parse(pending.text, now: now) {
            looksComplete = false
        }
        guard (quiet >= settleDelay && looksComplete) || quiet >= patienceDelay else { return nil }
        handledCount += 1
        self.pending = nil
        return pending.text
    }

    /// Call with the recognizer's final text; returns commands not yet acted on
    /// and resets for the next recognition task.
    mutating func finish(final: String) -> [String] {
        let commands = CommandParser.commandsFollowingWakeWord(in: final)
        let remaining = commands.count > handledCount ? Array(commands[handledCount...]) : []
        handledCount = 0
        pending = nil
        return remaining.filter { !$0.isEmpty }
    }

    mutating func reset() {
        handledCount = 0
        pending = nil
    }

    /// "add eggs and" / "remind me to" — clearly still talking.
    static func endsMidThought(_ text: String) -> Bool {
        let lastWord = text.lowercased().split(separator: " ").last.map(String.init) ?? ""
        return ["and", "to", "the", "a", "an", "at", "on", "for", "with", "my", "of", "that", "about", "remind", "add", "me", "um", "uh"].contains(lastWord)
    }
}
