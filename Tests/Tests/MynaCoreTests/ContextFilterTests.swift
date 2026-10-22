import XCTest
@testable import MynaCore

/// TV / media rejection and the on-device extractor's plumbing.
final class ContextFilterTests: XCTestCase {
    func testMediaFromBeeSummary() {
        XCTAssertTrue(TranscriptParser.looksLikeMedia(summary: "The user was watching a TV show about chefs.", transcript: ""))
        XCTAssertTrue(TranscriptParser.looksLikeMedia(summary: "Audio from a podcast episode.", transcript: ""))
        XCTAssertFalse(TranscriptParser.looksLikeMedia(summary: "Planned dinner with Sam on Friday.", transcript: ""))
        XCTAssertFalse(TranscriptParser.looksLikeMedia(summary: "Had a video call with the team.", transcript: ""))
    }

    func testMediaFromBroadcastPhrases() {
        let t = "Speaker 1: Stay tuned, we'll be right back after the break.\nSpeaker 2: Breaking news tonight."
        XCTAssertTrue(TranscriptParser.looksLikeMedia(summary: "", transcript: t))
        XCTAssertFalse(TranscriptParser.looksLikeMedia(summary: "", transcript: "Speaker 1: Don't forget to call the dentist."))
    }

    func testParseDate() {
        let d = ConversationExtractor.parseDate("2026-11-03 15:30")
        XCTAssertNotNil(d)
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: d!)
        XCTAssertEqual([c.year, c.month, c.day, c.hour, c.minute], [2026, 11, 3, 15, 30])
        let dayOnly = ConversationExtractor.parseDate("2026-11-03")
        XCTAssertEqual(Calendar.current.component(.hour, from: dayOnly!), 9)
        XCTAssertNil(ConversationExtractor.parseDate(""))
        XCTAssertNil(ConversationExtractor.parseDate("next Tuesday"))
    }

    func testChunksSplitOnLines() {
        let text = (1...10).map { "line \($0) " + String(repeating: "x", count: 40) }.joined(separator: "\n")
        let parts = ConversationExtractor.chunks(of: text, size: 120)
        XCTAssertTrue(parts.count > 1)
        XCTAssertEqual(parts.joined(separator: "\n"), text)
        XCTAssertTrue(parts.allSatisfy { $0.count <= 120 })
    }

    func testMergeKeepsUncoveredKeywordItems() {
        let model = [ParsedSuggestion(kind: .appointment, text: "Dentist appointment", detail: "", date: Date(timeIntervalSince1970: 2_000_000_000))]
        let heuristic = [
            ParsedSuggestion(kind: .appointment, text: "Dentist", detail: "", date: Date(timeIntervalSince1970: 2_000_000_600)),
            ParsedSuggestion(kind: .shopping, text: "milk", detail: "", autoAdd: true),
        ]
        let merged = TranscriptParser.merge(model: model, heuristic: heuristic)
        XCTAssertEqual(merged.map(\.text), ["Dentist appointment", "milk"])
    }

    func testWordsOverlap() {
        XCTAssertTrue(TranscriptParser.wordsOverlap("Call Mom about Sunday", "call mom"))
        XCTAssertFalse(TranscriptParser.wordsOverlap("Buy milk", "Renew passport"))
    }

    // MARK: - Model JSON extraction

    func testParseJSONExtractsItemsWithConfidenceAndEvidence() {
        let raw = """
        Sure, here you go:
        {"isMedia": false, "items": [
          {"kind": "shopping", "title": "Milk", "dateTime": "", "confidence": 90, "evidence": "we are out of milk"},
          {"kind": "todo", "title": "Call the dentist", "dateTime": "", "confidence": 40, "evidence": "I should call the dentist sometime"}
        ]}
        trailing text
        """
        let r = ConversationExtractor.parseJSON(raw, reference: Date())
        XCTAssertNotNil(r)
        XCTAssertFalse(r!.isMedia)
        XCTAssertEqual(r!.items.map(\.text), ["Milk", "Call the dentist"])
        XCTAssertEqual(r!.items[0].autoAdd, true)          // confident + quoted
        XCTAssertEqual(r!.items[1].autoAdd, false)         // low confidence
    }

    func testParseJSONMediaReturnsNoAutoAdd() {
        let r = ConversationExtractor.parseJSON(#"{"isMedia": true, "items": []}"#, reference: Date())
        XCTAssertEqual(r?.isMedia, true)
        XCTAssertEqual(r?.items.count, 0)
    }

    func testParseJSONRejectsItemWithoutEvidence() {
        let raw = #"{"isMedia": false, "items": [{"kind":"todo","title":"Do a thing","dateTime":"","confidence":95,"evidence":""}]}"#
        let r = ConversationExtractor.parseJSON(raw, reference: Date())
        XCTAssertEqual(r?.items.first?.autoAdd, false)     // no quote => not auto-added
    }

    func testFirstJSONObjectHandlesBracesInStrings() {
        let s = "noise {\"a\": \"has } brace\", \"b\": 1} more"
        XCTAssertEqual(ConversationExtractor.firstJSONObject(in: s), "{\"a\": \"has } brace\", \"b\": 1}")
    }

    func testParseJSONGarbageIsNil() {
        XCTAssertNil(ConversationExtractor.parseJSON("not json at all", reference: Date()))
    }
}
