import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Lets Myna look things up on the web when its on-device model doesn't know the
/// answer. No API key: DuckDuckGo's Instant Answer API, with a Wikipedia summary
/// as backup. This is the one time Myna reaches off the device — only the search
/// query goes out, only when the assistant asks for a lookup — so it's gated by a
/// setting. The URL builders and JSON parsers are pure, so they're unit-tested.
struct WebLookup {
    static let enabledKey = "myna.webLookup"
    static var isEnabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    var session: URLSession = .shared

    /// A short plain-text digest of what the web says about `query`, or nil.
    func summary(for query: String) async -> String? {
        if let ddg = await fetch(Self.duckDuckGoURL(query), Self.parseDuckDuckGo) { return ddg }
        if let title = await fetch(Self.wikipediaSearchURL(query), Self.parseWikipediaTitle),
           let summary = await fetch(Self.wikipediaSummaryURL(title), Self.parseWikipediaSummary) {
            return summary
        }
        return nil
    }

    private func fetch(_ url: URL?, _ parse: (Data) -> String?) async -> String? {
        guard let url else { return nil }
        guard let data = try? await session.data(from: url).0 else { return nil }
        guard let text = parse(data)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return String(text.prefix(1200))
    }

    // MARK: - URL builders (pure)

    static func duckDuckGoURL(_ query: String) -> URL? {
        guard let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
        return URL(string: "https://api.duckduckgo.com/?q=\(q)&format=json&no_html=1&skip_disambig=1&t=myna")
    }

    static func wikipediaSearchURL(_ query: String) -> URL? {
        guard let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
        return URL(string: "https://en.wikipedia.org/w/api.php?action=query&list=search&srlimit=1&srsearch=\(q)&format=json")
    }

    static func wikipediaSummaryURL(_ title: String) -> URL? {
        guard let t = title.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        return URL(string: "https://en.wikipedia.org/api/rest_v1/page/summary/\(t)")
    }

    // MARK: - Parsers (pure)

    static func parseDuckDuckGo(_ data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let answer = (obj["Answer"] as? String), !answer.isEmpty { return answer }
        if let abstract = (obj["AbstractText"] as? String), !abstract.isEmpty {
            if let src = obj["AbstractSource"] as? String, !src.isEmpty { return "\(abstract) (\(src))" }
            return abstract
        }
        if let related = obj["RelatedTopics"] as? [[String: Any]] {
            let texts = related.compactMap { $0["Text"] as? String }.filter { !$0.isEmpty }.prefix(3)
            if !texts.isEmpty { return texts.joined(separator: "; ") }
        }
        return nil
    }

    static func parseWikipediaTitle(_ data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let query = obj["query"] as? [String: Any],
              let search = query["search"] as? [[String: Any]],
              let first = search.first,
              let title = first["title"] as? String, !title.isEmpty else { return nil }
        return title
    }

    static func parseWikipediaSummary(_ data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        // Skip disambiguation pages — they aren't answers.
        if (obj["type"] as? String) == "disambiguation" { return nil }
        let extract = obj["extract"] as? String
        return (extract?.isEmpty == false) ? extract : nil
    }
}
