import XCTest
@testable import MynaCore

final class BeeCloudAPITests: XCTestCase {
    /// Regression: query strings must survive URL building. `appendingPathComponent`
    /// percent-encoded the `?` and produced 404s on /v1/conversations and /v1/facts.
    func testEndpointPreservesQueryString() {
        XCTAssertEqual(
            BeeCloudAPI.endpoint("/v1/conversations?limit=20")?.absoluteString,
            "https://api.developer.bee.amazon.dev/v1/conversations?limit=20"
        )
        XCTAssertEqual(
            BeeCloudAPI.endpoint("/v1/facts?limit=50")?.absoluteString,
            "https://api.developer.bee.amazon.dev/v1/facts?limit=50"
        )
    }

    func testEndpointPlainPath() {
        XCTAssertEqual(
            BeeCloudAPI.endpoint("/v1/me")?.absoluteString,
            "https://api.developer.bee.amazon.dev/v1/me"
        )
    }

    func testEndpointNeverPercentEncodesTheQuestionMark() {
        let url = BeeCloudAPI.endpoint("/v1/conversations?limit=20")?.absoluteString ?? ""
        XCTAssertFalse(url.contains("%3F"), "query '?' must not be percent-encoded")
    }
}
