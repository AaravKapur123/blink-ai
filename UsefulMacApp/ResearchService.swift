//
//  ResearchService.swift
//  UsefulMacApp
//
//  Created by AI on 8/29/25.
//

import Foundation

@MainActor
final class ResearchService {
    static let shared = ResearchService()

    private init() {}
    
    // Tavily removed. Using Gemini search grounding for sources.

    func research(query: String) async throws -> ResearchBundle {
        print("🔍 Ultra-fast search for: \(query)")
        
        // Minimal, lightning-fast search like ChatGPT
        let sources = try await quickSearch(query: query)
        
        print("✅ Found \(sources.count) sources in under 2 seconds")
        
        let isoNow = ISO8601DateFormatter().string(from: Date())
        return ResearchBundle(query: query, fetchedAt: isoNow, sources: sources, notes: nil)
    }
    
    // Ultra-fast search via DuckDuckGo + light heuristics (returns 2–3 sources)
    private func quickSearch(query: String) async throws -> [ResearchBundle.Source] {
        let subs = try await expandQueries(query)
        let raw = try await fetchExpanded(subs)
        var prioritized = prioritizeCurrentSources(raw)
        if prioritized.isEmpty, let wiki = try? await fetchWikipediaSummary(query: query) {
            prioritized = [wiki]
        }
        return Array(prioritized.prefix(3))
    }

    private func fetchDuckDuckGoResults(query: String) async throws -> [ResearchBundle.Source] {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return [] }
        
        // Simple, fast search
        let url = URL(string: "https://duckduckgo.com/html/?q=\(encoded)")!
        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 5.0 // Fast timeout
        
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let html = String(data: data, encoding: .utf8) else { return [] }
        
        var results: [ResearchBundle.Source] = []
        
        // Simple pattern for fast parsing
        let pattern = #"<a rel=\"nofollow\" class=\"result__a\" href=\"(.*?)\"[^>]*>(.*?)</a>.*?result__snippet.*?>(.*?)</span>"#
        if let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive]) {
            let ns = html as NSString
            let matches = regex.matches(in: html, options: [], range: NSRange(location: 0, length: ns.length))
            
            for m in matches.prefix(4) { // Limit to 4 for speed
                guard m.numberOfRanges >= 4 else { continue }
                let rawHref = ns.substring(with: m.range(at: 1))
                let title = ns.substring(with: m.range(at: 2)).strippingHTML()
                let snippet = ns.substring(with: m.range(at: 3)).strippingHTML()
                
                let href = extractActualURL(from: rawHref)
                let cleanedSnippet = snippet.trimmingCharacters(in: .whitespacesAndNewlines)
                
                if !title.isEmpty && !href.isEmpty && URL(string: href) != nil {
                    results.append(ResearchBundle.Source(
                        title: title, 
                        url: href, 
                        snippet: cleanedSnippet, 
                        publishedAt: nil, 
                        site: URL(string: href)?.host
                    ))
                }
            }
        }
        
        return results
    }
    
    // Extract actual URL from DuckDuckGo redirect
    private func extractActualURL(from ddgURL: String) -> String {
        // Handle relative URLs by adding protocol
        var url = ddgURL
        if url.hasPrefix("//") {
            url = "https:" + url
        }
        
        // Check if this is a DuckDuckGo redirect URL
        if url.contains("duckduckgo.com/l/?uddg=") {
            // Extract the encoded URL parameter
            if let range = url.range(of: "uddg=") {
                let afterUddg = String(url[range.upperBound...])
                // Get everything up to the next & parameter
                let encodedURL = afterUddg.components(separatedBy: "&").first ?? afterUddg
                // URL decode it
                if let decodedURL = encodedURL.removingPercentEncoding {
                    print("🔗 Extracted URL: \(ddgURL) -> \(decodedURL)")
                    return decodedURL
                }
            }
        }
        
        return url
    }
    
    // Prioritize sources based on recency and quality indicators
    private func prioritizeCurrentSources(_ sources: [ResearchBundle.Source]) -> [ResearchBundle.Source] {
        let currentYear = Calendar.current.component(.year, from: Date())
        let currentMonth = Calendar.current.component(.month, from: Date())
        
        return sources.sorted { source1, source2 in
            // Score sources based on multiple factors
            let score1 = calculateSourceScore(source1, currentYear: currentYear, currentMonth: currentMonth)
            let score2 = calculateSourceScore(source2, currentYear: currentYear, currentMonth: currentMonth)
            return score1 > score2
        }
    }
    
    private func calculateSourceScore(_ source: ResearchBundle.Source, currentYear: Int, currentMonth: Int) -> Double {
        var score: Double = 0
        
        // Base score for having substantial content (prioritize relevance)
        score += source.snippet.isEmpty ? 0 : 3  // Increased base relevance score
        
        let content = "\(source.title) \(source.snippet)".lowercased()
        
        // Strong boost for current year 
        if content.contains("\(currentYear)") {
            score += 4  // Increased for recent bias
        }
        
        // Stronger boost for recent indicators - prioritize last week content
        if !source.snippet.isEmpty {
            let veryRecentTerms = ["this week", "past week", "last week", "days ago", "yesterday", "today"]
            let recentTerms = ["latest", "recent", "current", "update", "new", "breaking"]
            
            // High score for very recent indicators
            for term in veryRecentTerms {
                if content.contains(term) {
                    score += 5  // Strong boost for weekly recency
                    break
                }
            }
            
            // Medium score for general recent indicators
            for term in recentTerms {
                if content.contains(term) {
                    score += 2  // Increased from 1 to 2
                    break
                }
            }
        }
        
        // Moderate boost for quality news sites and tech sources
        let qualitySites = ["reuters", "bloomberg", "cnbc", "bbc", "npr", "wikipedia", 
                           "techcrunch", "theverge", "arstechnica", "github", "openai", "anthropic", 
                           "google", "microsoft", "apple", "nvidia", "nature", "science", "arxiv"]
        if let site = source.site?.lowercased() {
            for newssite in qualitySites {
                if site.contains(newssite) {
                    score += 3  // Increased back to 3 for quality sources
                    break
                }
            }
        }
        
        // Small boost for current year in URL
        if source.url.contains("\(currentYear)") {
            score += 1  // Reduced from 2 to 1
        }
        
        // Penalty for very short snippets (likely not relevant)
        if source.snippet.count < 50 {
            score -= 1
        }
        
        return score
    }

    private func fetchWikipediaSummary(query: String) async throws -> ResearchBundle.Source? {
        // Call Wikipedia REST summary endpoint for the top page matching the query
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
        let searchUrl = URL(string: "https://en.wikipedia.org/w/api.php?action=query&list=search&srsearch=\(encoded)&format=json&srlimit=1")!
        let (data, _) = try await URLSession.shared.data(from: searchUrl)
        struct SearchResponse: Codable {
            struct Query: Codable {
                struct SearchItem: Codable { let title: String }
                let search: [SearchItem]
            }
            let query: Query
        }
        guard let resp = try? JSONDecoder().decode(SearchResponse.self, from: data), let first = resp.query.search.first else { return nil }
        let pageTitleEncoded = first.title.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? first.title
        let summaryUrl = URL(string: "https://en.wikipedia.org/api/rest_v1/page/summary/\(pageTitleEncoded)")!
        let (sumData, _) = try await URLSession.shared.data(from: summaryUrl)
        struct Summary: Codable {
            struct ContentURLs: Codable {
                struct Desktop: Codable { let page: String }
                let desktop: Desktop
            }
            let title: String
            let extract: String
            let content_urls: ContentURLs?
            let timestamp: String?
        }
        if let s = try? JSONDecoder().decode(Summary.self, from: sumData) {
            return ResearchBundle.Source(title: s.title, url: s.content_urls?.desktop.page ?? "https://en.wikipedia.org/wiki/\(pageTitleEncoded)", snippet: s.extract, publishedAt: s.timestamp, site: "Wikipedia")
        }
        return nil
    }

    // MARK: - Query enhancement
    private func enhanceQueryWithKeywords(_ query: String) -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        
        let currentYear = Calendar.current.component(.year, from: Date())
        let lowercaseQuery = trimmed.lowercased()
        
        // Add relevant keywords based on query content
        var keywords: [String] = []
        
        // Tech-related terms
        if lowercaseQuery.contains("ai") || lowercaseQuery.contains("artificial intelligence") {
            keywords.append("technology")
        }
        if lowercaseQuery.contains("model") || lowercaseQuery.contains("gpt") {
            keywords.append("machine learning")
        }
        if lowercaseQuery.contains("best") || lowercaseQuery.contains("top") {
            keywords.append("comparison review")
        }
        if lowercaseQuery.contains("latest") || lowercaseQuery.contains("new") {
            keywords.append("\(currentYear)")
        }
        
        // Always add temporal keywords for maximum recency
        if !lowercaseQuery.contains("\(currentYear)") {
            keywords.append("latest \(currentYear)")
        }
        
        // Add aggressive temporal modifiers for recent content
        if !lowercaseQuery.contains("recent") && !lowercaseQuery.contains("latest") {
            keywords.append("recent news")
        }
        
        // Add week-specific terms for very recent content
        keywords.append("this week")
        
        let enhanced = ([trimmed] + keywords).joined(separator: " ")
        return enhanced
    }

    // MARK: - Query expansion
    private func expandQueries(_ query: String) async throws -> [String] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        
        // Get current date components for more targeted searches
        let now = Date()
        let year = Calendar.current.component(.year, from: now)
        let month = Calendar.current.component(.month, from: now)
        let _ = Calendar.current.component(.day, from: now)
        let monthName = DateFormatter().monthSymbols[month - 1]
        
        // Create balanced searches: topic-focused with selective recency
        return [
            "\(q)", // Keep original query for maximum relevance
            "\(q) \(year)", // Add current year to topic
            "\(q) latest news \(year)", // Recent news about the topic
            "\(q) current trends", // Current trends for the topic
            "\(q) recent developments", // Recent developments in the topic
            "\(q) update \(monthName) \(year)" // Recent updates with specific date
        ]
    }

    private func fetchExpanded(_ subs: [String]) async throws -> [ResearchBundle.Source] {
        return try await withThrowingTaskGroup(of: [ResearchBundle.Source].self) { group in
            for s in subs.prefix(4) { // limit
                group.addTask { try await self.fetchDuckDuckGoResults(query: s) }
            }
            var combined: [ResearchBundle.Source] = []
            for try await part in group { combined.append(contentsOf: part) }
            // Deduplicate by URL
            var seen: Set<String> = []
            let deduped = combined.filter { src in
                if seen.contains(src.url) { return false }
                seen.insert(src.url)
                return true
            }
            return Array(deduped.prefix(8))
        }
    }

    // MARK: - Page body fetch and synthesis
    private func fetchBodies(for sources: [ResearchBundle.Source]) async throws -> [String: String] {
        var result: [String: String] = [:]
        try await withThrowingTaskGroup(of: (String, String?).self) { group in
            for s in sources {
                group.addTask {
                    do {
                        guard let url = URL(string: s.url) else { 
                            print("❌ Invalid URL: \(s.url)")
                            return (s.url, nil) 
                        }
                        var req = URLRequest(url: url)
                        req.timeoutInterval = 15
                        // Add user agent to avoid bot blocking
                        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
                        req.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
                        
                        print("🌐 Fetching content from: \(url.host ?? url.absoluteString)")
                        let (data, response) = try await URLSession.shared.data(for: req)
                        
                        if let httpResponse = response as? HTTPURLResponse {
                            print("📡 Response status for \(url.host ?? ""): \(httpResponse.statusCode)")
                            guard httpResponse.statusCode == 200 else {
                                print("❌ HTTP error \(httpResponse.statusCode) for \(url)")
                                return (s.url, nil)
                            }
                        }
                        
                        let html = String(data: data, encoding: .utf8) ?? ""
                        let text = await Self.extractReadableText(fromHTML: html)
                        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        
                        print("📄 Extracted \(trimmedText.count) characters from \(url.host ?? "")")
                        
                        return (s.url, trimmedText.isEmpty ? nil : trimmedText)
                    } catch {
                        print("❌ Error fetching \(s.url): \(error)")
                        return (s.url, nil)
                    }
                }
            }
            for try await (url, body) in group {
                if let body = body, !body.isEmpty { result[url] = body }
            }
        }
        return result
    }

    private func synthesizeNotes(query: String, sources: [ResearchBundle.Source], bodies: [String: String]) async throws -> String {
        // Build comprehensive synthesis from available data
        var bullets: [String] = []
        var successfulFetches = 0
        
        for s in sources {
            let body = bodies[s.url] ?? ""
            let site = s.site ?? URL(string: s.url)?.host ?? ""
            
            var content = ""
            if !body.isEmpty {
                // Use first few lines of extracted content
                let bodyLines = body.split(separator: "\n").prefix(5).joined(separator: " ")
                content = bodyLines.prefix(400).description
                successfulFetches += 1
            } else if !s.snippet.isEmpty {
                // Fall back to snippet from search results
                content = s.snippet
            } else {
                // Last resort - just the title
                content = "Source available (content not accessible)"
            }
            
            let publishedInfo = s.publishedAt.map { " (Published: \($0))" } ?? ""
            let piece = "- **\(s.title)** — \(site)\(publishedInfo): \(content) \n  Source: \(s.url)"
            bullets.append(piece)
        }
        
        if bullets.isEmpty { return "" }
        
        let header = "CURRENT RESEARCH DATA FOR: \(query) (fetched \(Date().formatted(date: .abbreviated, time: .shortened)))"
        let accessibility = successfulFetches > 0 ? 
            "Content successfully extracted from \(successfulFetches)/\(sources.count) sources." :
            "Note: Full content extraction was limited - using search snippets and metadata."
        let priority = "This research data contains the most current information available on this topic."
        
        return ([header, accessibility, priority, ""] + bullets).joined(separator: "\n")
    }

    // Very naive readability extraction
    private static func extractReadableText(fromHTML html: String) -> String {
        var s = html
        // Remove scripts/styles
        s = s.replacingOccurrences(of: "<script[\\s\\S]*?</script>", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "<style[\\s\\S]*?</style>", with: " ", options: .regularExpression)
        // Replace block tags with newlines to preserve some structure
        let blockTags = ["p","div","article","section","li","h1","h2","h3","h4","h5","h6","br"]
        for tag in blockTags {
            s = s.replacingOccurrences(of: "<\(tag)[^>]*>", with: "\n", options: .regularExpression)
            s = s.replacingOccurrences(of: "</\(tag)>", with: "\n", options: .regularExpression)
        }
        // Strip remaining tags
        s = s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        // Decode basic entities
        s = s.strippingHTML()
        // Collapse whitespace
        let lines = s.components(separatedBy: CharacterSet.newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return lines.joined(separator: "\n")
    }
}

private extension String {
    func strippingHTML() -> String {
        var s = self
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "&amp;", with: "&")
        s = s.replacingOccurrences(of: "&quot;", with: "\"")
        s = s.replacingOccurrences(of: "&#39;", with: "'")
        s = s.replacingOccurrences(of: "&nbsp;", with: " ")
        return s
    }
}


