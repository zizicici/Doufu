//
//  WebToolProvider.swift
//  Doufu
//
//  Created by Codex on 2026/03/08.
//

import Foundation

final class WebToolProvider {
    private let configuration: ProjectChatConfiguration

    init(configuration: ProjectChatConfiguration = .default) {
        self.configuration = configuration
    }

    // MARK: - Web Search

    struct SearchResult {
        let title: String
        let url: String
        let description: String
    }

    struct WebToolError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private enum SearchEngine: CaseIterable {
        case duckDuckGo
        case bing
        case bingCN
        case google

        var name: String {
            switch self {
            case .duckDuckGo: return "DuckDuckGo"
            case .bing: return "Bing"
            case .bingCN: return "Bing CN"
            case .google: return "Google"
            }
        }

        func searchURL(query: String) -> URL? {
            guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
            switch self {
            case .duckDuckGo:
                return URL(string: "https://html.duckduckgo.com/html/?q=\(encoded)")
            case .bing:
                return URL(string: "https://www.bing.com/search?q=\(encoded)&setlang=en")
            case .bingCN:
                return URL(string: "https://cn.bing.com/search?q=\(encoded)")
            case .google:
                return URL(string: "https://www.google.com/search?q=\(encoded)&hl=en")
            }
        }

        /// Which parser to use for this engine's HTML.
        var parserType: ParserType {
            switch self {
            case .duckDuckGo: return .duckDuckGo
            case .bing, .bingCN: return .bing
            case .google: return .google
            }
        }

        enum ParserType {
            case duckDuckGo, bing, google
        }
    }

    func webSearch(query: String) async -> Result<[SearchResult], WebToolError> {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(WebToolError(message: "Missing required parameter: query"))
        }

        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var lastError = ""

        // Try each search engine in order; fall back on failure or empty results
        for engine in SearchEngine.allCases {
            if Task.isCancelled {
                return .failure(WebToolError(message: "Operation cancelled"))
            }

            guard let searchURL = engine.searchURL(query: trimmedQuery) else { continue }

            var request = URLRequest(url: searchURL)
            request.httpMethod = "GET"
            request.timeoutInterval = configuration.webFetchTimeoutSeconds
            request.setValue(
                "Mozilla/5.0 (iPhone; CPU iPhone OS 19_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/19.0 Mobile/15E148 Safari/604.1",
                forHTTPHeaderField: "User-Agent"
            )
            request.setValue("text/html", forHTTPHeaderField: "Accept")
            request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse,
                      (200...299).contains(httpResponse.statusCode) else {
                    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                    lastError = "\(engine.name) returned status \(code)"
                    continue
                }

                guard let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) else {
                    lastError = "\(engine.name) returned undecodable data"
                    continue
                }

                let results: [SearchResult]
                switch engine.parserType {
                case .duckDuckGo: results = parseDuckDuckGoResults(html: html)
                case .bing: results = parseBingResults(html: html)
                case .google: results = parseGoogleResults(html: html)
                }

                if !results.isEmpty {
                    return .success(Array(results.prefix(configuration.webSearchMaxResults)))
                }
                lastError = "\(engine.name) returned no results"
            } catch {
                lastError = "\(engine.name) failed: \(error.localizedDescription)"
                continue
            }
        }

        // All engines failed
        if !lastError.isEmpty {
            return .failure(WebToolError(message: "All search engines failed. Last error: \(lastError)"))
        }
        return .success([])
    }

    // MARK: - Web Fetch

    func webFetch(urlString: String, raw: Bool = false) async -> Result<String, WebToolError> {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure(WebToolError(message: "Missing required parameter: url"))
        }

        if Task.isCancelled {
            return .failure(WebToolError(message: "Operation cancelled"))
        }

        guard let url = URL(string: trimmed), url.scheme == "http" || url.scheme == "https" else {
            return .failure(WebToolError(message: "Invalid URL: \(trimmed). Only http and https URLs are supported."))
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = configuration.webFetchTimeoutSeconds
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 19_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/19.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        // Prefer plain text to reduce parsing burden
        request.setValue("text/html,application/xhtml+xml,text/plain;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                return .failure(WebToolError(message: "Request failed with status \(statusCode)"))
            }
        } catch {
            return .failure(WebToolError(message: "Request failed: \(error.localizedDescription)"))
        }

        let truncatedData = data.prefix(configuration.webFetchMaxBytes * 2)
        guard let rawText = String(data: truncatedData, encoding: .utf8)
                ?? String(data: truncatedData, encoding: .ascii) else {
            return .failure(WebToolError(message: "Failed to decode response as text"))
        }

        let contentType = (response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""

        let extracted: String
        if raw {
            extracted = rawText
        } else if contentType.contains("text/html") || contentType.contains("xhtml") || rawText.contains("<html") {
            extracted = extractTextFromHTML(rawText)
        } else {
            extracted = rawText
        }

        let trimmedResult = extracted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedResult.isEmpty else {
            return .failure(WebToolError(message: "Page returned empty content"))
        }

        // Truncate to byte limit
        if trimmedResult.utf8.count > configuration.webFetchMaxBytes {
            let truncated = truncateToUTF8ByteCount(trimmedResult, maxBytes: configuration.webFetchMaxBytes)
            return .success(truncated + "\n\n[Content truncated at \(configuration.webFetchMaxBytes) bytes]")
        }
        return .success(trimmedResult)
    }

    // MARK: - DuckDuckGo HTML Parser

    /// Parses DuckDuckGo HTML search results page.
    ///
    /// Each result in DDG HTML looks roughly like:
    /// ```
    /// <div class="result results_links results_links_deep web-result">
    ///   <h2 class="result__title">
    ///     <a class="result__a" href="https://...">Title Text</a>
    ///   </h2>
    ///   <a class="result__snippet">Description text...</a>
    /// </div>
    /// ```
    private func parseDuckDuckGoResults(html: String) -> [SearchResult] {
        var results: [SearchResult] = []

        // Strategy: find each <a class="result__a" ...> for title+URL,
        // then the following <a class="result__snippet"> for description.
        let resultBlockPattern = #"<a[^>]*class="result__a"[^>]*href="([^"]*)"[^>]*>(.*?)</a>"#
        let snippetPattern = #"<a[^>]*class="result__snippet"[^>]*>(.*?)</a>"#

        guard let resultRegex = try? NSRegularExpression(pattern: resultBlockPattern, options: [.dotMatchesLineSeparators]),
              let snippetRegex = try? NSRegularExpression(pattern: snippetPattern, options: [.dotMatchesLineSeparators])
        else { return [] }

        let nsHTML = html as NSString
        let fullRange = NSRange(location: 0, length: nsHTML.length)

        let resultMatches = resultRegex.matches(in: html, range: fullRange)
        let snippetMatches = snippetRegex.matches(in: html, range: fullRange)

        for (index, match) in resultMatches.enumerated() {
            guard match.numberOfRanges >= 3 else { continue }

            var rawURL = nsHTML.substring(with: match.range(at: 1))
            let rawTitle = nsHTML.substring(with: match.range(at: 2))

            let title = stripHTMLTags(rawTitle).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }

            // DDG wraps URLs in a redirect: //duckduckgo.com/l/?uddg=<encoded_url>&...
            rawURL = resolveDDGRedirectURL(rawURL)

            // Skip DDG internal links
            guard rawURL.hasPrefix("http://") || rawURL.hasPrefix("https://") else { continue }

            var description = ""
            if index < snippetMatches.count {
                let snippetMatch = snippetMatches[index]
                if snippetMatch.numberOfRanges >= 2 {
                    let rawSnippet = nsHTML.substring(with: snippetMatch.range(at: 1))
                    description = stripHTMLTags(rawSnippet).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }

            results.append(SearchResult(title: title, url: rawURL, description: description))
        }

        return results
    }

    private func resolveDDGRedirectURL(_ rawURL: String) -> String {
        // DDG redirect format: //duckduckgo.com/l/?uddg=<percent-encoded-URL>&rut=...
        guard rawURL.contains("duckduckgo.com/l/") || rawURL.contains("uddg=") else {
            return rawURL
        }

        guard let components = URLComponents(string: rawURL.hasPrefix("//") ? "https:" + rawURL : rawURL),
              let uddgValue = components.queryItems?.first(where: { $0.name == "uddg" })?.value,
              !uddgValue.isEmpty
        else { return rawURL }

        return uddgValue
    }

    // MARK: - Bing HTML Parser

    /// Parses Bing search results page.
    /// Bing result structure:
    /// ```
    /// <li class="b_algo">
    ///   <h2><a href="https://...">Title</a></h2>
    ///   <p class="b_lineclamp...">Description...</p>
    /// </li>
    /// ```
    private func parseBingResults(html: String) -> [SearchResult] {
        var results: [SearchResult] = []
        let nsHTML = html as NSString
        let fullRange = NSRange(location: 0, length: nsHTML.length)

        // Match each <li class="b_algo"> block
        let blockPattern = #"<li[^>]*class="b_algo"[^>]*>(.*?)</li>"#
        guard let blockRegex = try? NSRegularExpression(pattern: blockPattern, options: [.dotMatchesLineSeparators]) else { return [] }

        let linkPattern = #"<h2[^>]*>\s*<a[^>]*href="([^"]*)"[^>]*>(.*?)</a>"#
        let descPattern = #"<p[^>]*>(.*?)</p>"#
        guard let linkRegex = try? NSRegularExpression(pattern: linkPattern, options: [.dotMatchesLineSeparators]),
              let descRegex = try? NSRegularExpression(pattern: descPattern, options: [.dotMatchesLineSeparators])
        else { return [] }

        let blocks = blockRegex.matches(in: html, range: fullRange)
        for block in blocks {
            let blockHTML = nsHTML.substring(with: block.range)
            let blockNS = blockHTML as NSString
            let blockRange = NSRange(location: 0, length: blockNS.length)

            guard let linkMatch = linkRegex.firstMatch(in: blockHTML, range: blockRange),
                  linkMatch.numberOfRanges >= 3 else { continue }

            let url = blockNS.substring(with: linkMatch.range(at: 1))
            let rawTitle = blockNS.substring(with: linkMatch.range(at: 2))
            let title = stripHTMLTags(rawTitle).trimmingCharacters(in: .whitespacesAndNewlines)

            guard !title.isEmpty, url.hasPrefix("http") else { continue }

            var description = ""
            if let descMatch = descRegex.firstMatch(in: blockHTML, range: blockRange),
               descMatch.numberOfRanges >= 2 {
                let rawDesc = blockNS.substring(with: descMatch.range(at: 1))
                description = stripHTMLTags(rawDesc).trimmingCharacters(in: .whitespacesAndNewlines)
            }

            results.append(SearchResult(title: title, url: url, description: description))
        }

        return results
    }

    // MARK: - Google HTML Parser

    /// Parses Google search results page.
    /// Google result structure varies but generally:
    /// ```
    /// <div class="g">
    ///   <a href="https://..."><h3>Title</h3></a>
    ///   <div ...><span>Description...</span></div>
    /// </div>
    /// ```
    private func parseGoogleResults(html: String) -> [SearchResult] {
        var results: [SearchResult] = []
        let nsHTML = html as NSString
        let fullRange = NSRange(location: 0, length: nsHTML.length)

        // Strategy: find <a href=...><h3>Title</h3></a> patterns
        // Google wraps each result's title in an <h3> inside an <a>
        let titleLinkPattern = #"<a[^>]*href="(/url\?q=([^&"]+)[^"]*|https?://[^"]+)"[^>]*>\s*<h3[^>]*>(.*?)</h3>"#
        guard let titleRegex = try? NSRegularExpression(pattern: titleLinkPattern, options: [.dotMatchesLineSeparators]) else { return [] }

        let matches = titleRegex.matches(in: html, range: fullRange)
        for match in matches {
            guard match.numberOfRanges >= 4 else { continue }

            var url = nsHTML.substring(with: match.range(at: 1))
            let rawTitle = nsHTML.substring(with: match.range(at: 3))
            let title = stripHTMLTags(rawTitle).trimmingCharacters(in: .whitespacesAndNewlines)

            guard !title.isEmpty else { continue }

            // Google sometimes uses /url?q=<encoded_url>&...
            if url.hasPrefix("/url?q=") {
                let encoded = nsHTML.substring(with: match.range(at: 2))
                url = encoded.removingPercentEncoding ?? encoded
            }

            guard url.hasPrefix("http://") || url.hasPrefix("https://") else { continue }
            // Skip Google's own links
            if url.contains("google.com/search") || url.contains("accounts.google") { continue }

            // Try to find a description nearby — look for the next <span> block after this match
            var description = ""
            let afterMatchStart = match.range.location + match.range.length
            let remainingRange = NSRange(location: afterMatchStart, length: min(1000, nsHTML.length - afterMatchStart))
            if remainingRange.length > 0 {
                let spanPattern = #"<span[^>]*>(.*?)</span>"#
                if let spanRegex = try? NSRegularExpression(pattern: spanPattern, options: [.dotMatchesLineSeparators]),
                   let spanMatch = spanRegex.firstMatch(in: html, range: remainingRange),
                   spanMatch.numberOfRanges >= 2 {
                    let rawDesc = nsHTML.substring(with: spanMatch.range(at: 1))
                    let cleaned = stripHTMLTags(rawDesc).trimmingCharacters(in: .whitespacesAndNewlines)
                    if cleaned.count > 20 { // Skip very short spans (likely UI elements)
                        description = cleaned
                    }
                }
            }

            results.append(SearchResult(title: title, url: url, description: description))
        }

        return results
    }

    // MARK: - HTML to Text

    /// Converts HTML to readable plain text:
    /// - Strips all tags
    /// - Preserves paragraph structure
    /// - Decodes HTML entities
    /// - Collapses whitespace
    private func extractTextFromHTML(_ html: String) -> String {
        var text = html

        // Remove <script>, <style>, <nav>, <header>, <footer> blocks entirely
        let stripBlocksPattern = #"<(script|style|nav|header|footer|noscript|svg|iframe)[^>]*>.*?</\1>"#
        if let regex = try? NSRegularExpression(pattern: stripBlocksPattern, options: [.dotMatchesLineSeparators, .caseInsensitive]) {
            text = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        }

        // Convert <br>, <p>, <div>, <li>, <h1-6>, <tr> to newlines
        let blockTagPattern = #"<\s*/?\s*(br|p|div|li|tr|h[1-6]|section|article|blockquote)[^>]*/?>"#
        if let regex = try? NSRegularExpression(pattern: blockTagPattern, options: [.caseInsensitive]) {
            text = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "\n")
        }

        // Strip remaining tags
        text = stripHTMLTags(text)

        // Decode common HTML entities
        text = decodeHTMLEntities(text)

        // Collapse whitespace: multiple spaces → single space, multiple newlines → double newline
        text = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .map { line in
                // Collapse multiple spaces within a line
                line.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            }
            .joined(separator: "\n")

        // Collapse 3+ consecutive newlines into 2
        if let multiNewline = try? NSRegularExpression(pattern: "\n{3,}") {
            text = multiNewline.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "\n\n")
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func stripHTMLTags(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "<[^>]+>", options: []) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
    }

    private func decodeHTMLEntities(_ text: String) -> String {
        var result = text
        let entities: [(String, String)] = [
            ("&amp;", "&"),
            ("&lt;", "<"),
            ("&gt;", ">"),
            ("&quot;", "\""),
            ("&#39;", "'"),
            ("&apos;", "'"),
            ("&nbsp;", " "),
            ("&ndash;", "–"),
            ("&mdash;", "—"),
            ("&laquo;", "«"),
            ("&raquo;", "»"),
            ("&copy;", "©"),
            ("&reg;", "®"),
            ("&trade;", "™"),
            ("&hellip;", "…"),
        ]
        for (entity, char) in entities {
            result = result.replacingOccurrences(of: entity, with: char)
        }
        // Decode numeric entities: &#123; or &#x1F;
        if let numericRegex = try? NSRegularExpression(pattern: "&#(x?)([0-9a-fA-F]+);") {
            let nsResult = result as NSString
            let matches = numericRegex.matches(in: result, range: NSRange(location: 0, length: nsResult.length))
            // Process in reverse to preserve ranges
            for match in matches.reversed() {
                guard match.numberOfRanges >= 3 else { continue }
                let isHex = nsResult.substring(with: match.range(at: 1)) == "x"
                let numberStr = nsResult.substring(with: match.range(at: 2))
                let codePoint: UInt32?
                if isHex {
                    codePoint = UInt32(numberStr, radix: 16)
                } else {
                    codePoint = UInt32(numberStr, radix: 10)
                }
                if let cp = codePoint, let scalar = Unicode.Scalar(cp) {
                    result = (result as NSString).replacingCharacters(in: match.range, with: String(scalar))
                }
            }
        }
        return result
    }

    // MARK: - Helpers

    private func truncateToUTF8ByteCount(_ text: String, maxBytes: Int) -> String {
        guard maxBytes > 0 else { return "" }
        let data = Data(text.utf8)
        guard data.count > maxBytes else { return text }
        var upperBound = maxBytes
        while upperBound > 0 {
            if let decoded = String(data: data.prefix(upperBound), encoding: .utf8) {
                return decoded
            }
            upperBound -= 1
        }
        return ""
    }
}
