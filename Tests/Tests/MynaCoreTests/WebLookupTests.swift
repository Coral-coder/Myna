import XCTest
@testable import MynaCore

/// The web-lookup that lets Myna answer from the internet. Network isn't tested
/// here, but the URL building and the JSON parsing of real response shapes are.
final class WebLookupTests: XCTestCase {
    func testDuckDuckGoURLEncodesQuery() {
        let url = WebLookup.duckDuckGoURL("tallest mountain")?.absoluteString ?? ""
        XCTAssertTrue(url.hasPrefix("https://api.duckduckgo.com/?q=tallest%20mountain"))
        XCTAssertTrue(url.contains("format=json"))
    }

    func testWikipediaURLs() {
        XCTAssertEqual(
            WebLookup.wikipediaSearchURL("Mount Everest")?.absoluteString,
            "https://en.wikipedia.org/w/api.php?action=query&list=search&srlimit=1&srsearch=Mount%20Everest&format=json"
        )
        XCTAssertEqual(
            WebLookup.wikipediaSummaryURL("Mount Everest")?.absoluteString,
            "https://en.wikipedia.org/api/rest_v1/page/summary/Mount%20Everest"
        )
    }

    func testParseDuckDuckGoAbstract() {
        let json = #"{"Answer":"","AbstractText":"Mount Everest is Earth's highest mountain.","AbstractSource":"Wikipedia","RelatedTopics":[]}"#
        XCTAssertEqual(
            WebLookup.parseDuckDuckGo(Data(json.utf8)),
            "Mount Everest is Earth's highest mountain. (Wikipedia)"
        )
    }

    func testParseDuckDuckGoDirectAnswer() {
        let json = #"{"Answer":"42","AbstractText":""}"#
        XCTAssertEqual(WebLookup.parseDuckDuckGo(Data(json.utf8)), "42")
    }

    func testParseDuckDuckGoRelatedFallback() {
        let json = #"{"Answer":"","AbstractText":"","RelatedTopics":[{"Text":"A"},{"Text":"B"},{"Text":"C"},{"Text":"D"}]}"#
        XCTAssertEqual(WebLookup.parseDuckDuckGo(Data(json.utf8)), "A; B; C")
    }

    func testParseDuckDuckGoEmptyIsNil() {
        XCTAssertNil(WebLookup.parseDuckDuckGo(Data(#"{"Answer":"","AbstractText":"","RelatedTopics":[]}"#.utf8)))
    }

    func testParseWikipediaTitle() {
        let json = #"{"query":{"search":[{"title":"Mount Everest"},{"title":"Other"}]}}"#
        XCTAssertEqual(WebLookup.parseWikipediaTitle(Data(json.utf8)), "Mount Everest")
    }

    func testParseWikipediaSummarySkipsDisambiguation() {
        let json = #"{"type":"disambiguation","extract":"Everest may refer to..."}"#
        XCTAssertNil(WebLookup.parseWikipediaSummary(Data(json.utf8)))
    }

    func testParseWikipediaSummaryExtract() {
        let json = #"{"type":"standard","extract":"Mount Everest is the highest mountain above sea level."}"#
        XCTAssertEqual(
            WebLookup.parseWikipediaSummary(Data(json.utf8)),
            "Mount Everest is the highest mountain above sea level."
        )
    }
}
