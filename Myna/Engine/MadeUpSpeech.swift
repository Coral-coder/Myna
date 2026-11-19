import Foundation

/// Takes out what speech recognizers make up from noise: stock lines learned
/// from video subtitles ("I'm going to go to the next video", "Thank you very
/// much", "Bye-bye") and words they get stuck repeating ("I Am, I Am, I Am…").
/// The home server does the same; this covers what the phone transcribes
/// itself. A line is only dropped when it is nothing but such a stock line.
enum MadeUpSpeech {
    private static let anywhere = [
        "thanks for watching", "thank you for watching", "next video", "subscribe to", "please subscribe",
        "like and subscribe", "subtitles by", "subtitled by", "transcribed by", "captions by", "amara org",
        "see you in the next",
    ]
    private static let wholeLine: Set<String> = [
        "", "you", "the", "a", "i", "so", "and", "oh", "uh", "um", "ah", "hmm", "mm", "mhm", "huh", "ahem", "grr",
        "thank you", "thank you very much", "thank you so much", "thanks", "thanks a lot", "thank you thank you",
        "bye", "bye bye", "goodbye", "good bye", "see you next time", "ill see you next time",
        "and ill see you next time", "see you later", "see you", "the end", "publisher", "beep", "bump",
        "im going to go to the next stage", "and the rest of the day", "music", "applause", "laughter", "silence",
    ]

    /// Lower case, letters only, single spaces ("Bye-bye!" → "bye bye").
    static func bare(_ text: String) -> String {
        let letters = text.lowercased().unicodeScalars.map { scalar -> Character in
            CharacterSet.lowercaseLetters.contains(scalar) && scalar.isASCII ? Character(scalar) : (scalar == "'" ? "\u{0}" : " ")
        }
        return String(letters).replacingOccurrences(of: "\u{0}", with: "")
            .split(separator: " ").joined(separator: " ")
    }

    /// One copy of a word repeated four times or more, a two- or three-word
    /// phrase three times or more, or a longer phrase twice or more in a row.
    static func collapseRepeats(_ text: String) -> String {
        let tokens = text.split(separator: " ").map(String.init)
        guard tokens.count >= 3 else { return text }
        let keys = tokens.map(bare)
        var kept: [Int] = []
        var i = 0
        while i < tokens.count {
            var collapsed = false
            let largest = min(8, (tokens.count - i) / 2)
            if largest >= 1 {
                for size in 1...largest {
                    let phrase = Array(keys[i..<(i + size)])
                    guard phrase.contains(where: { !$0.isEmpty }) else { continue }
                    var count = 1
                    while i + (count + 1) * size <= keys.count, Array(keys[(i + count * size)..<(i + (count + 1) * size)]) == phrase {
                        count += 1
                    }
                    if count >= (size == 1 ? 4 : size <= 3 ? 3 : 2) {
                        kept.append(contentsOf: i..<(i + size))
                        i += count * size
                        collapsed = true
                        break
                    }
                }
            }
            if !collapsed {
                kept.append(i)
                i += 1
            }
        }
        guard kept.count < tokens.count else { return text }
        return kept.map { tokens[$0] }.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: ",;"))
    }

    static func isMadeUp(_ text: String) -> Bool {
        let plain = bare(text)
        let words = Set(plain.split(separator: " ").map(String.init))
        if wholeLine.contains(plain) || (words.count == 1 && wholeLine.contains(words.first!)) { return true }
        return anywhere.contains { plain.contains($0) }
    }

    /// The text with stuck repeats collapsed, or "" when it is all made up.
    static func clean(_ text: String) -> String {
        let collapsed = collapseRepeats(text.trimmingCharacters(in: .whitespacesAndNewlines))
        return isMadeUp(collapsed) ? "" : collapsed
    }

    /// Server speaker turns with made-up ones dropped and repeats collapsed.
    static func clean(_ pieces: [HomeServer.Segment]) -> [HomeServer.Segment] {
        pieces.compactMap { piece in
            let said = clean(piece.text)
            return said.isEmpty ? nil : HomeServer.Segment(text: said, start: piece.start, duration: piece.duration, voice: piece.voice)
        }
    }
}
