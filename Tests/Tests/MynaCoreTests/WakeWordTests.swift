import XCTest
@testable import MynaCore

final class WakeWordTests: XCTestCase {
    override func tearDown() {
        CommandParser.customWakeWords = []
        super.tearDown()
    }

    func testDefaultWakeWordStillWorks() {
        CommandParser.customWakeWords = []
        XCTAssertEqual(CommandParser.commandsFollowingWakeWord(in: "Myna, add eggs"), ["add eggs"])
    }

    func testCustomWakeWordTriggers() {
        CommandParser.customWakeWords = ["scribe"]
        XCTAssertEqual(CommandParser.commandsFollowingWakeWord(in: "Scribe, add eggs"), ["add eggs"])
        // The built-in name keeps working alongside it.
        XCTAssertEqual(CommandParser.commandsFollowingWakeWord(in: "Myna, add eggs"), ["add eggs"])
    }

    func testCustomWakePhrase() {
        CommandParser.customWakeWords = ["hey scribe"]
        XCTAssertEqual(CommandParser.commandsFollowingWakeWord(in: "hey scribe what's on my calendar"), ["what's on my calendar"])
    }

    func testActiveWakeWordsDedupesAndLowercases() {
        CommandParser.customWakeWords = ["Myna", "Scribe", ""]
        let active = CommandParser.activeWakeWords
        XCTAssertEqual(active.filter { $0 == "myna" }.count, 1)
        XCTAssertTrue(active.contains("scribe"))
        XCTAssertFalse(active.contains(""))
    }

    func testUnrelatedWordDoesNotTrigger() {
        CommandParser.customWakeWords = ["scribe"]
        XCTAssertTrue(CommandParser.commandsFollowingWakeWord(in: "describe the meeting").isEmpty)
    }
}
