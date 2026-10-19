import XCTest
@testable import MynaCore

final class SavedPlaceTests: XCTestCase {
    private let home = SavedPlace(name: "Home", latitude: 37.7749, longitude: -122.4194, radius: 150)
    private let work = SavedPlace(name: "Work", latitude: 37.7899, longitude: -122.4014, radius: 200)

    func testDistanceIsHaversine() {
        // ~0.001° of latitude ≈ 111 m.
        let meters = home.distance(toLatitude: 37.7759, longitude: -122.4194)
        XCTAssertEqual(meters, 111.2, accuracy: 1)
    }

    func testNearestWithinRadius() {
        XCTAssertEqual(SavedPlace.nearest(toLatitude: 37.7752, longitude: -122.4190, in: [home, work])?.name, "Home")
        XCTAssertEqual(SavedPlace.nearest(toLatitude: 37.7895, longitude: -122.4010, in: [home, work])?.name, "Work")
    }

    func testNothingOutsideEveryRadius() {
        XCTAssertNil(SavedPlace.nearest(toLatitude: 37.80, longitude: -122.45, in: [home, work]))
        XCTAssertNil(SavedPlace.nearest(toLatitude: 37.7749, longitude: -122.4194, in: []))
    }

    func testOverlappingPlacesPickTheCloser() {
        let gym = SavedPlace(name: "Gym", latitude: 37.7755, longitude: -122.4194, radius: 150)
        XCTAssertEqual(SavedPlace.nearest(toLatitude: 37.7756, longitude: -122.4194, in: [home, gym])?.name, "Gym")
    }
}

final class PeopleIndexTests: XCTestCase {
    private let alex = KnownPerson(givenName: "Alex", familyName: "Chen", organization: "Acme", jobTitle: "Product Lead")
    private let alexR = KnownPerson(givenName: "Alex", familyName: "Rivera")
    private let priya = KnownPerson(givenName: "Priya", familyName: "Natarajan", nickname: "Pri")
    private let will = KnownPerson(givenName: "Will", familyName: "Ortiz")
    private let siobhan = KnownPerson(givenName: "Siobhan", familyName: "Kelly")

    private var index: PeopleIndex { PeopleIndex(people: [alex, alexR, priya, will, siobhan]) }

    func testFullNameMatches() {
        let found = index.mentions(in: "I talked to alex chen about the roadmap.")
        XCTAssertEqual(found.map(\.fullName), ["Alex Chen"])
    }

    func testAmbiguousFirstNameDoesNotMatch() {
        // Two Alexes — "Alex" alone could be either.
        XCTAssertTrue(index.mentions(in: "Alex said the launch slipped.").isEmpty)
    }

    func testUniqueCapitalizedFirstNameMatches() {
        let found = index.mentions(in: "Then Priya said she'd send it, and Siobhan agreed.")
        XCTAssertEqual(found.map(\.fullName), ["Priya Natarajan", "Siobhan Kelly"])
    }

    func testLowercaseFirstNameDoesNotMatch() {
        XCTAssertTrue(index.mentions(in: "priya is a word here").isEmpty)
    }

    func testEverydayWordNamesNeedTheFullName() {
        XCTAssertTrue(index.mentions(in: "Will you send the deck? I will.").isEmpty)
        XCTAssertEqual(index.mentions(in: "Will Ortiz is joining.").map(\.fullName), ["Will Ortiz"])
    }

    func testPossessiveAndOrder() {
        let found = index.mentions(in: "Siobhan's draft is good. Alex Rivera wants changes.")
        XCTAssertEqual(found.map(\.fullName), ["Siobhan Kelly", "Alex Rivera"])
    }

    func testNicknamesMatchButTwoLetterNamesDoNot() {
        XCTAssertEqual(PeopleIndex(people: [priya]).mentions(in: "Pri called.").map(\.fullName), ["Priya Natarajan"])
        // Two letters is too easy to mishear.
        let bo = KnownPerson(givenName: "Bo", familyName: "Lund")
        XCTAssertTrue(PeopleIndex(people: [bo]).mentions(in: "Bo called.").isEmpty)
    }

    func testEachPersonOnce() {
        let found = index.mentions(in: "Priya, Priya, Priya Natarajan!")
        XCTAssertEqual(found.count, 1)
    }

    func testResolve() {
        XCTAssertEqual(index.resolve("priya")?.fullName, "Priya Natarajan")
        XCTAssertEqual(index.resolve("Alex Chen")?.fullName, "Alex Chen")
        XCTAssertNil(index.resolve("Alex"))
        XCTAssertNil(index.resolve(""))
    }

    func testSummary() {
        XCTAssertEqual(alex.summary, "Alex Chen (Product Lead, Acme)")
        XCTAssertEqual(alexR.summary, "Alex Rivera")
    }
}

final class HealthMathTests: XCTestCase {
    private func interval(_ startHour: Double, _ endHour: Double) -> DateInterval {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        return DateInterval(start: base.addingTimeInterval(startHour * 3600), end: base.addingTimeInterval(endHour * 3600))
    }

    func testOverlappingSourcesCountOnce() {
        // Watch: 23–7, phone: 0–6 → 8 h, not 14.
        let total = HealthMath.coveredDuration(of: [interval(0, 6), interval(-1, 7)])
        XCTAssertEqual(total, 8 * 3600, accuracy: 0.5)
    }

    func testGapsAreExcluded() {
        let total = HealthMath.coveredDuration(of: [interval(0, 2), interval(3, 5), interval(4.5, 6)])
        XCTAssertEqual(total, 5 * 3600, accuracy: 0.5)
    }

    func testEmpty() {
        XCTAssertEqual(HealthMath.coveredDuration(of: []), 0)
    }

    func testSpokenDuration() {
        XCTAssertEqual(HealthMath.spokenDuration(45 * 60), "45 min")
        XCTAssertEqual(HealthMath.spokenDuration(7 * 3600), "7 h")
        XCTAssertEqual(HealthMath.spokenDuration(7 * 3600 + 5 * 60), "7 h 5 min")
    }

    func testHealthQuestionGate() {
        XCTAssertTrue(HealthMath.isHealthQuestion("How did I sleep last night?"))
        XCTAssertTrue(HealthMath.isHealthQuestion("how many steps today"))
        XCTAssertFalse(HealthMath.isHealthQuestion("What's on my calendar tomorrow?"))
        XCTAssertFalse(HealthMath.isHealthQuestion("Remind me to call Mom"))
    }
}

final class NoteContextTests: XCTestCase {
    func testEmptyContextAddsNothing() {
        XCTAssertEqual(NoteContext.empty.promptBlock(budget: 1000), "")
    }

    func testPromptBlock() {
        let context = NoteContext(
            place: "Work",
            people: [KnownPerson(givenName: "Alex", familyName: "Chen", organization: "Acme")],
            photoIdentifiers: ["A"],
            photoText: ["Q3 GOALS ship v2"]
        )
        let block = context.promptBlock(budget: 2000)
        XCTAssertTrue(block.contains("PLACE: Work"))
        XCTAssertTrue(block.contains("Alex Chen (Acme)"))
        XCTAssertTrue(block.contains("[Photo 1] Q3 GOALS ship v2"))
    }

    func testPromptBlockRespectsBudget() {
        let context = NoteContext(photoText: [String(repeating: "x", count: 5000)])
        XCTAssertEqual(context.promptBlock(budget: 300).count, 300)
    }

    func testAttendeeResolution() {
        let context = NoteContext(people: [KnownPerson(givenName: "Priya", familyName: "Natarajan")])
        XCTAssertEqual(context.resolveAttendee("Priya"), "Priya Natarajan")
        XCTAssertEqual(context.resolveAttendee("Jordan"), "Jordan")
    }
}

/// Smoke tests that the existing parsing logic still builds and behaves in
/// this package (the full case list lives with PR #4's notes).
final class CommandParserSmokeTests: XCTestCase {
    func testShoppingCommand() {
        let commands = CommandParser.commandsFollowingWakeWord(in: "Myna, add oat milk to the shopping list")
        XCTAssertEqual(commands.count, 1)
        guard case .addItems(let kind, let items) = CommandParser.parse(commands[0]) else {
            return XCTFail("expected addItems")
        }
        XCTAssertEqual(kind, .shopping)
        XCTAssertEqual(items.map { $0.lowercased() }, ["oat milk"])
    }
}
