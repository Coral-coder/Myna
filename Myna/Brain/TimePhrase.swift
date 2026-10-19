import Foundation

/// Finds and resolves spoken time phrases — "in 20 minutes", "tomorrow at 9",
/// "next Tuesday at 2 pm", "tonight", "at noon" — without touching the GPU, so
/// voice commands resolve instantly even while the phone is locked.
///
/// Speech recognition already writes times as digits ("5:30 PM"), but small
/// number words ("at five") are understood too. Anything this parser can't
/// place falls back to `NSDataDetector` on Apple platforms.
enum TimePhrase {

    struct Match: Equatable {
        /// The resolved moment.
        var date: Date
        /// Whether a clock time was spoken (vs. just a day like "tomorrow").
        var hasTime: Bool
        /// The text with the time phrase removed, tidied up.
        var remainder: String
        /// The phrase as heard.
        var phrase: String
    }

    /// Finds the first time phrase in `text`, resolved relative to `now`.
    static func find(in text: String, now: Date = .now, calendar: Calendar = .current) -> Match? {
        let lowered = text.lowercased()
        var matchedRanges: [Range<String.Index>] = []
        var day: Date?
        var dayIsExplicit = false
        var hour: Int?
        var minute = 0
        var meridiem: String?
        var partOfDay: Int?
        var relative: Date?

        // 1. Relative offsets: "in 20 minutes", "in an hour and a half", "in half an hour".
        if let match = firstMatch(#"\bin (?:(\d+|an?|one|two|three|four|five|six|seven|eight|nine|ten|fifteen|twenty|thirty|forty five|forty|fifty|a few|a couple of|half an?) )?(?:(half) )?(minute|min|hour|hr|day|week)s?(?: and a half)?\b"#, in: lowered) {
            let quantityText = match.groups[0] ?? "1"
            let unit = match.groups[2] ?? "minute"
            var quantity = Double(numberValue(quantityText) ?? 1)
            if quantityText.hasPrefix("half") { quantity = 0.5 }
            if lowered[match.range].hasSuffix("and a half") { quantity += 0.5 }
            let seconds: Double
            switch unit {
            case "minute", "min": seconds = 60
            case "hour", "hr": seconds = 3600
            case "day": seconds = 86_400
            default: seconds = 604_800
            }
            relative = now.addingTimeInterval(quantity * seconds)
            matchedRanges.append(match.range)
        }

        // 2. Days: today / tonight / tomorrow / weekdays / next week.
        let startOfToday = calendar.startOfDay(for: now)
        if relative == nil {
            if let match = firstMatch(#"\b(?:the )?day after tomorrow\b"#, in: lowered) {
                day = calendar.date(byAdding: .day, value: 2, to: startOfToday)
                dayIsExplicit = true
                matchedRanges.append(match.range)
            } else if let match = firstMatch(#"\btomorrow(?: (morning|afternoon|evening|night))?\b"#, in: lowered) {
                day = calendar.date(byAdding: .day, value: 1, to: startOfToday)
                dayIsExplicit = true
                partOfDay = match.groups[0].flatMap(hourFor(partOfDay:))
                matchedRanges.append(match.range)
            } else if let match = firstMatch(#"\b(tonight|this (morning|afternoon|evening)|today)\b"#, in: lowered) {
                day = startOfToday
                dayIsExplicit = true
                if match.groups[0] == "tonight" {
                    partOfDay = 20
                } else if let part = match.groups[1] {
                    partOfDay = hourFor(partOfDay: part)
                }
                matchedRanges.append(match.range)
            } else if let match = firstMatch(#"\b(?:(on|this|next|coming) )?(monday|tuesday|wednesday|thursday|friday|saturday|sunday)(?: (morning|afternoon|evening|night))?\b"#, in: lowered),
                      let weekdayName = match.groups[1],
                      let weekday = weekdayNumber(weekdayName) {
                var candidate = nextDate(weekday: weekday, after: startOfToday, calendar: calendar)
                if match.groups[0] == "next",
                   let days = calendar.dateComponents([.day], from: startOfToday, to: candidate).day,
                   days <= 2 {
                    // "next Tuesday" said on a Monday means a week from tomorrow.
                    candidate = calendar.date(byAdding: .day, value: 7, to: candidate) ?? candidate
                }
                day = candidate
                dayIsExplicit = true
                partOfDay = match.groups[2].flatMap(hourFor(partOfDay:))
                matchedRanges.append(match.range)
            } else if let match = firstMatch(#"\bnext week\b"#, in: lowered) {
                day = nextDate(weekday: 2, after: startOfToday, calendar: calendar)
                dayIsExplicit = true
                matchedRanges.append(match.range)
            }
        }

        // 3. Clock times: "at 5", "at 5:30 pm", "5 pm", "at noon", "17:00", "at five".
        if relative == nil {
            if let match = firstMatch(#"\b(?:at |by |around )?(noon|midday|midnight)\b"#, in: lowered) {
                hour = match.groups[0] == "midnight" ? 0 : 12
                meridiem = "set"
                matchedRanges.append(match.range)
            } else if let match = firstMatch(#"(?:\b(?:at|by|around|for) )?\b(\d{1,2})(?::(\d{2})| (\d{2})(?= ?[ap]\.?m))? ?([ap])\.? ?m\.?(?=\W|$)"#, in: lowered) {
                hour = Int(match.groups[0] ?? "")
                minute = Int(match.groups[1] ?? match.groups[2] ?? "0") ?? 0
                meridiem = match.groups[3]
                matchedRanges.append(match.range)
            } else if let match = firstMatch(#"\b(?:at|by|around) (\d{1,2})(?::(\d{2}))?(?: o'?clock)?\b"#, in: lowered) {
                hour = Int(match.groups[0] ?? "")
                minute = Int(match.groups[1] ?? "0") ?? 0
                matchedRanges.append(match.range)
            } else if let match = firstMatch(#"\b(\d{1,2}):(\d{2})\b"#, in: lowered) {
                hour = Int(match.groups[0] ?? "")
                minute = Int(match.groups[1] ?? "0") ?? 0
                matchedRanges.append(match.range)
            } else if let match = firstMatch(#"\b(?:at|by|around) (one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve)(?: (thirty|fifteen|forty five))?(?: o'?clock)?(?: ?([ap])\.? ?m\.?)?\b"#, in: lowered) {
                hour = numberValue(match.groups[0] ?? "")
                minute = match.groups[1].flatMap(numberValue) ?? 0
                meridiem = match.groups[2]
                matchedRanges.append(match.range)
            }
        }

        var resolved: Date?
        var hasTime = false

        if let relative {
            resolved = relative
            hasTime = true
        } else if var hour {
            hasTime = true
            let base = day ?? startOfToday
            if meridiem == "p", hour < 12 { hour += 12 }
            if meridiem == "a", hour == 12 { hour = 0 }
            if meridiem == nil, hour <= 12 {
                if let partOfDay, partOfDay >= 12, hour < 12 {
                    hour += 12
                } else if dayIsExplicit && day != startOfToday {
                    // A bare "at 3" on another day almost always means 3 pm.
                    if hour >= 1 && hour <= 6 { hour += 12 }
                } else {
                    // Today: take the next occurrence of h or h+12.
                    let morning = at(hour: hour == 12 ? 12 : hour, minute: minute, on: base, calendar: calendar)
                    let evening = hour < 12 ? at(hour: hour + 12, minute: minute, on: base, calendar: calendar) : nil
                    if let morning, morning > now, hour >= 7 || hour == 12 {
                        resolved = morning
                    } else if let evening, evening > now {
                        resolved = evening
                    } else if let morning, morning > now {
                        resolved = morning
                    }
                }
            }
            if resolved == nil, hour < 24 {
                resolved = at(hour: hour, minute: minute, on: base, calendar: calendar)
                if let candidate = resolved, candidate <= now, !dayIsExplicit {
                    resolved = calendar.date(byAdding: .day, value: 1, to: candidate)
                }
            }
        } else if let day {
            let defaultHour = partOfDay ?? 9
            resolved = at(hour: defaultHour, minute: 0, on: day, calendar: calendar)
            hasTime = partOfDay != nil
            if let candidate = resolved, candidate <= now {
                // "today" with no time, or "this morning" already passed: an hour from now.
                resolved = now.addingTimeInterval(3600)
            }
        }

        if resolved == nil {
            return detectorFallback(in: text, now: now)
        }

        let phrase = matchedRanges
            .sorted { $0.lowerBound < $1.lowerBound }
            .map { String(lowered[$0]).trimmingCharacters(in: .whitespaces) }
            .joined(separator: " ")
        return Match(
            date: resolved!,
            hasTime: hasTime,
            remainder: remove(ranges: matchedRanges, from: text),
            phrase: phrase
        )
    }

    // MARK: - Helpers

    private struct RegexMatch {
        var range: Range<String.Index>
        var groups: [String?]
    }

    private static func firstMatch(_ pattern: String, in text: String) -> RegexMatch? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let nsRange = NSRange(text.startIndex..., in: text)
        guard let result = regex.firstMatch(in: text, options: [], range: nsRange),
              let range = Range(result.range, in: text) else { return nil }
        var groups: [String?] = []
        if result.numberOfRanges > 1 {
            for index in 1..<result.numberOfRanges {
                let groupRange = result.range(at: index)
                if groupRange.location != NSNotFound, let swiftRange = Range(groupRange, in: text) {
                    groups.append(String(text[swiftRange]))
                } else {
                    groups.append(nil)
                }
            }
        }
        return RegexMatch(range: range, groups: groups)
    }

    static func numberValue(_ word: String) -> Int? {
        if let value = Int(word) { return value }
        let words: [String: Int] = [
            "a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
            "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11,
            "twelve": 12, "fifteen": 15, "twenty": 20, "thirty": 30, "forty": 40,
            "forty five": 45, "fifty": 50, "a few": 5, "a couple of": 2,
        ]
        return words[word]
    }

    private static func hourFor(partOfDay: String) -> Int? {
        switch partOfDay {
        case "morning": return 9
        case "afternoon": return 14
        case "evening": return 18
        case "night": return 20
        default: return nil
        }
    }

    private static func weekdayNumber(_ name: String) -> Int? {
        ["sunday": 1, "monday": 2, "tuesday": 3, "wednesday": 4, "thursday": 5, "friday": 6, "saturday": 7][name]
    }

    /// The next date (strictly after `start`'s day) that falls on `weekday`.
    private static func nextDate(weekday: Int, after start: Date, calendar: Calendar) -> Date {
        let current = calendar.component(.weekday, from: start)
        var delta = (weekday - current + 7) % 7
        if delta == 0 { delta = 7 }
        return calendar.date(byAdding: .day, value: delta, to: start) ?? start
    }

    private static func at(hour: Int, minute: Int, on day: Date, calendar: Calendar) -> Date? {
        calendar.date(bySettingHour: hour % 24, minute: minute, second: 0, of: day)
    }

    private static func remove(ranges: [Range<String.Index>], from text: String) -> String {
        // Ranges were found on the lowercased copy; lowercasing preserves indices
        // for the Latin text speech recognition produces, but rebuild defensively.
        let lowered = text.lowercased()
        guard lowered.count == text.count else { return text }
        var characters = Array(text)
        let offsets = ranges
            .map { (lowered.distance(from: lowered.startIndex, to: $0.lowerBound), lowered.distance(from: lowered.startIndex, to: $0.upperBound)) }
            .sorted { $0.0 > $1.0 }
        for (start, end) in offsets where start >= 0 && end <= characters.count {
            characters.removeSubrange(start..<end)
        }
        return tidy(String(characters))
    }

    /// Collapses whitespace and drops dangling connector words left behind.
    static func tidy(_ text: String) -> String {
        var result = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " ,.;:!?"))
        let dangling = #"(?i)(?:^(?:to|at|on|for|by|and|that)\s+)|(?:\s+(?:at|on|for|by|and|from|in)$)"#
        var previous = ""
        while previous != result {
            previous = result
            result = result.replacingOccurrences(of: dangling, with: "", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: " ,.;:!?"))
        }
        return result
    }

    private static func detectorFallback(in text: String, now: Date) -> Match? {
        #if canImport(Darwin)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let result = detector.firstMatch(in: text, options: [], range: range),
              let date = result.date, date > now,
              let swiftRange = Range(result.range, in: text) else { return nil }
        var remainder = text
        remainder.removeSubrange(swiftRange)
        return Match(date: date, hasTime: true, remainder: tidy(remainder), phrase: String(text[swiftRange]))
        #else
        return nil
        #endif
    }
}
