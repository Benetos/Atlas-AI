import Foundation

enum WebSearchError: LocalizedError {
    case disabled
    case unavailable

    var errorDescription: String? {
        switch self {
        case .disabled:
            return "Internet search is turned off."
        case .unavailable:
            return "Web search unavailable."
        }
    }
}

struct WebSearchClient: Sendable {
    func search(query: String) async throws -> [WebHit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var hits: [WebHit] = []
        if let wiki = try? await searchFandom(trimmed) {
            hits.append(contentsOf: wiki)
        }
        if let web = try? await searchDuckDuckGo(trimmed) {
            hits.append(contentsOf: web)
        }
        if hits.isEmpty {
            throw WebSearchError.unavailable
        }
        var seen: Set<String> = []
        return hits.filter { hit in
            seen.insert(hit.url.absoluteString).inserted
        }
    }

    private func searchFandom(_ query: String) async throws -> [WebHit] {
        var components = URLComponents(string: "https://nomanssky.fandom.com/api.php")
        components?.queryItems = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "list", value: "search"),
            URLQueryItem(name: "srsearch", value: query),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "srlimit", value: "5"),
            URLQueryItem(name: "origin", value: "*"),
        ]
        guard let url = components?.url else { return [] }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
        let decoded = try JSONDecoder().decode(FandomResponse.self, from: data)
        return (decoded.query?.search ?? []).compactMap { row in
            guard let page = URL(string: "https://nomanssky.fandom.com/wiki/\(row.title.replacingOccurrences(of: " ", with: "_"))") else {
                return nil
            }
            return WebHit(
                title: row.title,
                url: page,
                snippet: row.snippet.strippingHTML,
                host: "nomanssky.fandom.com",
                provenance: "community/web"
            )
        }
    }

    private func searchDuckDuckGo(_ query: String) async throws -> [WebHit] {
        var components = URLComponents(string: "https://html.duckduckgo.com/html/")
        components?.queryItems = [URLQueryItem(name: "q", value: "No Man's Sky \(query)")]
        guard let url = components?.url else { return [] }
        var request = URLRequest(url: url)
        request.setValue("Atlas-AI/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let html = String(data: data, encoding: .utf8)
        else { return [] }
        return parseDuckDuckGo(html)
    }

    private func parseDuckDuckGo(_ html: String) -> [WebHit] {
        let pattern = #"href="(https?://[^"]+)"[^>]*class="result__a"[^>]*>(.*?)</a>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return fallbackParse(html)
        }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        return regex.matches(in: html, range: range).prefix(5).compactMap { match in
            guard match.numberOfRanges >= 3,
                  let urlRange = Range(match.range(at: 1), in: html),
                  let titleRange = Range(match.range(at: 2), in: html),
                  let url = URL(string: String(html[urlRange]))
            else { return nil }
            let host = url.host ?? url.absoluteString
            return WebHit(
                title: String(html[titleRange]).strippingHTML,
                url: url,
                snippet: "Web result",
                host: host,
                provenance: "community/web"
            )
        }
    }

    private func fallbackParse(_ html: String) -> [WebHit] {
        let pattern = #"uddg=([^"&]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        return regex.matches(in: html, range: range).prefix(5).compactMap { match in
            guard let captured = Range(match.range(at: 1), in: html),
                  let decoded = String(html[captured]).removingPercentEncoding,
                  let url = URL(string: decoded)
            else { return nil }
            return WebHit(
                title: url.host ?? url.absoluteString,
                url: url,
                snippet: "Web result",
                host: url.host ?? "",
                provenance: "community/web"
            )
        }
    }
}

private struct FandomResponse: Decodable {
    var query: FandomQuery?
}

private struct FandomQuery: Decodable {
    var search: [FandomHit]?
}

private struct FandomHit: Decodable {
    var title: String
    var snippet: String
}

private extension String {
    var strippingHTML: String {
        replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
