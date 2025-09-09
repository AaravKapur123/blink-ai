//
//  OpenAIService.swift
//  UsefulMacApp


//  Created by Aarav Kapur on 8/20/25.
//

import Foundation

struct ResearchBundle: Codable {
    struct Source: Codable {
        let title: String
        let url: String
        let snippet: String
        let publishedAt: String?
        let site: String?
    }
    let query: String
    let fetchedAt: String
    let sources: [Source]
    // Optional synthesized notes derived from crawling and triangulating top sources
    let notes: String?
}

extension ResearchBundle {
    func toJSONString() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = []
        let data = try encoder.encode(self)
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

struct OpenAIMessage: Codable {
    let role: String
    let content: [Content]
    
    struct Content: Codable {
        let type: String
        let text: String?
        let image_url: ImageURL?
        
        struct ImageURL: Codable {
            let url: String
            let detail: String?
        }
    }
}

struct OpenAIRequest: Codable {
    let model: String
    let messages: [OpenAIMessage]
    let max_tokens: Int?
    let max_completion_tokens: Int?
    let temperature: Double
    // Enable SSE streaming when true (optional; defaults to nil for non-streaming)
    let stream: Bool?
    // Optional OpenAI tools (e.g., web_search)
    let tools: [Tool]?
    struct Tool: Codable { let type: String }
    // Optional web search options for search-enabled models
    let web_search_options: [String: String]?
    // Optional response format (e.g., {"type":"text"}) for GPT-5 family
    struct ResponseFormat: Codable { let type: String }
    let response_format: ResponseFormat?
    
    init(model: String, messages: [OpenAIMessage], max_tokens: Int, temperature: Double, stream: Bool? = nil, tools: [Tool]? = nil, web_search_options: [String: String]? = nil, response_format: ResponseFormat? = nil) {
        self.model = model
        self.messages = messages
        // For GPT-5 family, only send max_completion_tokens (do not include max_tokens) and force default temperature=1.0
        if model.hasPrefix("gpt-5") {
            self.max_tokens = nil
            self.max_completion_tokens = max_tokens
            self.temperature = 1.0
        } else {
            self.max_tokens = max_tokens
            self.max_completion_tokens = nil
            self.temperature = temperature
        }
        self.stream = stream
        self.tools = tools
        self.web_search_options = web_search_options
        self.response_format = response_format
    }
}

struct OpenAIResponse: Codable {
    let choices: [Choice]
    
    struct Choice: Codable {
        let message: Message
        
        struct Message: Codable {
            let content: String
        }
    }
}

class OpenAIService: ObservableObject {
    private var appToken: String { AppConfig.appToken }
    private var baseURL: String { "\(AppConfig.workerBaseURL)/openai/v1/chat/completions" }
    private var responsesURL: String { "\(AppConfig.workerBaseURL)/openai/v1/responses" }
    // Use a fully supported chat model for both non-streaming and streaming
    private let chatModel = "gpt-4o-mini"
    private let knowledgeCutoff = "October 2024"
    
    // Detect MIME type for image data (PNG/JPEG) to build correct data URLs
    private func detectImageMimeType(_ data: Data) -> String {
        // PNG signature: 89 50 4E 47 0D 0A 1A 0A
        let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        // JPEG signature: FF D8 FF
        let jpegSignature: [UInt8] = [0xFF, 0xD8, 0xFF]
        let bytes = [UInt8](data.prefix(8))
        if bytes.starts(with: pngSignature) { return "image/png" }
        if bytes.starts(with: jpegSignature) { return "image/jpeg" }
        // Default to PNG if unknown
        return "image/png"
    }

    // MARK: - New Responses API (GPT-5 mini) streaming for contextual help
    func analyzeScreenshotForContextualHelpResponses(imageData: Data) async throws -> String {
        guard let url = URL(string: responsesURL) else { throw URLError(.badURL) }
        let base64Image = imageData.base64EncodedString()
        let mime = detectImageMimeType(imageData)
        let dataURL = "data:\(mime);base64,\(base64Image)"

        let systemText = "You are ChatGPT. Provide concise, directly useful help for what is on screen. Use plain text (no markdown headings). End with: Answer: ..."
        let userText = "Analyze this screen and give the most relevant, practical help. If steps, put each on its own line."

        let input: [[String: Any]] = [
            [
                "role": "system",
                "content": [["type": "input_text", "text": systemText]]
            ],
            [
                "role": "user",
                "content": [
                    ["type": "input_text", "text": userText],
                    ["type": "input_image", "image_url": dataURL]
                ]
            ]
        ]

        var payload: [String: Any] = [
            "model": "gpt-5-mini",
            "input": input,
            "stream": false,
            "modalities": ["text"],
            "response_format": ["type": "text"]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(appToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let msg = String(data: data, encoding: .utf8) ?? "Server error"
            throw NSError(domain: "OpenAI", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: msg])
        }
        // Best-effort parse for Responses API: try to pull output_text or deep collect
        if let obj = try? JSONSerialization.jsonObject(with: data), let text = Self.extractTextFromChatResponseObject(obj) {
            return sanitizeContextualHelpResponse(text)
        }
        return sanitizeContextualHelpResponse(String(data: data, encoding: .utf8) ?? "")
    }

    func streamScreenshotForContextualHelpResponses(
        imageData: Data,
        onDelta: @escaping (String) -> Void,
        onComplete: @escaping () -> Void
    ) async throws {
        guard let url = URL(string: responsesURL) else { throw URLError(.badURL) }

        let base64Image = imageData.base64EncodedString()
        let mime = detectImageMimeType(imageData)
        let dataURL = "data:\(mime);base64,\(base64Image)"

        let systemText = "You are ChatGPT. Provide concise, directly useful help for what is on screen. Use plain text. End with: Answer: ..."
        let userText = "Analyze this screen and give the most relevant, practical help. If steps, put each on its own line."

        let input: [[String: Any]] = [
            [
                "role": "system",
                "content": [["type": "input_text", "text": systemText]]
            ],
            [
                "role": "user",
                "content": [
                    ["type": "input_text", "text": userText],
                    ["type": "input_image", "image_url": dataURL]
                ]
            ]
        ]

        let payload: [String: Any] = [
            "model": "gpt-5-mini",
            "input": input,
            "stream": true,
            "modalities": ["text"],
            "response_format": ["type": "text"]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(appToken)", forHTTPHeaderField: "Authorization")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("keep-alive", forHTTPHeaderField: "Connection")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 45
        config.timeoutIntervalForResource = 75
        let session = URLSession(configuration: config)

        print("🟣 GPT-5 Responses: streaming via /responses")
        let (bytes, response) = try await session.bytes(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let (edata, _) = try await session.data(for: request)
            let msg = String(data: edata, encoding: .utf8) ?? "Server error"
            print("🔴 GPT-5 Responses HTTP error: \(http.statusCode) — \(msg)")
            throw NSError(domain: "OpenAI", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: msg])
        }

        var accumulated = ""
        var debugCount = 0
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let dataPart = String(line.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
            if dataPart == "[DONE]" { break }
            guard let jsonData = dataPart.data(using: .utf8) else { continue }
            guard let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else { continue }

            if debugCount < 5 {
                let keys = Array(obj.keys)
                print("🟠 RESP(resp) keys[\(debugCount)]: \(keys)")
                if let t = obj["type"] as? String { print("🟠 RESP(resp) type=\(t)") }
                debugCount += 1
            }

            if let type = obj["type"] as? String {
                switch type {
                case "response.output_text.delta":
                    if let delta = obj["delta"] as? String, !delta.isEmpty {
                        accumulated += delta
                        print("🟦 OpenAI Delta: '\(delta)' (length: \(delta.count), total accumulated: \(accumulated.count))")
                        await MainActor.run { onDelta(delta) }
                    }
                case "response.output_text.done":
                    break
                case "response.completed", "response.completed.success":
                    await MainActor.run { onComplete() }
                    return
                case "response.error":
                    let message = (obj["error"] as? [String: Any])?["message"] as? String ?? "Unknown error"
                    print("🔴 RESP(resp) error: \(message)")
                    throw NSError(domain: "OpenAI", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
                default:
                    // Ignore other event types
                    break
                }
            } else {
                // Fallback best-effort for unusual shapes
                if let s = obj["output_text"] as? String, !s.isEmpty {
                    accumulated += s
                    print("🟨 OpenAI Fallback output_text: '\(s)' (length: \(s.count))")
                    await MainActor.run { onDelta(s) }
                } else if let s = obj["text"] as? String, !s.isEmpty {
                    accumulated += s
                    print("🟨 OpenAI Fallback text: '\(s)' (length: \(s.count))")
                    await MainActor.run { onDelta(s) }
                }
            }
        }
        await MainActor.run { onComplete() }
    }
    // Best-effort extraction for text from diverse OpenAI/preview responses
    private static func extractTextFromChatResponseObject(_ obj: Any) -> String? {
        guard let root = obj as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let first = choices.first else { return nil }

        // 1) Standard message.content as String
        if let message = first["message"] as? [String: Any], let contentStr = message["content"] as? String, !contentStr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return contentStr
        }
        // 2) message.content as array of parts with {type, text}
        if let message = first["message"] as? [String: Any], let contentArr = message["content"] as? [[String: Any]] {
            var buf = ""
            for part in contentArr {
                if let t = part["text"] as? String, !t.isEmpty { buf += t }
                else if let inner = part["content"] as? String, !inner.isEmpty { buf += inner }
            }
            if !buf.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return buf }
        }
        // 3) Some models use output_text (string or array)
        if let outStr = first["output_text"] as? String, !outStr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return outStr
        }
        if let outArr = first["output_text"] as? [String] {
            let joined = outArr.joined()
            if !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return joined }
        }
        // 4) Legacy top-level content
        if let contentStr = first["content"] as? String, !contentStr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return contentStr
        }
        // 5) Deep-scan for nested text fields (handles GPT-5 nested content shapes)
        if let deep = deepCollectText(from: first), !deep.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return deep
        }
        if let deepRoot = deepCollectText(from: root), !deepRoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return deepRoot
        }
        return nil
    }

    // Recursively collect text from arbitrarily nested structures
    private static func deepCollectText(from any: Any) -> String? {
        var buffer = ""
        func walk(_ node: Any) {
            if let s = node as? String {
                if !s.isEmpty { buffer += s }
                return
            }
            if let dict = node as? [String: Any] {
                // Prefer output_text and text fields
                if let out = dict["output_text"] as? String { buffer += out }
                if let outArr = dict["output_text"] as? [String] { buffer += outArr.joined() }
                if let t = dict["text"] as? String { buffer += t }
                if let contentStr = dict["content"] as? String { buffer += contentStr }
                if let contentArr = dict["content"] as? [Any] { contentArr.forEach { walk($0) } }
                // Also traverse message if present
                if let message = dict["message"] { walk(message) }
                return
            }
            if let arr = node as? [Any] {
                arr.forEach { walk($0) }
                return
            }
        }
        walk(any)
        return buffer.isEmpty ? nil : buffer
    }
    
    // Helper to get current date context
    private func getCurrentDateContext() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMMM d, yyyy"
        return "Today is \(formatter.string(from: Date()))"
    }
    
    // Create a focused, digestible summary of research data
    private func createFocusedResearchSummary(_ research: ResearchBundle, for query: String) -> String {
        var summary: [String] = []
        
        summary.append("Current web information for: \(query)")
        summary.append("")
        
        // Process top 3 highest quality sources
        let limitedSources = Array(research.sources.prefix(3))
        for (index, source) in limitedSources.enumerated() {
            let sourceNum = index + 1
            summary.append("[\(sourceNum)] \(source.title)")
            
            if let site = source.site {
                summary.append("From: \(site)")
            }
            
            if !source.snippet.isEmpty {
                let cleanSnippet = source.snippet
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "\n", with: " ")
                    .replacingOccurrences(of: "  ", with: " ")
                    .prefix(300)
                summary.append("\(cleanSnippet)")
            }
            summary.append("")
        }
        
        // Always include a clean Sources list with direct links
        if !limitedSources.isEmpty {
            summary.append("Sources:")
            for (index, s) in limitedSources.enumerated() {
                summary.append("[\(index + 1)] \(s.title) — \(s.url)")
            }
        }
        
        return summary.joined(separator: "\n")
    }
    
    // Auto-research query analysis cache
    private var queryAnalysisCache: [String: Bool] = [:]
    private let cacheQueue = DispatchQueue(label: "queryAnalysisCache")
    
    // Smart content detection for optimal formatting
    private func analyzeUserQuery(_ query: String) -> ContentAnalysis {
        let lowercased = query.lowercased()
        
        let listIndicators = ["list", "steps", "ways", "methods", "tips", "points", "items", "how to", "tutorial", "guide", "process"]
        let tableIndicators = ["compare", "comparison", "vs", "versus", "difference", "pros and cons", "benefits", "advantages", "disadvantages"]
        let codeIndicators = ["code", "programming", "function", "script", "syntax", "example", "implement", "write a", "create a"]
        let explanationIndicators = ["explain", "what is", "why", "how does", "tell me about", "describe"]
        
        var needsList = listIndicators.contains { lowercased.contains($0) }
        var needsTable = tableIndicators.contains { lowercased.contains($0) }
        var needsCode = codeIndicators.contains { lowercased.contains($0) }
        var needsExplanation = explanationIndicators.contains { lowercased.contains($0) }
        
        // Check for numbered questions/multiple parts
        let numberedPattern = "\\b\\d+[.)]\\s"
        if query.range(of: numberedPattern, options: .regularExpression) != nil {
            needsList = true
        }
        
        return ContentAnalysis(
            shouldUseLists: needsList,
            shouldUseTables: needsTable,
            shouldUseCodeBlocks: needsCode,
            shouldUseDetailedExplanation: needsExplanation,
            complexity: determineComplexity(query)
        )
    }

    // Public wrapper to reuse the same heuristic from outside
    func likelyNeedsWeb(_ query: String) -> Bool {
        return shouldSearchWebCached(for: query)
    }
    
    private func determineComplexity(_ query: String) -> ContentComplexity {
        if query.count < 50 { return .simple }
        if query.count < 150 { return .moderate }
        return .complex
    }
    
    private func enhanceSystemPromptWithAnalysis(_ basePrompt: String, analysis: ContentAnalysis) -> String {
        var enhancements: [String] = []
        
        if analysis.shouldUseLists {
            enhancements.append("- Structure your response with clear numbered or bulleted lists")
            enhancements.append("- Break down processes into step-by-step instructions")
        }
        
        if analysis.shouldUseTables {
            enhancements.append("- Use markdown tables to compare different options or features")
            enhancements.append("- Present pros/cons or comparisons in a structured table format")
        }
        
        if analysis.shouldUseCodeBlocks {
            enhancements.append("- Include practical code examples with proper syntax highlighting")
            enhancements.append("- Use ``` blocks with language tags for all code samples")
        }
        
        if analysis.shouldUseDetailedExplanation {
            enhancements.append("- Provide comprehensive explanations with context and background")
            enhancements.append("- Use headings to organize different aspects of the topic")
        }
        
        if !enhancements.isEmpty {
            let enhancementText = "\n\n**Additional Formatting Guidelines for this response:**\n" + enhancements.joined(separator: "\n")
            return basePrompt + enhancementText
        }
        
        return basePrompt
    }
    
    // MARK: - Auto-Research Detection
    
    /// Heuristic detection for when web search is likely needed
    private func shouldSearchWeb(for query: String) -> Bool {
        let q = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty { return false }
        
        // Obvious cases: summarizing a link or asking for sources
        if q.contains("http://") || q.contains("https://") { return true }
        let citationIntent = ["cite", "source", "sources", "references", "link", "according to", "citation"]
        if citationIntent.contains(where: { q.contains($0) }) { return true }
        
        // Recency indicators
        let recencyTerms = [
            "latest", "breaking", "news", "today", "this week", "right now", "recent", "update", "updates",
            "current", "as of", "new in", "changelog", "release notes", "announced", "rolled out"
        ]
        if recencyTerms.contains(where: { q.contains($0) }) { return true }
        
        // Time-sensitive domains
        let timeSensitive = [
            "price", "stock", "earnings", "ipo", "merger", "acquisition", "weather", "forecast", "score",
            "game", "schedule", "deadline", "when is", "who won", "is x down", "status", "outage", "cve",
            "vulnerability", "security advisory"
        ]
        if timeSensitive.contains(where: { q.contains($0) }) { return true }
        
        // Short WH questions about facts/entities may need sources
        let whStarts = ["who ", "when ", "where ", "how many", "how much", "what time", "what date"]
        if whStarts.contains(where: { q.hasPrefix($0) }) && q.count <= 140 { return true }
        
        // Avoid browsing for creative/how-to/code unless recency is explicit
        let avoid = ["explain", "how to", "tutorial", "guide", "example", "code", "implement", "design", "write", "brainstorm", "poem", "story", "rewrite", "refactor"]
        if avoid.contains(where: { q.contains($0) }) { return false }
        
        return false
    }
    
    /// Cached version of shouldSearchWeb to improve performance
    private func shouldSearchWebCached(for query: String) -> Bool {
        let cacheKey = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Check cache first
        let cached = cacheQueue.sync { queryAnalysisCache[cacheKey] }
        if let cached = cached { return cached }
        
        // Fast local analysis - no API call needed
        let result = shouldSearchWeb(for: query)
        
        cacheQueue.async { [weak self] in
            self?.queryAnalysisCache[cacheKey] = result
            
            // Limit cache size to prevent memory bloat
            if let self = self, self.queryAnalysisCache.count > 100 {
                let keysToRemove = Array(self.queryAnalysisCache.keys.prefix(50))
                keysToRemove.forEach { self.queryAnalysisCache.removeValue(forKey: $0) }
            }
        }
        
        return result
    }
    
    // LLM-backed decision for borderline cases (uses gpt-4o in high-stakes contexts)
    private func classifyWebNeedLLM(_ query: String) async -> (should: Bool, queries: [String])? {
        let systemText = """
        Return ONLY JSON: {"should_browse": boolean, "queries": string[]}
        Decide if answering the user's question likely needs current web data or citations. Prefer false unless recency, verification, or a specific link/domain is required. If true, include 1–3 concise search queries.
        """
        let system = OpenAIMessage(role: "system", content: [OpenAIMessage.Content(type: "text", text: systemText, image_url: nil)])
        let user = OpenAIMessage(role: "user", content: [OpenAIMessage.Content(type: "text", text: query, image_url: nil)])
        let req = OpenAIRequest(model: "gpt-4o", messages: [system, user], max_tokens: 120, temperature: 0.0)
        guard let raw = try? await sendRequest(req),
              let jsonStr = extractFirstJSONObjectString(from: raw),
              let data = jsonStr.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let should = obj["should_browse"] as? Bool
        else { return nil }
        let queries = obj["queries"] as? [String] ?? []
        return (should, queries)
    }
    
    /// Unified decision: heuristic first, then LLM probe for borderline cases
    private func decideResearch(for query: String) async -> (needed: Bool, queries: [String]) {
        if shouldSearchWebCached(for: query) { return (true, []) }
        if let res = await classifyWebNeedLLM(query), res.should { return (true, res.queries) }
        return (false, [])
    }
    
    func sendTextMessage(_ message: String) async throws -> String {
        let openAIMessage = OpenAIMessage(
            role: "user",
            content: [OpenAIMessage.Content(type: "text", text: message, image_url: nil)]
        )
        
        let request = OpenAIRequest(
            model: chatModel,
            messages: [openAIMessage],
            max_tokens: 1000,
            temperature: 0.1
        )
        
        return try await sendRequest(request)
    }

    // Plain chat (no research): Natural ChatGPT-like responses
    func sendRawChat(_ message: String) async throws -> String {
        let analysis = analyzeUserQuery(message)
        let baseSystemText = """
        You are ChatGPT by OpenAI. \(getCurrentDateContext()).
        Knowledge cutoff: \(knowledgeCutoff).
        Keep answers matching query length or user desire. Do not claim web access. If the query likely needs current facts or post-cutoff events, say you may be outdated and suggest turning on Internet Mode.
        """
        
        let enhancedSystemText = enhanceSystemPromptWithAnalysis(baseSystemText, analysis: analysis)
        let system = OpenAIMessage(role: "system", content: [OpenAIMessage.Content(type: "text", text: enhancedSystemText, image_url: nil)])
        let user = OpenAIMessage(role: "user", content: [OpenAIMessage.Content(type: "text", text: message, image_url: nil)])
        let request = OpenAIRequest(model: chatModel, messages: [system, user], max_tokens: 4000, temperature: 0.2)
        return try await sendRequest(request)
    }

    // Chat with short history (last few messages) and optional research grounding
    func sendChatWithHistory(history: [ChatMessage], userText: String, research: ResearchBundle?, autoResearch: Bool = true, model: AIModel = .gpt4o) async throws -> String {
        // Only use web when explicitly forced via provided research
        let needsWeb = research != nil
        if model == .geminiFlash {
            // Respect forced research if provided; also enable web based on recency heuristics
            let forced = (research != nil)
            let needsWeb = forced || shouldSearchWebCached(for: userText)
            var sources: [ResearchBundle.Source]? = nil
            sources = research?.sources
            
            // Convert chat history to format Gemini expects
            let geminiHistory: [(role: String, content: String)] = history.suffix(24).map { m in
                (m.isUser ? "user" : "assistant", m.content)
            }
            
            let text = try await GeminiService.shared.generateWithHistory(history: geminiHistory, query: userText, sources: sources, enableWeb: needsWeb)
            return text
        }
        if model == .claudeHaiku {
            // Claude Haiku: no browsing; ignore research toggle and send plain chat with history
            let messages: [(role: String, text: String)] = history.suffix(24).map { m in (m.isUser ? "user" : "assistant", m.content) } + [("user", userText)]
            let system = """
            You are Claude 3.5 Haiku.
            Provide thorough, well-structured answers by default.  Match the length and detail level of the user's query.
            Use clean Markdown formatting. Keep a friendly, expert tone.
            """
            let text = try await AnthropicService.shared.generate(messages: messages, system: system, maxTokens: 6000)
            return text
        }
        // Auto-detect if web search is needed when not manually provided
        var finalResearch = research
        var searchQueries: [String] = []
        // Auto-research disabled unless forced by toggle
        
        let analysis = analyzeUserQuery(userText)
        let baseFormattingSystem = """
        You are ChatGPT by OpenAI. \(getCurrentDateContext()).
        Knowledge cutoff: \(knowledgeCutoff).
        Keep answers concise. If a RESEARCH section is present, ground factual claims in it. Otherwise, do not claim web access. If the query likely needs current facts or post-cutoff events, say you may be outdated and suggest turning on Internet Mode.
        """
        
        // Append minimal browsing rule only when GPT search will be used
        let willUseWebTool = (model != .geminiFlash) && (finalResearch != nil || shouldSearchWebCached(for: userText))
        let browsingRule = "\n\nBrowsing Rules:\n- Cite only links you actually used and that are directly relevant.\n- Do not place bare domains (e.g., pcgamer.com) inline.\n- Use numeric citations like [1] that correspond to a final Sources list with full URLs.\n- If you mention a source inline, use only [n], never the domain name."
        let simpleBaseForGPT5Mini = """
        You are ChatGPT. \(getCurrentDateContext()).
        Knowledge cutoff: \(knowledgeCutoff).
        Answer naturally and directly. Default to concise unless the user asks for depth.
        If RESEARCH is provided, ground claims in it and include brief inline citations like [1], [2] with a final Sources list (full URLs). Otherwise, do not mention browsing.
        """
        let formattingSystem: String = {
            if model == .gpt5Mini {
                return simpleBaseForGPT5Mini + (willUseWebTool ? browsingRule : "")
            } else {
                return enhanceSystemPromptWithAnalysis(baseFormattingSystem + (willUseWebTool ? browsingRule : ""), analysis: analysis)
            }
        }()
        var messages: [OpenAIMessage] = []
        messages.append(OpenAIMessage(role: "system", content: [OpenAIMessage.Content(type: "text", text: formattingSystem, image_url: nil)]))
        if let finalResearch = finalResearch {
            print("📊 Including research data with \(finalResearch.sources.count) sources in prompt")
            // Create a focused research summary instead of dumping all data
            let researchSummary = createFocusedResearchSummary(finalResearch, for: userText)
            
            let researchInstruction = """
            \(researchSummary)
            
            Always integrate the above current information into your response. Include links where helpful.
            """
            
            print("📋 Focused research summary being sent:")
            print(researchSummary.prefix(400))
            
            messages.append(OpenAIMessage(role: "system", content: [OpenAIMessage.Content(type: "text", text: researchInstruction, image_url: nil)]))
            if let notes = finalResearch.notes, !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                messages.append(OpenAIMessage(role: "system", content: [OpenAIMessage.Content(type: "text", text: "SYNTHESIZED_NOTES:\n\(notes)", image_url: nil)]))
            }
        }
        // Include last few exchanges
        let historyWindow = (model == .gpt5Mini) ? 12 : 24
        for m in history.suffix(historyWindow) {
            let role = m.isUser ? "user" : "assistant"
            messages.append(OpenAIMessage(role: role, content: [OpenAIMessage.Content(type: "text", text: m.content, image_url: nil)]))
        }
        // Current user message
        let finalUserText = userText
        messages.append(OpenAIMessage(role: "user", content: [OpenAIMessage.Content(type: "text", text: finalUserText, image_url: nil)]))

        // If GPT and we either auto-detected or forced research, use search-preview model or attach web_search_preview tool
        let needsWebTool = (model != .geminiFlash && model != .claudeHaiku) && (finalResearch != nil)
        var tools: [OpenAIRequest.Tool]? = nil
        var actualModel: String = {
            switch model {
            case .gpt4o:
                return InternalAIModel.gpt4o.rawValue
            case .gpt5Mini:
                return InternalAIModel.gpt5Mini.rawValue
            case .geminiFlash, .claudeHaiku:
                return model.rawValue
            }
        }()
        var webSearchOptions: [String: String]? = nil
        if needsWebTool {
            // Prefer the search-enabled model if available; otherwise attach preview tool
            // For now, use gpt-4o-search-preview for both GPT-4o and GPT-5 mini since no GPT-5 search model exists yet
            actualModel = "gpt-4o-mini-search-preview"
            webSearchOptions = [:]
            tools = nil
        }
        // For search-preview models, omit temperature (server rejects it). We'll pass 0.0 but drop it when building payload.
        let finalTemperature = 0.2
        print("🤖 Using model: \(actualModel) (search: \(needsWebTool))")
        let request = OpenAIRequest(model: actualModel, messages: messages, max_tokens: finalResearch != nil ? 6000 : 4000, temperature: finalTemperature, stream: nil, tools: tools, web_search_options: webSearchOptions)
        return try await sendRequest(request)
    }

    // True SSE token streaming for chat with history and optional research
    func streamChatWithHistory(
        history: [ChatMessage],
        userText: String,
        research: ResearchBundle?,
        contextSummary: String? = nil,
        temperature: Double = 0.7,
        maxTokens: Int = 7000,
        autoResearch: Bool = true,
        model: AIModel = .gpt4o,
        onAutoResearchStart: (() -> Void)? = nil,
        onDelta: @escaping (String) -> Void,
        onComplete: @escaping () -> Void
    ) async throws {
        guard let url = URL(string: baseURL) else { throw URLError(.badURL) }

        if model == .geminiFlash {
            // For streaming, respect forced research if provided; compute in steps to avoid await-in-ternary issues
            let forced = (research != nil)
            let needsWeb = forced
            var sources: [ResearchBundle.Source]? = nil
            sources = research?.sources
            
            // Convert chat history to format Gemini expects
            let geminiHistory: [(role: String, content: String)] = history.suffix(24).map { m in
                (m.isUser ? "user" : "assistant", m.content)
            }
            
            try await GeminiService.shared.streamGenerateWithHistory(history: geminiHistory, query: userText, sources: sources, enableWeb: needsWeb, onDelta: { delta in
                onDelta(delta)
            })
            await MainActor.run { onComplete() }
            return
        }
        if model == .claudeHaiku {
            // Claude Haiku streaming: no browsing; ignore research. Stream deltas.
            let messages: [(role: String, text: String)] = history.suffix(24).map { m in (m.isUser ? "user" : "assistant", m.content) } + [("user", userText)]
            let system = """
            You are Claude 3.5 Haiku.
            Provide thorough, well-structured answers by default. 
            Use clean Markdown formatting. Keep a friendly, expert tone.
            """
            let allowedMax = min(maxTokens, 8192)
            try await AnthropicService.shared.streamGenerate(messages: messages, system: system, maxTokens: allowedMax, onDelta: { delta in
                onDelta(delta)
            })
            await MainActor.run { onComplete() }
            return
        }

        // Auto-detect if web search is needed when not manually provided
        var finalResearch = research
        var searchQueries: [String] = []
        // Auto-research disabled unless forced by toggle

        let analysis = analyzeUserQuery(userText)
        let baseSystemText = """
        You are ChatGPT by OpenAI. \(getCurrentDateContext()).
        Knowledge cutoff: \(knowledgeCutoff).
        Keep answers concise. Do not claim web access. If a RESEARCH section is present, ground factual claims in it. If not, and the query likely needs current facts or post-cutoff events, say you may be outdated and suggest turning on Internet Mode.
        """
        
        let willUseWebTool = (model != .geminiFlash) && (finalResearch != nil || shouldSearchWebCached(for: userText))
        let browsingRule = "\n\nBrowsing Rules:\n- Cite only links you actually used and that are directly relevant.\n- Do not place bare domains (e.g., pcgamer.com) inline.\n- Use numeric citations like [1] that correspond to a final Sources list with full URLs.\n- If you mention a source inline, use only [n], never the domain name."
        let simpleBaseForGPT5Mini = """
        You are ChatGPT. \(getCurrentDateContext()).
        Knowledge cutoff: \(knowledgeCutoff).
        Answer naturally and directly. Default to concise unless the user asks for depth.
        If RESEARCH is provided, ground claims in it and include brief inline citations like [1], [2] with a final Sources list (full URLs). Otherwise, do not mention browsing.
        """
        let systemText: String = {
            if model == .gpt5Mini {
                return simpleBaseForGPT5Mini + (willUseWebTool ? browsingRule : "")
            } else {
                return enhanceSystemPromptWithAnalysis(baseSystemText + (willUseWebTool ? browsingRule : ""), analysis: analysis)
            }
        }()
        var msgs: [[String: Any]] = []
        msgs.append([
            "role": "system",
            "content": [["type": "text", "text": systemText]]
        ])
        if let summary = contextSummary, !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            msgs.append(["role": "system", "content": [["type": "text", "text": "CONTEXT_SUMMARY:\n\(summary)"]]])
        }
        if let finalResearch = finalResearch {
            print("📊 Including research data with \(finalResearch.sources.count) sources in streaming prompt")
            
            // Create a focused research summary instead of dumping all data
            let researchSummary = createFocusedResearchSummary(finalResearch, for: userText)
            
            let researchInstruction = """
            \(researchSummary)
            
            Always integrate the above current information into your response. Include links where helpful.
            """
            
            print("📋 Focused research summary being sent to streaming:")
            print(researchSummary.prefix(400))
            
            msgs.append(["role": "system", "content": [["type": "text", "text": researchInstruction]]])
            
            if let notes = finalResearch.notes, !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                msgs.append(["role": "system", "content": [["type": "text", "text": "SYNTHESIZED_NOTES:\n\(notes)"]]])
            }
        }
        let historyWindow = (model == .gpt5Mini) ? 12 : 24
        for m in history.suffix(historyWindow) {
            msgs.append([
                "role": m.isUser ? "user" : "assistant",
                "content": [["type": "text", "text": m.content]]
            ])
        }
        // Add user message
        let finalUserText = userText
        msgs.append(["role": "user", "content": [["type": "text", "text": finalUserText]]])

        // If GPT and we either auto-detected or forced research, use search-preview model
        let needsWebTool = (model != .geminiFlash && model != .claudeHaiku) && (finalResearch != nil)
        var actualModel: String = {
            switch model {
            case .gpt4o:
                return InternalAIModel.gpt4o.rawValue
            case .gpt5Mini:
                return InternalAIModel.gpt5Mini.rawValue
            case .geminiFlash, .claudeHaiku:
                return model.rawValue
            }
        }()
        if needsWebTool {
            // For now, use gpt-4o-search-preview for both GPT-4o and GPT-5 mini since no GPT-5 search model exists yet
            actualModel = "gpt-4o-mini-search-preview"
        }
        print("🤖 Using model: \(actualModel) (search: \(needsWebTool))")
        
        var payload: [String: Any] = [
            "model": actualModel,
            "messages": msgs,
            "stream": true
        ]
        
        // Use max_completion_tokens for GPT-5 family, max_tokens for others
        if actualModel.hasPrefix("gpt-5") {
            payload["max_completion_tokens"] = finalResearch != nil ? min(maxTokens, 6000) : maxTokens
        } else {
            payload["max_tokens"] = finalResearch != nil ? min(maxTokens, 6000) : maxTokens
        }
        // Only set temperature and penalty parameters for non-GPT-5 models when not using web tools
        if !needsWebTool && !actualModel.hasPrefix("gpt-5") { 
            payload["temperature"] = finalResearch != nil ? 0.6 : temperature 
            payload["presence_penalty"] = 0.05
            payload["frequency_penalty"] = 0.0
        }

        if needsWebTool { payload["web_search_options"] = [:] }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(appToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("keep-alive", forHTTPHeaderField: "Connection")
        
        // Only send app token - no user auth needed for simplified worker
        
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        // Aggressive timeouts to keep browsing responses snappy
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 45
        config.timeoutIntervalForResource = 75
        let session = URLSession(configuration: config)

        let (bytes, response) = try await session.bytes(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            // Try to fetch error body for better diagnostics
            let (edata, _) = try await session.data(for: request)
            let responseBody = String(data: edata, encoding: .utf8) ?? "Unable to decode response"
            print("❌ Streaming HTTP Error: \(http.statusCode)")
            print("📝 Response body: \(responseBody)")
            print("🌐 Request URL: \(baseURL)")
            
            if let message = Self.decodeAPIErrorMessage(from: edata) {
                throw NSError(domain: "OpenAI", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: message])
            }
            throw NSError(domain: "OpenAI", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "Server error (status \(http.statusCode))"])
        }
        var pendingBuffer = ""
        let maxChunk = 60
        let minDelayNs: UInt64 = 25_000_000 // ~25ms between flushes
        var lastFlush = DispatchTime.now()
        var receivedAnySSE = false
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let dataPart = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if dataPart == "[DONE]" { break }
            guard let jsonData = dataPart.data(using: .utf8) else { continue }
            receivedAnySSE = true
            guard let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  let choices = obj["choices"] as? [[String: Any]],
                  let first = choices.first else { continue }

            var piece = ""
            if let delta = first["delta"] as? [String: Any] {
                // 1) Common case: delta.content is a string
                if let s = delta["content"] as? String { piece = s }
                // 2) delta.content is an array of parts with {type, text} or nested {content}
                else if let arr = delta["content"] as? [[String: Any]] {
                    for part in arr {
                        if let t = part["text"] as? String, !t.isEmpty { piece += t }
                        else if let inner = part["content"] as? String, !inner.isEmpty { piece += inner }
                    }
                }
                // 3) Some providers use delta.text directly
                if piece.isEmpty, let t = delta["text"] as? String { piece = t }
            }

            // 4) Fallback: full message chunk sometimes only appears near end
            if piece.isEmpty, let message = first["message"] as? [String: Any] {
                if let mc = message["content"] as? String { piece = mc }
                else if let mArr = message["content"] as? [[String: Any]] {
                    for part in mArr {
                        if let t = part["text"] as? String, !t.isEmpty { piece += t }
                        else if let inner = part["content"] as? String, !inner.isEmpty { piece += inner }
                    }
                }
            }
            // 5) Very small variants expose top-level text
            if piece.isEmpty, let t = first["text"] as? String { piece = t }

            if !piece.isEmpty {
                pendingBuffer += piece
                // Size-based flush
                while pendingBuffer.count >= maxChunk {
                    let chunk = String(pendingBuffer.prefix(maxChunk))
                    pendingBuffer.removeFirst(chunk.count)
                    await MainActor.run { onDelta(chunk) }
                    try? await Task.sleep(nanoseconds: minDelayNs)
                    lastFlush = DispatchTime.now()
                }
                // Time-based flush for the remainder
                let elapsed = DispatchTime.now().uptimeNanoseconds - lastFlush.uptimeNanoseconds
                if !pendingBuffer.isEmpty && elapsed >= minDelayNs {
                    let chunk = pendingBuffer
                    pendingBuffer = ""
                    await MainActor.run { onDelta(chunk) }
                    try? await Task.sleep(nanoseconds: minDelayNs)
                    lastFlush = DispatchTime.now()
                }
            }
        }
        // Final flush
        if !pendingBuffer.isEmpty {
            await MainActor.run { onDelta(pendingBuffer) }
        }
        // If the provider didn't send any SSE tokens but still completed, try to parse a full response body once
        if !receivedAnySSE {
            // No-op here because bytes.for finishes without providing a buffer; upstream providers that buffer full messages
            // typically include the full message in the last delta.message path which we handled above.
        }
        await MainActor.run { onComplete() }
    }
    
    func analyzeScreenshot(_ imageData: Data, model: AIModel = .gpt4o) async throws -> String {
              let base64Image = imageData.base64EncodedString()
        let dataURL = "data:image/jpeg;base64,\(base64Image)"
        
        let textContent = OpenAIMessage.Content(
            type: "text",
            text: "Two screenshots, 0.15s apart, side by side. The images are vertically cropped so the typing caret is at the exact vertical center in each half. Find the blinking text caret by comparing frames; also use the mouse cursor if visible. Focus analysis around the centered region. Important: The question/prompt whose answer belongs at the caret is usually ABOVE the caret; prefer text above the caret over below unless layout obviously indicates otherwise. If multiple candidates are above, choose the nearest one immediately above the caret (not the top-most on the page). Choose the SINGLE nearby question/prompt accordingly (caret has priority; cursor is a secondary cue). Return ONLY the final answer text. Never echo the question and never add 'Answer:' or extra words. If uncertain, choose the most plausible nearby question rather than returning Try Again; only output 'Try Again' if there is no readable question at all.",
            image_url: nil
        )
        
        let imageContent = OpenAIMessage.Content(
            type: "image_url",
            text: nil,
            image_url: OpenAIMessage.Content.ImageURL(url: dataURL, detail: "low")
        )
        
        let openAIMessage = OpenAIMessage(
            role: "user",
            content: [textContent, imageContent]
        )
        
        // Use the actual selected model instead of hardcoding gpt-4o-mini
        let actualModel: String = {
            switch model {
            case .gpt4o:
                return InternalAIModel.gpt4o.rawValue
            case .gpt5Mini:
                return InternalAIModel.gpt5Mini.rawValue
            case .geminiFlash, .claudeHaiku:
                // These shouldn't reach here as they're handled separately, but fallback to gpt-4o-mini
                return InternalAIModel.gpt4o.rawValue
            }
        }()
        
        let request = OpenAIRequest(
            model: actualModel,
            messages: [openAIMessage],
            max_tokens: 500,
            temperature: 0.1
        )
        
        let raw = try await sendRequest(request)
        return sanitizeAnswer(raw)
    }

    struct DirectAnswerResponse: Codable {
        let direct_answer: String
        let explanation: String
        let follow_ups: [String]?
    }

    // Chat: return structured response separating direct answer from explanation
    func sendStructuredChat(_ message: String) async throws -> DirectAnswerResponse {
        let systemText = """
        You are a concise assistant. Always respond with ONLY JSON and no preamble, using this exact schema:
        {
          "direct_answer": string,      // the exact text the user likely wants to copy; if long-form (e.g., essay), put full content here
          "explanation": string,        // surrounding context: how you got there, key reasoning, tips; 2–6 sentences; may include brief bullets separated by newlines if helpful
          "follow_ups": string[]        // 3–6 tailored next steps grounded in (a) the user's request intent you infer and (b) the content you just produced in direct_answer/explanation. Favour concrete actions or precise clarifying questions. Start with a verb, keep to 5–12 words, no trailing period. Avoid generic or redundant items.
        }
        Rules for follow_ups:
        - Reflect the most likely next thing the user will want given their request AND your output (e.g., refine, expand, compare, translate, summarize, generate related artifacts, validate, format for a destination).
        - Do not repeat the direct answer. Make each item distinct and additive.
        - If ambiguity remains, include at most one short clarifying question as a follow-up.
        If there is no clear direct answer, set direct_answer to an empty string and put your full response in explanation, but still provide high-quality follow_ups targeted to the user's intent and your output.
        Never include markdown, code fences, or additional keys. Output the JSON object only.
        """
        let system = OpenAIMessage(
            role: "system",
            content: [OpenAIMessage.Content(type: "text", text: systemText, image_url: nil)]
        )
        let user = OpenAIMessage(
            role: "user",
            content: [OpenAIMessage.Content(type: "text", text: message, image_url: nil)]
        )
        let request = OpenAIRequest(
            model: "gpt-4o-mini",
            messages: [system, user],
            max_tokens: 1000,
            temperature: 0.5
        )
        let raw = try await sendRequest(request)
        let jsonString = extractFirstJSONObjectString(from: raw) ?? raw
        guard let data = jsonString.data(using: .utf8) else {
            throw URLError(.cannotParseResponse)
        }
        do {
            return try JSONDecoder().decode(DirectAnswerResponse.self, from: data)
        } catch {
            // Attempt to relax by removing code fences if present
            let trimmed = jsonString.replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "")
            if let tdata = trimmed.data(using: .utf8), let parsed = try? JSONDecoder().decode(DirectAnswerResponse.self, from: tdata) {
                return parsed
            }
            throw error
        }
    }

    // Chat with external research context: same schema, but ground on provided research JSON
    func sendRawChatWithResearch(_ message: String, research: ResearchBundle) async throws -> String {
        let systemText = """
        \(getCurrentDateContext()). You are a helpful, up-to-date assistant. You are given web research JSON gathered today to ground your answer.
        Adapt style: for casual prompts, reply briefly; for substantive queries, provide a well-structured Markdown response when helpful.
        Guidelines for substantive responses:
        - Use short paragraphs and bullets when useful; bold key terms sparingly
        - Ground non-trivial claims in the research; if findings conflict, note differences
        - Add inline numeric markers like [1], [2] tied to the source order in RESEARCH_JSON
        - End with a "Sources" section as a Markdown list, one per line: Title — URL
        - Include full clickable URLs (http/https). Use fenced code blocks only if code is required.
        Avoid boilerplate; vary structure naturally based on the content.
        """
        let system = OpenAIMessage(role: "system", content: [OpenAIMessage.Content(type: "text", text: systemText, image_url: nil)])
        let researchJSON = try research.toJSONString()
        let researchMsg = OpenAIMessage(role: "system", content: [OpenAIMessage.Content(type: "text", text: "RESEARCH_JSON:\n\(researchJSON)", image_url: nil)])
        let user = OpenAIMessage(role: "user", content: [OpenAIMessage.Content(type: "text", text: message, image_url: nil)])
        let request = OpenAIRequest(model: "gpt-4o", messages: [system, researchMsg, user], max_tokens: 6000, temperature: 0.25)
        return try await sendRequest(request)
    }

    // Summarize a conversation into 5–10 bullets to preserve long-range context
    func summarizeConversation(history: [ChatMessage]) async throws -> String {
        let systemText = """
        You summarize a conversation into 5–10 concise bullets capturing key decisions, facts, constraints, and open questions. Use plain Markdown bullets only.
        """
        var msgs: [OpenAIMessage] = []
        msgs.append(OpenAIMessage(role: "system", content: [OpenAIMessage.Content(type: "text", text: systemText, image_url: nil)]))
        for m in history.suffix(40) {
            msgs.append(OpenAIMessage(role: m.isUser ? "user" : "assistant", content: [OpenAIMessage.Content(type: "text", text: m.content, image_url: nil)]))
        }
        let req = OpenAIRequest(model: "gpt-4o-mini", messages: msgs, max_tokens: 400, temperature: 0.2)
        return try await sendRequest(req)
    }

    // Generate 3–6 follow-up suggestions based on the last exchange
    func generateFollowUps(lastUser: String, lastAssistant: String) async throws -> [String] {
        let systemText = """
        Return ONLY a JSON array (no preamble) of 3 short follow-up suggestions that the USER could send as their next message to the assistant. Each item must be an imperative user query/command (start with a verb), not a statement from the assistant. Avoid first-person AI phrasing (no "I can..."). Allow at most one short clarifying question if ambiguity remains. Keep 5–12 words and no trailing period.
        Examples: ["Draft a polite reply to this email", "Summarize the key points from this page", "Compare RDS vs Aurora for cost and failover"]
        """
        let system = OpenAIMessage(role: "system", content: [OpenAIMessage.Content(type: "text", text: systemText, image_url: nil)])
        let user = OpenAIMessage(role: "user", content: [OpenAIMessage.Content(type: "text", text: "User: \(lastUser)\nAssistant: \(lastAssistant)", image_url: nil)])
        let req = OpenAIRequest(model: "gpt-4o-mini", messages: [system, user], max_tokens: 200, temperature: 0.5)
        let raw = try await sendRequest(req)
        // Extract first JSON array in response
        if let start = raw.firstIndex(of: "["), let end = raw.lastIndex(of: "]") {
            let json = String(raw[start...end])
            if let data = json.data(using: .utf8), let arr = try? JSONSerialization.jsonObject(with: data) as? [String] {
                // Filter to imperative, non-question items; allow at most one clarifying question
                var results: [String] = []
                var includedQuestion = false
                for item in arr {
                    let t = item.trimmingCharacters(in: .whitespacesAndNewlines)
                    if t.isEmpty { continue }
                    let lower = t.lowercased()
                    let isQuestion = t.hasSuffix("?")
                    let startsWithVerb = !lower.hasPrefix("i ") && !lower.hasPrefix("can ") && !lower.hasPrefix("let me")
                    if isQuestion {
                        if includedQuestion { continue }
                        includedQuestion = true
                        results.append(t)
                    } else if startsWithVerb {
                        results.append(t)
                    }
                    if results.count >= 3 { break }
                }
                return Array(results.prefix(3))
            }
        }
        return []
    }

    private func extractFirstJSONObjectString(from input: String) -> String? {
        guard let start = input.firstIndex(of: "{") else { return nil }
        var depth = 0
        for idx in input[start...].indices {
            let ch = input[idx]
            if ch == "{" { depth += 1 }
            if ch == "}" {
                depth -= 1
                if depth == 0 {
                    let end = input.index(after: idx)
                    return String(input[start..<end])
                }
            }
        }
        return nil
    }

    // Image + prompt: return structured response (direct_answer/explanation/follow_ups)
    func sendStructuredImageWithPrompt(imageData: Data, prompt: String, model: AIModel = .gpt4o) async throws -> DirectAnswerResponse {
        let systemText = """
        You are a concise assistant. Always respond with ONLY JSON and no preamble, using this exact schema:
        {
          "direct_answer": string,
          "explanation": string,
          "follow_ups": string[]
        }

        **CRITICAL: For charts, graphs, or visual data:**
        - Read all axis labels, scales, and units precisely
        - Don't estimate - read exact values from gridlines and data points
        - State confidence level if visual data is unclear
        - Cross-reference multiple visual elements before concluding

        Rules for follow_ups:
        - Use what you just wrote in direct_answer/explanation to anticipate the user's next likely need.
        - Do not repeat the answer; each item must be distinct and useful.
        - Include at most one clarifying question if ambiguity remains.
        """
        let system = OpenAIMessage(
            role: "system",
            content: [OpenAIMessage.Content(type: "text", text: systemText, image_url: nil)]
        )
        let base64Image = imageData.base64EncodedString()
        let mime = detectImageMimeType(imageData)
        let dataURL = "data:\(mime);base64,\(base64Image)"
        let textContent = OpenAIMessage.Content(type: "text", text: prompt, image_url: nil)
        let imageContent = OpenAIMessage.Content(type: "image_url", text: nil, image_url: OpenAIMessage.Content.ImageURL(url: dataURL, detail: "low"))
        let user = OpenAIMessage(role: "user", content: [textContent, imageContent])
        
        // Use the actual selected model instead of hardcoding gpt-4o-mini
        let actualModel: String = {
            switch model {
            case .gpt4o:
                return InternalAIModel.gpt4o.rawValue
            case .gpt5Mini:
                return InternalAIModel.gpt5Mini.rawValue
            case .geminiFlash, .claudeHaiku:
                // These shouldn't reach here as they're handled separately, but fallback to gpt-4o-mini
                return InternalAIModel.gpt4o.rawValue
            }
        }()
        
        let request = OpenAIRequest(model: actualModel, messages: [system, user], max_tokens: 1000, temperature: 0.1)
        let raw = try await sendRequest(request)
        let jsonString = extractFirstJSONObjectString(from: raw) ?? raw
        guard let data = jsonString.data(using: .utf8) else { throw URLError(.cannotParseResponse) }
        do {
            return try JSONDecoder().decode(DirectAnswerResponse.self, from: data)
        } catch {
            let trimmed = jsonString.replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "")
            if let tdata = trimmed.data(using: .utf8), let parsed = try? JSONDecoder().decode(DirectAnswerResponse.self, from: tdata) {
                return parsed
            }
            throw error
        }
    }

    // GPT-5-mini with low-quality image for faster processing
    func analyzeScreenshotForContextualHelp(imageData: Data) async throws -> String {
        let timer = CFAbsoluteTimeGetCurrent()
        
        let base64Image = imageData.base64EncodedString()
        let mime = detectImageMimeType(imageData)
        let dataURL = "data:\(mime);base64,\(base64Image)"

        let prompt = """
Analyze this screenshot and provide helpful, practical assistance for what is shown. Be concise and directly useful.

IMPORTANT: If multiple questions are visible on screen, focus on the question closest to the text cursor (I-beam). If the cursor is between questions, prioritize the nearest one above it. If no cursor is visible, choose the most prominent or central question.

If there are steps, put each on a new line.
If there's a question, answer it clearly.
Use plain text (no LaTeX).
End with "Answer: [your conclusion]" if appropriate.
"""

        // Use direct payload for GPT-5-mini with low-quality image
        let payload: [String: Any] = [
            "model": "gpt-5-mini",
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "text", "text": prompt],
                    ["type": "image_url", "image_url": ["url": dataURL, "detail": "low"]]
                ]
            ]],
            "max_completion_tokens": 4000,
            "stream": false
        ]
        
        guard let url = URL(string: baseURL) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(appToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        
        print("🟣 ContextHelp: GPT-5-mini with low-quality image")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let msg = String(data: data, encoding: .utf8) ?? "Server error"
            print("🔴 ContextHelp: HTTP \(http.statusCode) - \(msg)")
            throw NSError(domain: "OpenAI", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: msg])
        }
        
        let finalAnswer: String
        if let obj = try? JSONSerialization.jsonObject(with: data) {
            // Debug: print the raw response to see what's happening
            print("🔍 Raw response: \(obj)")
            
            if let text = Self.extractTextFromChatResponseObject(obj), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                finalAnswer = text
            } else {
                // Check for finish_reason = length with no content
                if let objDict = obj as? [String: Any],
                   let choices = objDict["choices"] as? [[String: Any]], 
                   let first = choices.first,
                   let finishReason = first["finish_reason"] as? String,
                   finishReason == "length" {
                    finalAnswer = "I need more processing capacity to analyze this image. Please try a simpler question or try again."
                } else {
                    finalAnswer = "I couldn't process this image. Please try again."
                }
            }
        } else {
            finalAnswer = "Error processing response. Please try again."
        }
        
        let ms = Int((CFAbsoluteTimeGetCurrent() - timer) * 1000)
        print("🟢 ContextHelp: GPT-5-mini completed in \(ms)ms, chars=\(finalAnswer.count)")

        let trimmed = finalAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            print("⚠️ ContextHelp: empty content from GPT-5-mini")
            return ""
        }
        
        return sanitizeContextualHelpResponse(finalAnswer)
    }
    
    // NEW: Real streaming version for contextual help - provides immediate token-by-token responses
    func streamScreenshotForContextualHelp(
        imageData: Data,
        model: AIModel = .gpt5Mini,
        onDelta: @escaping (String) -> Void,
        onComplete: @escaping () -> Void
    ) async throws {
              let base64Image = imageData.base64EncodedString()
        let mime = detectImageMimeType(imageData)
        let dataURL = "data:\(mime);base64,\(base64Image)"
        
        let textContent = OpenAIMessage.Content(
            type: "text",
            text: """
Academic assistant. Read the COMPLETE question carefully - don't rush or miss details. Format: Provide your explanation and work, then end with Answer: [result].

"Analyze the screenshot and answer the most relevant question/ Be concise and practical and if there a steps it should be on new lines. If a chart/graph is present, read labels and values exactly. Use plain text (no LaTeX). End with: Answer: ..."

Focus rule: If multiple questions are visible, prioritize the one closest to the text insertion caret (I‑beam). If the caret sits between questions, pick the nearest one above it. If no caret is visible, choose the question closest to the visual center and ignore unrelated sidebars.
""",
            image_url: nil
        )

        let imageContent = OpenAIMessage.Content(
            type: "image_url",
            text: nil,
            image_url: OpenAIMessage.Content.ImageURL(url: dataURL, detail: "low")
        )

        let openAIMessage = OpenAIMessage(
            role: "user",
            content: [textContent, imageContent]
        )

        // Use the actual selected model instead of hardcoding gpt-5-mini
        let actualModel: String = {
            switch model {
            case .gpt4o:
                return InternalAIModel.gpt4o.rawValue
            case .gpt5Mini:
                return InternalAIModel.gpt5Mini.rawValue
            case .geminiFlash, .claudeHaiku:
                // These shouldn't reach here as they're handled separately, but fallback to gpt-4o-mini
                return InternalAIModel.gpt4o.rawValue
            }
        }()

        // Use the same payload structure as the working chat streaming
        let msg: [String: Any] = [
            "role": "user",
            "content": [
                ["type": "text", "text": textContent.text ?? ""],
                ["type": "image_url", "image_url": ["url": dataURL, "detail": "low"]]
            ]
        ]
        var payload: [String: Any] = [
            "model": actualModel,
            "messages": [msg],
            "stream": true
        ]
        // For GPT-5 family, use max_completion_tokens and omit temperature/penalties  
        if actualModel.hasPrefix("gpt-5") {
            payload["max_completion_tokens"] = 6000
        } else {
            payload["max_tokens"] = 6000
        }
        
        guard let url = URL(string: baseURL) else { throw URLError(.badURL) }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(appToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("keep-alive", forHTTPHeaderField: "Connection")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        let session = URLSession(configuration: config)

        let t0 = CFAbsoluteTimeGetCurrent()
        print("🟣 ContextHelp: streaming model=gpt-5-mini vision=true")
        
        do {
            let (bytes, response) = try await session.bytes(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                // Try to get error details for better debugging
                let (errorData, _) = try await session.data(for: request)
                if let errorMessage = Self.decodeAPIErrorMessage(from: errorData) {
                    throw NSError(domain: "OpenAI", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: errorMessage])
                }
                throw NSError(domain: "OpenAI", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "Server error (status \(http.statusCode))"])
            }
            
            var accumulatedText = ""
            var debugChunkCount = 0
            for try await line in bytes.lines {
                guard line.hasPrefix("data:") else { continue }
                let data = String(line.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
                if data == "[DONE]" { 
                    print("🟢 Streaming completed with [DONE] marker")
                    break 
                }
                
                // Parse the streaming JSON response
                guard let jsonData = data.data(using: .utf8) else { 
                    print("🔴 Failed to convert data to UTF8: \(data)")
                    continue 
                }
                
                guard let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                    print("🔴 Failed to parse JSON: \(data)")
                    continue
                }
                if debugChunkCount < 5 {
                    let preview = data.prefix(1000)
                    print("🟠 SSE preview[\(debugChunkCount)]: \(preview)")
                    if let choices = json["choices"] as? [[String: Any]], let first = choices.first {
                        let keys = Array(first.keys)
                        print("🟠 SSE keys[\(debugChunkCount)]: choices[0] keys=\(keys)")
                        if let delta = first["delta"] as? [String: Any] {
                            let dkeys = Array(delta.keys)
                            print("🟠 SSE delta-keys[\(debugChunkCount)]: \(dkeys)")
                        }
                    }
                    debugChunkCount += 1
                }
                
                guard let choices = json["choices"] as? [[String: Any]],
                      let firstChoice = choices.first else {
                    print("🔴 No choices found in response: \(json)")
                    continue
                }
                // If the server signals a finish without sending any text tokens, complete without non-streaming fallback
                if let finish = firstChoice["finish_reason"] as? String, !finish.isEmpty, accumulatedText.isEmpty {
                    print("🟠 Streaming finish=\(finish) with no content; ending (no fallback)")
                    await MainActor.run { onComplete() }
                    return
                }
                
                // Extract text from various possible delta shapes, or final message chunk
                var piece = ""
                if let delta = firstChoice["delta"] as? [String: Any] {
                    if let content = delta["content"] as? String {
                        piece = content
                    } else if let contentArr = delta["content"] as? [[String: Any]] {
                        for part in contentArr {
                            if let t = part["text"] as? String, !t.isEmpty { piece += t }
                            else if let inner = part["content"] as? String, !inner.isEmpty { piece += inner }
                        }
                    }
                    // GPT-5 streaming often uses output_text (string or [string])
                    if piece.isEmpty, let outStr = delta["output_text"] as? String { piece = outStr }
                    else if piece.isEmpty, let outArr = delta["output_text"] as? [String] { piece = outArr.joined() }
                    // Some variants expose delta.text directly
                    if piece.isEmpty, let t = delta["text"] as? String { piece = t }
                }
                // Some providers send the full message only in the last chunk
                if piece.isEmpty, let message = firstChoice["message"] as? [String: Any] {
                    if let mc = message["content"] as? String { piece = mc }
                    else if let mArr = message["content"] as? [[String: Any]] {
                        for part in mArr {
                            if let t = part["text"] as? String, !t.isEmpty { piece += t }
                            else if let inner = part["content"] as? String, !inner.isEmpty { piece += inner }
                        }
                    }
                }
                // Some providers put content at choice level
                if piece.isEmpty, let contentStr = firstChoice["content"] as? String, !contentStr.isEmpty { piece = contentStr }
                else if piece.isEmpty, let contentArr = firstChoice["content"] as? [[String: Any]] {
                    for part in contentArr {
                        if let t = part["text"] as? String, !t.isEmpty { piece += t }
                        else if let inner = part["content"] as? String, !inner.isEmpty { piece += inner }
                    }
                }
                // Choice-level output_text fallback
                if piece.isEmpty, let outStr = firstChoice["output_text"] as? String { piece = outStr }
                else if piece.isEmpty, let outArr = firstChoice["output_text"] as? [String] { piece = outArr.joined() }
                // Some server variants send deltas as {type, text}
                if piece.isEmpty, let t = firstChoice["text"] as? String { piece = t }
                // Rare: top-level output_text on the event root
                if piece.isEmpty, let topOut = json["output_text"] as? String { piece = topOut }
                else if piece.isEmpty, let topArr = json["output_text"] as? [String] { piece = topArr.joined() }
                
                if !piece.isEmpty {
                    accumulatedText += piece
                    print("🔵 ContextHelp delta: '\(piece)' (+\(piece.count) chars, total=\(accumulatedText.count))")
                    await MainActor.run { onDelta(piece) }
                }
            }
            
            let ms = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
            print("🟢 ContextHelp: streaming completed in \(ms)ms, chars=\(accumulatedText.count)")
            
            // Ensure we have some content, otherwise use fallback
            if accumulatedText.isEmpty {
                print("🔴 No content received via streaming, using fallback")
                let fallbackResult = try await analyzeScreenshotForContextualHelp(imageData: imageData)
                let finalText = fallbackResult.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "I couldn’t read enough from this screen. Try again or adjust the screenshot." : fallbackResult
                await MainActor.run {
                    onDelta(finalText)
                    onComplete()
                }
            } else {
                await MainActor.run {
                    onComplete()
                }
            }
            
        } catch {
            let ms = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
            print("🔴 ContextHelp: gpt-5-mini streaming failed after \(ms)ms → falling back to non-streaming. error=\(error)")
            
            // Fallback to the existing non-streaming method
            let fallbackResult = try await analyzeScreenshotForContextualHelp(imageData: imageData)
            let finalText = fallbackResult.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "I couldn’t read enough from this screen. Try again or adjust the screenshot." : fallbackResult
            await MainActor.run {
                onDelta(finalText)
                onComplete()
            }
        }
    }
    
    
    // Send multiple images with an optional prompt. If prompt is nil/empty, instruct the model to infer the likely user request from the images and answer directly.
    func sendImagesWithOptionalPrompt(imagesData: [Data], prompt: String?, model: AIModel = .gpt4o) async throws -> String {
        guard !imagesData.isEmpty else { return "" }
        
        // Use different prompts based on model - GPT-5 needs more explicit brevity instructions
        let defaultInstruction: String
        if model == .gpt5Mini {
            defaultInstruction = "Look at the image and answer what the user is asking. Be brief and direct - give just the answer, not explanations unless specifically asked."
        } else {
            defaultInstruction = "Analyze the image(s) and provide the answer the user is most likely asking for based on the visual content. If the images show a question, form, or problem, extract the likely question and answer it directly. Return plain text only."
        }
        
        let trimmed = (prompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let effectivePrompt = trimmed.isEmpty ? defaultInstruction : "\(trimmed)\n\n\(defaultInstruction)"

        var parts: [OpenAIMessage.Content] = []
        parts.append(OpenAIMessage.Content(type: "text", text: effectivePrompt, image_url: nil))
        for data in imagesData {
            let b64 = data.base64EncodedString()
            // Assume PNG by default; upstream uses pngData(). If other formats are passed, they can still be sent as data URLs with a generic type.
            let dataURL = "data:image/png;base64,\(b64)"
            parts.append(OpenAIMessage.Content(type: "image_url", text: nil, image_url: OpenAIMessage.Content.ImageURL(url: dataURL, detail: "low")))
        }

        // Use the actual selected model instead of hardcoding gpt-4o-mini
        let actualModel: String = {
            switch model {
            case .gpt4o:
                return InternalAIModel.gpt4o.rawValue
            case .gpt5Mini:
                return InternalAIModel.gpt5Mini.rawValue
            case .geminiFlash, .claudeHaiku:
                // These shouldn't reach here as they're handled separately, but fallback to gpt-4o-mini
                return InternalAIModel.gpt4o.rawValue
            }
        }()
        
        let message = OpenAIMessage(role: "user", content: parts)
        
        // Use sufficient tokens for GPT-5 to ensure complete responses
        let maxTokens = (model == .gpt5Mini) ? 1200 : 1500
        let request = OpenAIRequest(model: actualModel, messages: [message], max_tokens: maxTokens, temperature: 0.2)
        let raw = try await sendRequest(request)
        return sanitizeAnswer(raw)
    }


    // Generic helper: send an image with a custom prompt and return sanitized text
    func sendImageWithPrompt(imageData: Data, prompt: String, model: AIModel = .gpt4o) async throws -> String {
        let base64Image = imageData.base64EncodedString()
        let dataURL = "data:image/png;base64,\(base64Image)"

        let textContent = OpenAIMessage.Content(
            type: "text",
            text: "\(prompt)\n\n**CRITICAL: Read the question THREE TIMES and look for trick wording like 'NOT', 'EXCEPT', 'LEAST', 'NEVER', 'FALSE'. Check if the question asks for the OPPOSITE of what seems obvious. Pay attention to qualifying words: 'always', 'sometimes', 'never', 'all', 'some', 'none'. For multiple choice questions: provide the FULL TEXT of the correct answer, NOT just the letter (A, B, C, D). FOCUS ON THE RIGHT ANSWER CONTENT, ignore which letter it corresponds to.**\n\n**NO LATEX ALLOWED: Write fractions as VC/M NOT \\frac{VC}{M}, write 5/2m NOT \\frac{5}{2m}. For exponents use ² ³ symbols. FORBIDDEN: Any \\frac{} or LaTeX notation.**\n\nContext: The screenshot is vertically cropped so the typing caret is at the exact vertical center. Focus analysis around that centered region. Prefer the relevant question/prompt ABOVE the caret; if multiple are above, pick the nearest one immediately above (not the highest/top-most).",
            image_url: nil
        )

        let imageContent = OpenAIMessage.Content(
            type: "image_url",
            text: nil,
            image_url: OpenAIMessage.Content.ImageURL(url: dataURL, detail: "low")
        )

        let openAIMessage = OpenAIMessage(
            role: "user",
            content: [textContent, imageContent]
        )

        // Use the actual selected model instead of hardcoding gpt-4o-mini
        let actualModel: String = {
            switch model {
            case .gpt4o:
                return InternalAIModel.gpt4o.rawValue
            case .gpt5Mini:
                return InternalAIModel.gpt5Mini.rawValue
            case .geminiFlash, .claudeHaiku:
                // These shouldn't reach here as they're handled separately, but fallback to gpt-4o-mini
                return InternalAIModel.gpt4o.rawValue
            }
        }()

        let request = OpenAIRequest(
            model: actualModel,
            messages: [openAIMessage],
            max_tokens: 700,
            temperature: 0.3
        )

        let raw = try await sendRequest(request)
        return sanitizeAnswer(raw)
    }

    // Extract just the nearest question text from the paired screenshots
    func extractQuestion(from imageData: Data, model: AIModel = .gpt4o) async throws -> String {
        let base64Image = imageData.base64EncodedString()
        let dataURL = "data:image/png;base64,\(base64Image)"
        let textContent = OpenAIMessage.Content(
            type: "text",
            text: "Two screenshots, 0.15s apart. The images are vertically cropped so the typing caret is at the exact vertical center. Detect the caret by frame difference; also use mouse cursor if visible. Return ONLY the exact text of the single question/prompt whose answer belongs at that centered caret. Important: The relevant question/prompt is typically ABOVE the caret; prefer text above over below unless layout clearly indicates otherwise (e.g., label below input). If multiple candidates are above, choose the nearest one immediately above the caret (not the top-most on the page). Output the question text only, no quotes, no prefix, no answer.",
            image_url: nil
        )
        let imageContent = OpenAIMessage.Content(
            type: "image_url",
            text: nil,
            image_url: OpenAIMessage.Content.ImageURL(url: dataURL, detail: "low")
        )
        let openAIMessage = OpenAIMessage(role: "user", content: [textContent, imageContent])
        
        // Use the actual selected model instead of hardcoding gpt-4o-mini
        let actualModel: String = {
            switch model {
            case .gpt4o:
                return InternalAIModel.gpt4o.rawValue
            case .gpt5Mini:
                return InternalAIModel.gpt5Mini.rawValue
            case .geminiFlash, .claudeHaiku:
                // These shouldn't reach here as they're handled separately, but fallback to gpt-4o-mini
                return InternalAIModel.gpt4o.rawValue
            }
        }()
        
        let request = OpenAIRequest(model: actualModel, messages: [openAIMessage], max_tokens: 200, temperature: 0.1)
        let raw = try await sendRequest(request)
        return sanitizeQuestion(raw)
    }

    // Answer a plain-text question; reply only with the final answer text
    func answerQuestionOnly(_ question: String) async throws -> String {
        let system = OpenAIMessage(role: "system", content: [OpenAIMessage.Content(type: "text", text: "You are a precise answer engine. **CRITICAL: Read the question THREE TIMES and look for trick wording like 'NOT', 'EXCEPT', 'LEAST', 'NEVER', 'FALSE'. Check if the question asks for the OPPOSITE of what seems obvious. Pay attention to qualifying words: 'always', 'sometimes', 'never', 'all', 'some', 'none'. For multiple choice questions: provide the FULL TEXT of the correct answer, NOT just the letter (A, B, C, D). FOCUS ON THE RIGHT ANSWER CONTENT, ignore which letter it corresponds to.** Respond with ONLY the final answer text to the user's question. Do not repeat the question. Do not include any meta commentary, tips, troubleshooting, or references to screenshots, images, cursors, carets, the mouse, or how to capture screens. Provide a medium-length answer (about 1–3 concise sentences, or 2–4 brief clauses for comparisons). No prefixes like 'Answer:' and no extra preamble or postscript.", image_url: nil)])
        let user = OpenAIMessage(role: "user", content: [OpenAIMessage.Content(type: "text", text: question, image_url: nil)])
        let request = OpenAIRequest(model: "gpt-4o-mini", messages: [system, user], max_tokens: 300, temperature: 0.1)
        let raw = try await sendRequest(request)
        return sanitizeAnswer(raw)
    }

    // Stream tokens for a plain-text answer and invoke a callback per delta
    func streamAnswerQuestionOnly(_ question: String, onDelta: @escaping (String) -> Void) async throws {
        guard let url = URL(string: baseURL) else { throw URLError(.badURL) }
        let system = OpenAIMessage(role: "system", content: [OpenAIMessage.Content(type: "text", text: "You are a precise answer engine. **CRITICAL: Read the question THREE TIMES and look for trick wording like 'NOT', 'EXCEPT', 'LEAST', 'NEVER', 'FALSE'. Check if the question asks for the OPPOSITE of what seems obvious. For multiple choice questions: provide the FULL TEXT of the correct answer, NOT just the letter (A, B, C, D). FOCUS ON THE RIGHT ANSWER CONTENT, ignore which letter it corresponds to.** Respond with ONLY the final answer text.", image_url: nil)])
        let user = OpenAIMessage(role: "user", content: [OpenAIMessage.Content(type: "text", text: question, image_url: nil)])
        // Build a lightweight JSON payload with stream=true
        let payload: [String: Any] = [
            "model": "gpt-4o-mini",
            "messages": [
                ["role": system.role, "content": system.content.map { ["type": $0.type, "text": $0.text ?? ""] }],
                ["role": user.role, "content": user.content.map { ["type": $0.type, "text": $0.text ?? ""] }]
            ],
            "max_tokens": 300,
            "temperature": 0.1,
            "stream": true
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(appToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw URLError(.badServerResponse)
        }
        for try await line in bytes.lines {
            // SSE lines start with "data: {json}"
            guard line.hasPrefix("data:") else { continue }
            let dataPart = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if dataPart == "[DONE]" { break }
            guard let jsonData = dataPart.data(using: .utf8) else { continue }
            if let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
               let choices = obj["choices"] as? [[String: Any]],
               let delta = choices.first?["delta"] as? [String: Any],
               let content = delta["content"] as? String, !content.isEmpty {
                await MainActor.run { onDelta(content) }
            }
        }
    }
    
    // Rewrite or continue selected text per user direction; return ONLY the text to insert
    func rewriteOrContinueText(selected: String, direction: String) async throws -> String {
        let systemPrompt = "You are an expert writing assistant. You receive an input Excerpt and a Direction. Based on the Direction: either (A) rewrite the entire Excerpt, or (B) continue the Excerpt. Always preserve the original meaning unless told otherwise, improve clarity/flow, and maintain formatting/markdown if present. Critically: Respond with ONLY the text to insert — no quotes, no commentary, no labels. If rewriting, output the full rewritten text only. If continuing, output only the continuation (do not repeat the original)."
        let system = OpenAIMessage(role: "system", content: [OpenAIMessage.Content(type: "text", text: systemPrompt, image_url: nil)])
        let userText = "Direction: \(direction)\n\nExcerpt:\n\(selected)"
        let user = OpenAIMessage(role: "user", content: [OpenAIMessage.Content(type: "text", text: userText, image_url: nil)])
        let request = OpenAIRequest(model: "gpt-4o", messages: [system, user], max_tokens: 700, temperature: 0.3)
        let raw = try await sendRequest(request)
        return sanitizeAnswer(raw)
    }
    
    func sendRequest(_ request: OpenAIRequest) async throws -> String {
        guard let url = URL(string: baseURL) else {
            throw URLError(.badURL)
        }
        
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(appToken)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        // Only send app token - no user auth needed for simplified worker
        
        let jsonData = try JSONEncoder().encode(request)
        urlRequest.httpBody = jsonData
        
        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            let message = Self.decodeAPIErrorMessage(from: data) ?? "Server error (status \(httpResponse.statusCode))"
            print("❌ HTTP Error: \(httpResponse.statusCode) — \(message)")
            print("📝 Response body: \(String(data: data, encoding: .utf8) ?? "Unable to decode")")
            print("🌐 Request URL: \(baseURL)")
            throw NSError(domain: "OpenAI", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: message])
        }
        
        // Try normal JSON decode first
        if let openAIResponse = try? JSONDecoder().decode(OpenAIResponse.self, from: data) {
            let text = openAIResponse.choices.first?.message.content ?? ""
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
        }
        // If decoding fails (or content empty), extract text best-effort
        if let obj = try? JSONSerialization.jsonObject(with: data), let text = Self.extractTextFromChatResponseObject(obj) {
            return text
        }
        // As last resort, return raw string body for visibility
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func decodeAPIErrorMessage(from data: Data) -> String? {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let err = obj["error"] as? [String: Any] {
                if let msg = err["message"] as? String { return msg }
                if let msg = err["code"] as? String { return msg }
            }
            if let msg = obj["message"] as? String { return msg }
        }
        return String(data: data, encoding: .utf8)
    }

    private func sanitizeAnswer(_ input: String) -> String {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = ["Answer:", "A:", "Ans:", "Response:", "Output:"]
        for p in prefixes {
            if text.lowercased().hasPrefix(p.lowercased()) {
                text = String(text.dropFirst(p.count)).trimmingCharacters(in: .whitespaces)
                break
            }
        }
        if (text.hasPrefix("\"") && text.hasSuffix("\"")) || (text.hasPrefix("'") && text.hasSuffix("'")) {
            text = String(text.dropFirst().dropLast())
        }
        // Normalize whitespace/newlines into single spaces for clean insertion
        text = text.replacingOccurrences(of: "\n", with: " ")
                  .replacingOccurrences(of: "\r", with: " ")
        while text.contains("  ") { text = text.replacingOccurrences(of: "  ", with: " ") }

        // Strip common meta/troubleshooting lead-ins if present
        let bannedStarts = [
            "ensure the application",
            "ensure the device",
            "check if the cursor",
            "if the issue persists",
            "try using a different screenshot",
            "screenshot",
            "cursor",
            "caret",
            "mouse"
        ]
        for prefix in bannedStarts {
            let lower = text.lowercased()
            if lower.hasPrefix(prefix) {
                // Heuristic: drop the first sentence
                if let dot = text.firstIndex(of: ".") {
                    let after = text.index(after: dot)
                    text = String(text[after...]).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                break
            }
        }

        // Remove any sentences that refer to screenshots/cursors/caret/meta guidance
        let lowerAll = text.lowercased()
        if lowerAll.contains("screenshot") || lowerAll.contains("cursor") || lowerAll.contains("caret") || lowerAll.contains("mouse") || lowerAll.contains("keyboard") || lowerAll.contains("hotkey") {
            // crude sentence split on ., !, ? keeping punctuation minimal
            let delimiters: CharacterSet = CharacterSet(charactersIn: ".!?\n")
            let rawParts = text.components(separatedBy: delimiters)
            let filtered = rawParts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { part in
                    let l = part.lowercased()
                    if l.isEmpty { return false }
                    if l.contains("screenshot") { return false }
                    if l.contains("cursor") { return false }
                    if l.contains("caret") { return false }
                    if l.contains("mouse") { return false }
                    if l.contains("keyboard") { return false }
                    if l.contains("hotkey") { return false }
                    if l.contains("frame") { return false }
                    return true
                }
            if !filtered.isEmpty {
                text = filtered.joined(separator: ". ")
            }
        }

        // De-duplicate common LLM repetition cases
        // 1) Exact duplicate halves (e.g., paragraph repeated twice)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count >= 80 {
            let midIndex = trimmed.index(trimmed.startIndex, offsetBy: trimmed.count / 2)
            let firstHalf = String(trimmed[..<midIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            let secondHalf = String(trimmed[midIndex...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if firstHalf == secondHalf {
                text = firstHalf
            }
        }

        // 2) Remove contiguous duplicate paragraphs/lines
        let separators = ["\n\n", "\n"]
        for sep in separators {
            if text.contains(sep) {
                let parts = text.components(separatedBy: sep)
                var deduped: [String] = []
                for part in parts {
                    let t = part.trimmingCharacters(in: .whitespacesAndNewlines)
                    if t.isEmpty { continue }
                    if deduped.last?.caseInsensitiveCompare(t) == .orderedSame { continue }
                    deduped.append(t)
                }
                text = deduped.joined(separator: " ")
                break
            }
        }

        // 3) Sentence-level near-duplicate removal (Jaccard similarity)
        let sentenceDelimiters = CharacterSet(charactersIn: ".!?\n")
        let rawSentences = text.components(separatedBy: sentenceDelimiters)
        var cleanedSentences: [String] = []
        for raw in rawSentences {
            let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if s.isEmpty { continue }
            var isDup = false
            for kept in cleanedSentences {
                if isNearDuplicate(kept, s) { isDup = true; break }
            }
            if !isDup { cleanedSentences.append(s) }
        }
        if !cleanedSentences.isEmpty {
            text = cleanedSentences.joined(separator: ". ")
        }
        return text
    }

    // Remove generic inline domains and keep only real http(s) links; limit and format a clean Sources section
    func sanitizeWebCitationsInResponse(_ input: String) -> String {
        var text = input
        // 1) Extract http/https links to build Sources and mapping
        var urls: [URL] = []
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            let ns = text as NSString
            let range = NSRange(location: 0, length: ns.length)
            detector.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
                if let m = match, let u = m.url, (u.scheme == "http" || u.scheme == "https") {
                    // Require non-empty path to avoid homepages only
                    if !u.path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        urls.append(u)
                    }
                }
            }
        }
        // 2) Deduplicate and cap to 4
        var seen: Set<String> = []
        let unique = urls.filter { u in
            if seen.contains(u.absoluteString) { return false }
            seen.insert(u.absoluteString)
            return true
        }
        let kept = Array(unique.prefix(4))
        // Build host -> numeric index map
        var hostIndex: [String: Int] = [:]
        for (i, u) in kept.enumerated() {
            let host = (u.host ?? "").replacingOccurrences(of: "www.", with: "")
            if !host.isEmpty { hostIndex[host] = i + 1 }
        }

        // 3) Replace inline (domain.com, domain2.com) with numeric markers [1][2]
        if !hostIndex.isEmpty {
            let pattern = "\\(([A-Za-z0-9_.-]+\\.[A-Za-z]{2,}(?:\\s*,\\s*[A-Za-z0-9_.-]+\\.[A-Za-z]{2,})*)\\)"
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                let ns = text as NSString
                let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length))
                var result = text
                for m in matches.reversed() {
                    let inside = ns.substring(with: m.range(at: 1))
                    let domains = inside.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "www.", with: "") }
                    let indices = domains.compactMap { hostIndex[$0] }
                    let replacement = indices.isEmpty ? "" : indices.map { "[\($0)]" }.joined()
                    let rns = result as NSString
                    result = rns.replacingCharacters(in: m.range, with: replacement)
                }
                text = result
            }
        }

        // 3b) Remove any remaining inline bare-domain parentheses not mapped above
        if let cleanup = try? NSRegularExpression(pattern: "\\(([A-Za-z0-9_.-]+\\.[A-Za-z]{2,}(?:\\s*,\\s*[A-Za-z0-9_.-]+\\.[A-Za-z]{2,})*)\\)", options: [.caseInsensitive]) {
            text = cleanup.stringByReplacingMatches(in: text, options: [], range: NSRange(location: 0, length: (text as NSString).length), withTemplate: "")
        }

        // 4) Remove any existing trailing Sources section (best-effort)
        if let range = text.range(of: "\nSources:", options: [.caseInsensitive, .backwards]) {
            text = String(text[..<range.lowerBound])
        }
        // 5) Append clean Sources if any remain
        if !kept.isEmpty {
            let lines = kept.map { "- \($0.absoluteString)" }.joined(separator: "\n")
            text += "\n\nSources:\n" + lines
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func sanitizeContextualHelpResponse(_ input: String) -> String {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Remove common AI response prefixes
        let prefixes = ["Based on what I can see", "Looking at this", "From this image", "I can see that", "It appears that", "This appears to be", "This looks like"]
        for prefix in prefixes {
            if text.lowercased().hasPrefix(prefix.lowercased()) {
                // Find the first comma or period and start from there
                if let commaIndex = text.firstIndex(of: ",") {
                    text = String(text[text.index(after: commaIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                    break
                }
            }
        }
        
        // Remove any references to screenshots or images
        text = text.replacingOccurrences(of: "screenshot", with: "", options: .caseInsensitive)
        text = text.replacingOccurrences(of: "image", with: "", options: .caseInsensitive)
        text = text.replacingOccurrences(of: "picture", with: "", options: .caseInsensitive)
        
        // Clean up any double spaces
        while text.contains("  ") {
            text = text.replacingOccurrences(of: "  ", with: " ")
        }
        
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Dedup helpers
    private func isNearDuplicate(_ a: String, _ b: String) -> Bool {
        let na = normalizeForCompare(a)
        let nb = normalizeForCompare(b)
        if na.isEmpty || nb.isEmpty { return false }
        if na == nb { return true }
        if na.contains(nb) || nb.contains(na) { return true }
        let sim = jaccardSimilarity(na, nb)
        return sim >= 0.85
    }
    
    private func normalizeForCompare(_ s: String) -> String {
        let lowered = s.lowercased()
        let removedPunct = lowered.components(separatedBy: CharacterSet.punctuationCharacters).joined()
        let collapsed = removedPunct.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        var result = collapsed
        while result.contains("  ") { result = result.replacingOccurrences(of: "  ", with: " ") }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private func jaccardSimilarity(_ a: String, _ b: String) -> Double {
        let setA = Set(a.split(separator: " "))
        let setB = Set(b.split(separator: " "))
        if setA.isEmpty || setB.isEmpty { return 0.0 }
        let inter = setA.intersection(setB).count
        let uni = setA.union(setB).count
        return Double(inter) / Double(uni)
    }

    private func sanitizeQuestion(_ input: String) -> String {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let newline = text.firstIndex(of: "\n") {
            text = String(text[..<newline])
        }
        if (text.hasPrefix("\"") && text.hasSuffix("\"")) || (text.hasPrefix("'") && text.hasSuffix("'")) {
            text = String(text.dropFirst().dropLast())
        }
        return text
    }
    
    // MARK: - Presentation Support
    func generatePresentationContent(prompt: String) async throws -> String {
        // Check if we need to search for current information
        let searchKeywords = ["current", "latest", "recent", "today", "2024", "2025", "news", "statistics", "data", "trends", "market", "research", "study", "report", "update"]
        let lowercasePrompt = prompt.lowercased()
        let needsSearch = searchKeywords.contains { lowercasePrompt.contains($0) }
        
        var enhancedPrompt = prompt
        
        if needsSearch {
            enhancedPrompt += "\n\nNote: You are equipped with current information browsing capabilities. \(getCurrentDateContext()). Please search for and include the most up-to-date information, statistics, and recent developments relevant to this presentation topic. Make sure to incorporate current data from \(Date().formatted(.dateTime.year())) and the latest research findings and trends."
        }
        
        let openAIMessage = OpenAIMessage(
            role: "user",
            content: [OpenAIMessage.Content(type: "text", text: enhancedPrompt, image_url: nil)]
        )
        
        let request = OpenAIRequest(
            model: "gpt-4o",
            messages: [openAIMessage],
            max_tokens: 4000,
            temperature: 0.1
        )
        
        return try await sendRequest(request)
    }
}

// Content analysis structures for smart formatting
private struct ContentAnalysis {
    let shouldUseLists: Bool
    let shouldUseTables: Bool
    let shouldUseCodeBlocks: Bool
    let shouldUseDetailedExplanation: Bool
    let complexity: ContentComplexity
}

private enum ContentComplexity {
    case simple
    case moderate
    case complex
}


