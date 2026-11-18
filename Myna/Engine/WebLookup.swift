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
        var parts: [String] = []
        if let ddg = await fetch(Self.duckDuckGoURL(query), Self.parseDuckDuckGo) { parts.append(ddg) }
        // Ordinary search results: what the top pages say.
        if let results = await searchResults(query) { parts.append("Top search results:\n" + results) }
        if parts.isEmpty,
           let title = await fetch(Self.wikipediaSearchURL(query), Self.parseWikipediaTitle),
           let summary = await fetch(Self.wikipediaSummaryURL(title), Self.parseWikipediaSummary) {
            parts.append(summary)
        }
        return parts.isEmpty ? nil : String(parts.joined(separator: "\n").prefix(3600))
    }

    /// Titles and snippets of the first few web results for `query`.
    private func searchResults(_ query: String) async -> String? {
        guard let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://html.duckduckgo.com/html/?q=\(q)") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        guard let data = try? await session.data(for: request).0,
              let html = String(data: data, encoding: .utf8) else { return nil }
        let results = Self.parseSearchResults(html)
        guard !results.isEmpty else { return nil }
        var out = results.joined(separator: "\n")
        // Read the first result's page as well, for the detail a snippet lacks.
        if let link = Self.firstResultLink(html), let page = await pageText(link) {
            out += "\nFrom the first result's page: " + page
        }
        return out
    }

    /// The readable text at the start of a web page.
    private func pageText(_ url: URL) async -> String? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        guard let data = try? await session.data(for: request).0, data.count < 3_000_000,
              let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return nil }
        let text = Self.readableText(html)
        return text.count < 80 ? nil : String(text.prefix(1400))
    }

    /// Where the first search result points (DuckDuckGo wraps it in a redirect).
    static func firstResultLink(_ html: String) -> URL? {
        guard let regex = try? NSRegularExpression(pattern: "class=\"result__a\"[^>]*href=\"([^\"]+)\""),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html) else { return nil }
        var link = String(html[range]).replacingOccurrences(of: "&amp;", with: "&")
        if link.hasPrefix("//") { link = "https:" + link }
        if let wrapped = URLComponents(string: link)?.queryItems?.first(where: { $0.name == "uddg" })?.value {
            link = wrapped
        }
        guard let url = URL(string: link), url.scheme == "https" || url.scheme == "http" else { return nil }
        return url
    }

    /// A page's text with scripts, styles and markup removed.
    static func readableText(_ html: String) -> String {
        var text = html
        for pattern in ["<script[\\s\\S]*?</script>", "<style[\\s\\S]*?</style>", "<head[\\s\\S]*?</head>", "<nav[\\s\\S]*?</nav>",
                        "<footer[\\s\\S]*?</footer>", "<[^>]+>"] {
            text = text.replacingOccurrences(of: pattern, with: " ", options: [.regularExpression, .caseInsensitive])
        }
        for (entity, plain) in ["&amp;": "&", "&quot;": "\"", "&#x27;": "'", "&#39;": "'", "&lt;": "<", "&gt;": ">", "&nbsp;": " "] {
            text = text.replacingOccurrences(of: entity, with: plain)
        }
        return text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "Title — snippet" for each result on a DuckDuckGo HTML results page.
    static func parseSearchResults(_ html: String, limit: Int = 5) -> [String] {
        func clean(_ text: String) -> String {
            var out = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            for (entity, plain) in ["&amp;": "&", "&quot;": "\"", "&#x27;": "'", "&#39;": "'", "&lt;": "<", "&gt;": ">", "&nbsp;": " "] {
                out = out.replacingOccurrences(of: entity, with: plain)
            }
            return out.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func matches(_ pattern: String) -> [String] {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return [] }
            let range = NSRange(html.startIndex..., in: html)
            return regex.matches(in: html, range: range).compactMap { match in
                Range(match.range(at: 1), in: html).map { clean(String(html[$0])) }
            }
        }
        let titles = matches("class=\"result__a\"[^>]*>(.*?)</a>")
        let snippets = matches("class=\"result__snippet\"[^>]*>(.*?)</a>")
        var out: [String] = []
        for index in 0..<min(limit, min(titles.count, snippets.count)) where !snippets[index].isEmpty {
            out.append("\(index + 1). \(titles[index]) — \(snippets[index])")
        }
        return out
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
