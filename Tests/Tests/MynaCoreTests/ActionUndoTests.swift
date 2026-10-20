import XCTest
@testable import MynaCore

/// The Cancel button on an action notification reaches the phone (and Watch) as
/// a `userInfo` dictionary. These lock in that it round-trips to the right undo.
final class ActionUndoTests: XCTestCase {
    func testEventRoundTrips() {
        let undo = ActionUndo.event(id: "ABC-123")
        XCTAssertEqual(ActionUndo(payload: undo.payload), .event(id: "ABC-123"))
    }

    func testItemsRoundTrip() {
        let ids = [UUID().uuidString, UUID().uuidString]
        let undo = ActionUndo.items(ids: ids)
        XCTAssertEqual(ActionUndo(payload: undo.payload), .items(ids: ids))
    }

    func testUnknownKindIsNil() {
        XCTAssertNil(ActionUndo(payload: [ActionUndo.kindKey: "mystery", "eventID": "x"]))
    }

    func testMissingKindIsNil() {
        XCTAssertNil(ActionUndo(payload: ["eventID": "x"]))
    }

    func testEmptyEventIDIsNil() {
        XCTAssertNil(ActionUndo(payload: [ActionUndo.kindKey: "event", "eventID": ""]))
    }

    func testEmptyItemsIsNil() {
        XCTAssertNil(ActionUndo(payload: [ActionUndo.kindKey: "items", "itemIDs": [String]()]))
    }

    func testWrongTypeForItemsIsNil() {
        // A stray string where a list is expected must not crash or mis-parse.
        XCTAssertNil(ActionUndo(payload: [ActionUndo.kindKey: "items", "itemIDs": "not-a-list"]))
    }

    func testPayloadIsNamespaced() {
        // The kind lives under a namespaced key, so it won't collide with other userInfo.
        XCTAssertEqual(ActionUndo.kindKey, "myna.undo")
        XCTAssertNotNil(ActionUndo.event(id: "x").payload[ActionUndo.kindKey])
    }
}
