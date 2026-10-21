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
}
