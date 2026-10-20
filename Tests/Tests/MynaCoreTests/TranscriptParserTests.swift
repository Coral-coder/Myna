import XCTest
@testable import MynaCore

/// The transcript parser is what makes Myna a Bee companion: it reads a Bee
/// conversation and finds things to buy, do, and remember. The keyword
/// heuristics are deterministic and platform-free, so they're unit-tested here.
/// (The NSDataDetector path — dates, phones, addresses — behaves differently on
/// Linux vs. Apple platforms, so it isn't asserted on here.)
final class TranscriptParserTests: XCTestCase {

    private func kinds(_ items: [ParsedSuggestion]) -> [SuggestionKind] { items.map(\.kind) }
    private func text(_ items: [ParsedSuggestion], _ kind: SuggestionKind) -> [String] {
        items.filter { $0.kind == kind }.map(\.text)
    }

    func testPicksUpShoppingItems() {
        let t = "We're out of milk. Can you grab some coffee on the way home?"
        let items = TranscriptParser.keywordItems(t)
        let shopping = text(items, .shopping)
        XCTAssertTrue(shopping.contains("milk"), "\(shopping)")
        XCTAssertTrue(shopping.contains(where: { $0.contains("coffee") }), "\(shopping)")
    }

    func testBuyViaNeedToIsShoppingNotTodo() {
        let items = TranscriptParser.keywordItems("I need to buy a birthday card for Sarah.")
        XCTAssertEqual(text(items, .shopping), ["a birthday card for sarah"])
        XCTAssertTrue(text(items, .todo).isEmpty)
    }

    func testLeadInBecomesTodo() {
        let items = TranscriptParser.keywordItems("Don't forget to call the dentist tomorrow.")
        XCTAssertEqual(text(items, .todo), ["call the dentist tomorrow"])
    }

    func testImperativeVerbBecomesTodo() {
        let items = TranscriptParser.keywordItems("Email the landlord about the lease.")
        XCTAssertEqual(text(items, .todo), ["email the landlord about the lease"])
    }

    func testStripsSpeakerLabel() {
        XCTAssertEqual(TranscriptParser.stripSpeaker("Speaker 2: we need some eggs"), "we need some eggs")
        XCTAssertEqual(TranscriptParser.stripSpeaker("Alex: buy bread"), "buy bread")
    }

    func testKeepsMidSentenceColon() {
        // A colon deep in a sentence is not a speaker label.
        let s = "the plan is simple: we meet at noon"
        XCTAssertEqual(TranscriptParser.stripSpeaker(s), s)
    }

    func testTidyCutsAtConjunction() {
        XCTAssertEqual(TranscriptParser.tidy("milk and also some bread"), "milk")
        XCTAssertEqual(TranscriptParser.tidy(" the dentist, then the bank "), "the dentist")
    }

    func testTidyCapsLength() {
        let long = Array(repeating: "word", count: 20).joined(separator: " ")
        XCTAssertEqual(TranscriptParser.tidy(long).split(separator: " ").count, 10)
    }

    func testCueMustBeOnWordBoundary() {
        // "buy" inside "buying" must not trigger a shopping item.
        let items = TranscriptParser.keywordItems("They were buying time before the meeting.")
        XCTAssertTrue(text(items, .shopping).isEmpty, "\(items)")
    }

    func testSentenceSplitting() {
        XCTAssertEqual(
            TranscriptParser.sentences("One thing. Another thing! A third?"),
            ["One thing", "Another thing", "A third"]
        )
    }

    func testDedupCollapsesRepeats() {
        let a = ParsedSuggestion(kind: .shopping, text: "Milk", detail: "x")
        let b = ParsedSuggestion(kind: .shopping, text: "milk", detail: "y")
        let c = ParsedSuggestion(kind: .todo, text: "milk", detail: "z")
        let out = TranscriptParser.dedup([a, b, c])
        XCTAssertEqual(out.count, 2, "case-insensitive same kind collapses; different kind stays")
    }

    func testNothingActionableYieldsNothing() {
        let items = TranscriptParser.keywordItems("It was a lovely sunny day and we talked for hours.")
        XCTAssertTrue(items.isEmpty, "\(items)")
    }

    func testDedupKeyIsKindAndText() {
        XCTAssertEqual(SuggestionKind.shopping.dedupKey(for: "  Milk "), "shopping|milk")
    }
}
