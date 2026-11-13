import XCTest
@testable import MynaCore

final class ModelPlaceholderTests: XCTestCase {
    func testDetectsEchoedPlaceholders() {
        // The exact string the Ask chat showed when the model echoed the schema.
        XCTAssertTrue(ModelPlaceholder.looksLikePlaceholder("what you say back, spoken aloud"))
        XCTAssertTrue(ModelPlaceholder.looksLikePlaceholder("Short, vivid title for this conversation"))  // case-insensitive
        XCTAssertTrue(ModelPlaceholder.looksLikePlaceholder("2-3 sentence summary"))
        XCTAssertTrue(ModelPlaceholder.looksLikePlaceholder("the item to check off"))
        XCTAssertTrue(ModelPlaceholder.looksLikePlaceholder("  ...  "))
        XCTAssertTrue(ModelPlaceholder.looksLikePlaceholder("…"))
        XCTAssertTrue(ModelPlaceholder.looksLikePlaceholder("   "))
        XCTAssertTrue(ModelPlaceholder.looksLikePlaceholder(""))
    }

    func testKeepsRealContent() {
        XCTAssertFalse(ModelPlaceholder.looksLikePlaceholder("You said you'd call the plumber and send Dana the deck."))
        XCTAssertFalse(ModelPlaceholder.looksLikePlaceholder("Buy milk"))
        XCTAssertFalse(ModelPlaceholder.looksLikePlaceholder("Dentist appointment Tuesday at 2"))
        XCTAssertFalse(ModelPlaceholder.looksLikePlaceholder("Alex prefers async standups over meetings."))
        // Real content that merely MENTIONS a template phrase must NOT be wiped
        // (this is the substring-match data-loss bug the exact match fixes).
        XCTAssertFalse(ModelPlaceholder.looksLikePlaceholder("Store all times in ISO 8601 format."))
        XCTAssertFalse(ModelPlaceholder.looksLikePlaceholder("Send Dana the most important takeaways from the call."))
        XCTAssertFalse(ModelPlaceholder.looksLikePlaceholder("<follow up with legal>"))
        XCTAssertFalse(ModelPlaceholder.looksLikePlaceholder("The invoice is due in 2026."))
    }
}
