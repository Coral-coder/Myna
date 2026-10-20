import XCTest
@testable import MynaCore

/// How Myna chooses and orders its speaking voice — so it talks back in the best
/// installed voice, and honours the one you pick.
final class VoiceOptionTests: XCTestCase {
    private let voices = [
        VoiceOption(id: "compact.en-US", name: "Samantha", quality: .standard, language: "en-US"),
        VoiceOption(id: "enhanced.en-US", name: "Ava", quality: .enhanced, language: "en-US"),
        VoiceOption(id: "premium.en-US", name: "Zoe", quality: .premium, language: "en-US"),
        VoiceOption(id: "premium.en-GB", name: "Jamie", quality: .premium, language: "en-GB"),
        VoiceOption(id: "premium.fr-FR", name: "Marie", quality: .premium, language: "fr-FR"),
    ]

    func testPicksHighestQualityForExactLanguage() {
        let pick = VoiceCatalog.select(identifier: nil, from: voices, preferredLanguage: "en-US")
        XCTAssertEqual(pick?.id, "premium.en-US")
    }

    func testHonoursAnExplicitChoice() {
        let pick = VoiceCatalog.select(identifier: "enhanced.en-US", from: voices, preferredLanguage: "en-US")
        XCTAssertEqual(pick?.id, "enhanced.en-US")
    }

    func testFallsBackToLanguageFamilyWhenNoExactMatch() {
        // No en-AU installed → best English voice wins over a louder non-English one.
        let pick = VoiceCatalog.select(identifier: nil, from: voices, preferredLanguage: "en-AU")
        XCTAssertEqual(pick?.quality, .premium)
        XCTAssertTrue(pick?.language.hasPrefix("en") ?? false)
    }

    func testStaleExplicitChoiceFallsBackToBest() {
        // The picked voice was deleted from the device → don't return nil, pick the best.
        let pick = VoiceCatalog.select(identifier: "deleted.voice", from: voices, preferredLanguage: "en-US")
        XCTAssertEqual(pick?.id, "premium.en-US")
    }

    func testOrderedKeepsFamilyBestFirst() {
        let ordered = VoiceCatalog.ordered(voices, preferredLanguage: "en-US")
        XCTAssertEqual(ordered.map(\.id), ["premium.en-US", "premium.en-GB", "enhanced.en-US", "compact.en-US"])
        XCTAssertFalse(ordered.contains { $0.language == "fr-FR" }, "picker shouldn't offer other languages")
    }

    func testEmptyIsNil() {
        XCTAssertNil(VoiceCatalog.select(identifier: nil, from: [], preferredLanguage: "en-US"))
    }
}
