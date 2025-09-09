//
//  GeminiService.swift
//  UsefulMacApp
//
//  Provides Gemini 2.5 Flash chat with optional Google Search grounding and citations.
//

import Foundation
import PDFKit

struct GeminiInlineData: Codable { let mime_type: String; let data: String }
struct GeminiMessagePart: Codable {
    let text: String?
    let inline_data: GeminiInlineData?
    init(text: String) { self.text = text; self.inline_data = nil }
    init(inline_data: GeminiInlineData) { self.text = nil; self.inline_data = inline_data }
}
struct GeminiContent: Codable { let role: String; let parts: [GeminiMessagePart] }

struct GeminiTool: Codable { let google_search: [String: String] = [:] }

struct GeminiRequest: Codable {
    let contents: [GeminiContent]
    let tools: [GeminiTool]?
    let system_instruction: GeminiSystemInstruction?
}

struct GeminiSystemInstruction: Codable { let parts: [GeminiMessagePart] }

struct GeminiResponse: Codable {
    struct Candidate: Codable {
        struct Content: Codable { let parts: [GeminiMessagePart]? }
        let content: Content?
    }
    let candidates: [Candidate]?
}

final class GeminiService {
    static let shared = GeminiService()
    private init() {}
    
    private let baseURL = "\(AppConfig.workerBaseURL)/gemini/v1beta"
    private let model = "gemini-2.5-flash"
    private var appToken: String { AppConfig.appToken }
    private let knowledgeCutoff = "October 2024"
    
    private func currentDateContext() -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "EEEE, MMMM d, yyyy"
        return "Today is \(df.string(from: Date()))."
    }
    
    func generate(query: String, sources: [ResearchBundle.Source]? = nil, enableWeb: Bool = true) async throws -> String {
        return try await generateWithHistory(history: [], query: query, sources: sources, enableWeb: enableWeb)
    }
    
    // New method that accepts chat history for proper conversation context
    func generateWithHistory(history: [(role: String, content: String)], query: String, sources: [ResearchBundle.Source]? = nil, enableWeb: Bool = true) async throws -> String {
        print("🔵 Gemini generateWithHistory called with query: \(query.prefix(50))...")
        guard let url = URL(string: "\(baseURL)/models/\(model):generateContent") else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(appToken)", forHTTPHeaderField: "Authorization")
        
        // Only send app token - no user auth needed for simplified worker
        req.timeoutInterval = 20
        
        var systemHint: String
        if enableWeb {
            systemHint = """
\(currentDateContext()) Web mode.
Write a clear, reasonably thorough answer (2–5 short paragraphs or concise bullets).
Cite sources inline using numeric references like [1], [2] next to claims grounded in the web.
End with a Sources section listing the full URLs you used.
Prefer recent, credible sources; avoid unrelated links.
"""
        } else {
            systemHint = "\(currentDateContext()) Knowledge cutoff: \(knowledgeCutoff). Be brief and accurate. Do not browse or cite live web. If the query likely needs current facts or post-cutoff events, say you may be outdated and suggest turning on Internet Mode."
        }
        if let sources = sources, !sources.isEmpty {
            var lines: [String] = ["Sources:"]
            for (idx, s) in sources.prefix(5).enumerated() {
                lines.append("[\(idx+1)] \(s.title) — \(s.url)")
            }
            systemHint += "\n\n" + lines.joined(separator: "\n")
        }
        let sys = GeminiSystemInstruction(parts: [GeminiMessagePart(text: systemHint)])
        
        // Build conversation history + current query
        var contents: [GeminiContent] = []
        
        // Add history messages (limit to last 20 for token efficiency)
        for message in history.suffix(20) {
            let geminiRole = message.role == "user" ? "user" : "model"
            contents.append(GeminiContent(role: geminiRole, parts: [GeminiMessagePart(text: message.content)]))
        }
        
        // Add current user query
        contents.append(GeminiContent(role: "user", parts: [GeminiMessagePart(text: query)]))
        
        let payload = GeminiRequest(contents: contents, tools: enableWeb ? [GeminiTool()] : nil, system_instruction: sys)
        req.httpBody = try JSONEncoder().encode(payload)
        
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            let msg = String(data: data, encoding: .utf8) ?? "Server error"
            print("🔴 Gemini Error: Status \(http.statusCode), Response: \(msg)")
            print("🌐 Request URL: \(req.url?.absoluteString ?? "unknown")")
            throw NSError(domain: "Gemini", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: msg])
        }
        let parsed = try JSONDecoder().decode(GeminiResponse.self, from: data)
        let text = parsed.candidates?.first?.content?.parts?.first?.text ?? ""
        print("🟢 Gemini Success: Received \(text.count) characters")
        if text.isEmpty {
            print("⚠️ Gemini returned empty text. Full response: \(String(data: data, encoding: .utf8) ?? "Unable to decode")")
        }
        return text
    }

    // Send multiple images with an optional prompt. If prompt is empty, instruct Gemini to infer the likely user request from the visuals and answer directly.
    func sendImagesWithOptionalPrompt(imagesData: [Data], prompt: String?) async throws -> String {
        guard !imagesData.isEmpty else { return "" }
        guard let url = URL(string: "\(baseURL)/models/\(model):generateContent") else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(appToken)", forHTTPHeaderField: "Authorization")
        
        // Only send app token - no user auth needed for simplified worker
        req.timeoutInterval = 30

        let defaultInstruction = "Analyze the image(s) and provide the answer the user is most likely asking for based on the visual content. If the images depict a question, form, chart, or problem, extract the likely question and answer it directly. Return plain text only."
        let trimmed = (prompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let effectivePrompt = trimmed.isEmpty ? defaultInstruction : "\(trimmed)\n\n\(defaultInstruction)"

        var parts: [GeminiMessagePart] = [GeminiMessagePart(text: effectivePrompt)]
        for data in imagesData {
            let b64 = data.base64EncodedString()
            parts.append(GeminiMessagePart(inline_data: GeminiInlineData(mime_type: "image/png", data: b64)))
        }

        let systemHint = "\(currentDateContext()) Be concise and accurate. Return plain text only."
        let payload = GeminiRequest(
            contents: [GeminiContent(role: "user", parts: parts)],
            tools: nil,
            system_instruction: GeminiSystemInstruction(parts: [GeminiMessagePart(text: systemHint)])
        )
        req.httpBody = try JSONEncoder().encode(payload)

        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            let msg = String(data: data, encoding: .utf8) ?? "Server error"
            print("🔴 Gemini Error: Status \(http.statusCode), Response: \(msg)")
            print("🌐 Request URL: \(req.url?.absoluteString ?? "unknown")")
            throw NSError(domain: "Gemini", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: msg])
        }
        let parsed = try JSONDecoder().decode(GeminiResponse.self, from: data)
        let text = parsed.candidates?.first?.content?.parts?.first?.text ?? ""
        print("🟢 Gemini Success: Received \(text.count) characters")
        if text.isEmpty {
            print("⚠️ Gemini returned empty text. Full response: \(String(data: data, encoding: .utf8) ?? "Unable to decode")")
        }
        return text
    }
    
    // Streaming generation via SSE. Emits textual deltas in small chunks for typing effect with low UI overhead.
    func streamGenerate(query: String, sources: [ResearchBundle.Source]? = nil, enableWeb: Bool = true, onDelta: @escaping (String) -> Void) async throws {
        try await streamGenerateWithHistory(history: [], query: query, sources: sources, enableWeb: enableWeb, onDelta: onDelta)
    }
    
    // New streaming method that accepts chat history for proper conversation context
    func streamGenerateWithHistory(history: [(role: String, content: String)], query: String, sources: [ResearchBundle.Source]? = nil, enableWeb: Bool = true, onDelta: @escaping (String) -> Void) async throws {
        print("🟣 Gemini streamGenerateWithHistory called with query: \(query.prefix(50))...")
        var urlString = "\(baseURL)/models/\(model):streamGenerateContent?alt=sse"
        print("🌐 Gemini URL: \(urlString)")
        guard let url = URL(string: urlString) else { 
            print("❌ Gemini URL creation failed: \(urlString)")
            throw URLError(.badURL) 
        }
        
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(appToken)", forHTTPHeaderField: "Authorization")
        
        // Only send app token - no user auth needed for simplified worker
        req.timeoutInterval = 45
        print("📡 About to make Gemini streaming request...")
        
        var systemHint: String
        if enableWeb {
            systemHint = """
\(currentDateContext()) Web mode.
Provide a well-structured answer with brief paragraphs and bullets as needed.
Use inline numeric citations [1], [2] for web-grounded facts and finish with a Sources list (full URLs).
Favor recent, credible sources.
"""
        } else {
            systemHint = "\(currentDateContext()) Knowledge cutoff: \(knowledgeCutoff). Be brief and accurate. Do not browse or cite live web. If the query likely needs current facts or post-cutoff events, say you may be outdated and suggest turning on Internet Mode."
        }
        if let sources = sources, !sources.isEmpty {
            var lines: [String] = ["Sources:"]
            for (idx, s) in sources.prefix(5).enumerated() {
                lines.append("[\(idx+1)] \(s.title) — \(s.url)")
            }
            systemHint += "\n\n" + lines.joined(separator: "\n")
        }
        let sys = GeminiSystemInstruction(parts: [GeminiMessagePart(text: systemHint)])
        
        // Build conversation history + current query
        var contents: [GeminiContent] = []
        
        // Add history messages (limit to last 20 for token efficiency)
        for message in history.suffix(20) {
            let geminiRole = message.role == "user" ? "user" : "model"
            contents.append(GeminiContent(role: geminiRole, parts: [GeminiMessagePart(text: message.content)]))
        }
        
        // Add current user query
        contents.append(GeminiContent(role: "user", parts: [GeminiMessagePart(text: query)]))
        
        let payload = GeminiRequest(contents: contents, tools: enableWeb ? [GeminiTool()] : nil, system_instruction: sys)
        req.httpBody = try JSONEncoder().encode(payload)
        
        do {
            let (bytes, resp) = try await URLSession.shared.bytes(for: req)
            print("✅ Gemini streaming request started successfully")
            if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                let (data, _) = try await URLSession.shared.data(for: req)
                let msg = String(data: data, encoding: .utf8) ?? "Server error"
                print("🔴 Gemini Streaming Error: Status \(http.statusCode), Response: \(msg)")
                print("🌐 Request URL: \(req.url?.absoluteString ?? "unknown")")
                throw NSError(domain: "Gemini", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: msg])
            }
        var accumulated = ""
        var pendingBuffer = ""
        let maxChunk = 80 // characters per UI update
        let minDelayNs: UInt64 = 18_000_000 // ~18ms between flushes
        var lastFlush = DispatchTime.now()
        
        print("🔄 Starting to read Gemini streaming lines...")
        var lineCount = 0
        var fullResponse = ""
        
        for try await line in bytes.lines {
            lineCount += 1
            if lineCount <= 5 {
                print("📝 Raw line \(lineCount): \(line.prefix(100))...")
            }
            
            // Handle SSE format (data: prefix)
            if line.hasPrefix("data:") {
                let dataPart = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if dataPart == "[DONE]" { break }
                guard let jsonData = dataPart.data(using: .utf8) else { 
                    print("⚠️ Failed to convert SSE data to UTF8: \(dataPart.prefix(100))")
                    continue 
                }
                // Process SSE JSON chunk
                if let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                    if lineCount <= 3 {
                        print("📊 SSE JSON object: \(obj)")
                    }
                    // Extract and process text from SSE chunk
                    if let candidates = obj["candidates"] as? [[String: Any]],
                       let content = candidates.first?["content"] as? [String: Any],
                       let parts = content["parts"] as? [[String: Any]] {
                        let full = parts.compactMap { $0["text"] as? String }.joined()
                        if !full.isEmpty {
                            await processGeminiStreamingText(full: full, accumulated: &accumulated, pendingBuffer: &pendingBuffer, maxChunk: maxChunk, minDelayNs: minDelayNs, lastFlush: &lastFlush, onDelta: onDelta)
                        }
                    }
                }
            } else {
                // Handle regular JSON response (accumulate all lines)
                fullResponse += line
            }
        }
        
        // If we accumulated a full JSON response (not SSE), process it at the end
        if !fullResponse.isEmpty {
            print("📄 Processing complete JSON response...")
            print("🔍 Raw JSON (first 200 chars): \(fullResponse.prefix(200))...")
            
            if let jsonData = fullResponse.data(using: .utf8) {
                do {
                    let jsonObject = try JSONSerialization.jsonObject(with: jsonData)
                    print("📊 Complete JSON parsed successfully")
                    
                    // Handle both array format and object format by collecting all parts text
                    var collectedText = ""
                    if let array = jsonObject as? [[String: Any]] {
                        print("🔄 Detected array format, concatenating items")
                        for item in array {
                            if let candidates = item["candidates"] as? [[String: Any]],
                               let content = candidates.first?["content"] as? [String: Any],
                               let parts = content["parts"] as? [[String: Any]] {
                                let t = parts.compactMap { $0["text"] as? String }.joined()
                                collectedText += t
                            }
                        }
                    } else if let dictionary = jsonObject as? [String: Any] {
                        print("🔄 Detected object format")
                        if let candidates = dictionary["candidates"] as? [[String: Any]],
                           let content = candidates.first?["content"] as? [String: Any],
                           let parts = content["parts"] as? [[String: Any]] {
                            collectedText = parts.compactMap { $0["text"] as? String }.joined()
                        }
                    }
                    if !collectedText.isEmpty {
                        print("✅ Found complete text: \(collectedText.prefix(50))...")
                        await sendTextAsStreamingChunks(text: collectedText, onDelta: onDelta)
                    } else {
                        print("❌ Failed to extract text from complete JSON response")
                        print("🔍 Raw response: \(fullResponse.prefix(400))...")
                    }
                } catch {
                    print("❌ JSON parsing error: \(error)")
                    print("🔍 Raw response: \(fullResponse)")
                }
            } else {
                print("❌ Failed to convert response to UTF8 data")
            }
        }
        
        if !pendingBuffer.isEmpty {
            print("🏁 Sending final delta: \(pendingBuffer.prefix(30))...")
            await MainActor.run { onDelta(pendingBuffer) }
        }
        print("✅ Gemini streaming completed")
        } catch {
            print("🔴 Gemini streaming error: \(error)")
            throw error
        }
    }

    // Send PDFs with an optional prompt - extract text content and send to Gemini
    func sendPDFsWithOptionalPrompt(pdfURLs: [URL], prompt: String?) async throws -> String {
        guard !pdfURLs.isEmpty else { return "" }
        guard let url = URL(string: "\(baseURL)/models/\(model):generateContent") else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(appToken)", forHTTPHeaderField: "Authorization")
        
        // Only send app token - no user auth needed for simplified worker
        req.timeoutInterval = 30

        let defaultInstruction = "Analyze the PDF document(s) and provide a helpful response based on the content. If the user asks a question, answer it directly. If no specific question is asked, provide a useful summary."
        let trimmed = (prompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let effectivePrompt = trimmed.isEmpty ? defaultInstruction : "\(trimmed)\n\n\(defaultInstruction)"

        // Extract text from PDFs
        var extractedTexts: [String] = []
        for pdfURL in pdfURLs {
            if let pdfText = extractTextFromPDF(at: pdfURL) {
                extractedTexts.append("PDF: \(pdfURL.lastPathComponent)\n\n\(pdfText)")
            }
        }
        
        guard !extractedTexts.isEmpty else {
            throw NSError(domain: "GeminiService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Could not extract text from PDF files"])
        }

        let combinedText = "\(effectivePrompt)\n\nPDF Content:\n\n\(extractedTexts.joined(separator: "\n\n---\n\n"))"
        let parts: [GeminiMessagePart] = [GeminiMessagePart(text: combinedText)]

        let systemHint = "\(currentDateContext()) Be concise and accurate. You are analyzing PDF documents. Return plain text only."
        let payload = GeminiRequest(
            contents: [GeminiContent(role: "user", parts: parts)],
            tools: nil,
            system_instruction: GeminiSystemInstruction(parts: [GeminiMessagePart(text: systemHint)])
        )
        req.httpBody = try JSONEncoder().encode(payload)

        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            let msg = String(data: data, encoding: .utf8) ?? "Server error"
            print("🔴 Gemini Error: Status \(http.statusCode), Response: \(msg)")
            print("🌐 Request URL: \(req.url?.absoluteString ?? "unknown")")
            throw NSError(domain: "Gemini", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: msg])
        }
        let parsed = try JSONDecoder().decode(GeminiResponse.self, from: data)
        let text = parsed.candidates?.first?.content?.parts?.first?.text ?? ""
        print("🟢 Gemini Success: Received \(text.count) characters")
        if text.isEmpty {
            print("⚠️ Gemini returned empty text. Full response: \(String(data: data, encoding: .utf8) ?? "Unable to decode")")
        }
        return text
    }
    
    // Extract text content from PDF using PDFKit
    private func extractTextFromPDF(at url: URL) -> String? {
        guard let pdfDocument = PDFDocument(url: url) else { return nil }
        
        var extractedText = ""
        let pageCount = pdfDocument.pageCount
        
        // Limit to first 50 pages to avoid extremely long content
        let maxPages = min(pageCount, 50)
        
        for pageIndex in 0..<maxPages {
            if let page = pdfDocument.page(at: pageIndex) {
                if let pageText = page.string {
                    extractedText += pageText + "\n"
                }
            }
        }
        
        // Trim and return the extracted text
        return extractedText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    // Fetch 2–3 high-quality, recent sources (JSON-only contract)
    func searchSources(query: String, maxResults: Int = 3) async throws -> [ResearchBundle.Source] {
        guard let url = URL(string: "\(baseURL)/models/\(model):generateContent") else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(appToken)", forHTTPHeaderField: "Authorization")
        
        // Only send app token - no user auth needed for simplified worker
        req.timeoutInterval = 20
        
        let sysText = "\(currentDateContext()) Return ONLY JSON array: [{\"title\": string, \"url\": string, \"snippet\": string}]. Pick \(maxResults) recent, credible results for: \"\(query)\". Prefer the last 14 days."
        let sys = GeminiSystemInstruction(parts: [GeminiMessagePart(text: sysText)])
        let userContent = GeminiContent(role: "user", parts: [GeminiMessagePart(text: query)])
        let payload = GeminiRequest(contents: [userContent], tools: [GeminiTool()], system_instruction: sys)
        req.httpBody = try JSONEncoder().encode(payload)
        
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            let msg = String(data: data, encoding: .utf8) ?? "Server error"
            print("🔴 Gemini Error: Status \(http.statusCode), Response: \(msg)")
            print("🌐 Request URL: \(req.url?.absoluteString ?? "unknown")")
            throw NSError(domain: "Gemini", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: msg])
        }
        let parsed = try JSONDecoder().decode(GeminiResponse.self, from: data)
        let text = parsed.candidates?.first?.content?.parts?.first?.text ?? "[]"
        let json = extractFirstJSONArray(from: text) ?? text
        guard let jdata = json.data(using: .utf8) else { return [] }
        struct Item: Codable { let title: String; let url: String; let snippet: String? }
        if let arr = try? JSONDecoder().decode([Item].self, from: jdata) {
            var seen: Set<String> = []
            var out: [ResearchBundle.Source] = []
            for it in arr {
                guard let u = URL(string: it.url) else { continue }
                let host = u.host?.lowercased() ?? it.url
                if seen.contains(host) { continue }
                seen.insert(host)
                out.append(ResearchBundle.Source(title: it.title, url: u.absoluteString, snippet: (it.snippet ?? "").trimmingCharacters(in: .whitespacesAndNewlines), publishedAt: nil, site: u.host))
                if out.count >= maxResults { break }
            }
            return out
        }
        return []
    }
    
    private func extractFirstJSONArray(from input: String) -> String? {
        guard let start = input.firstIndex(of: "[") else { return nil }
        var depth = 0
        for idx in input[start...].indices {
            let ch = input[idx]
            if ch == "[" { depth += 1 }
            if ch == "]" {
                depth -= 1
                if depth == 0 {
                    let end = input.index(after: idx)
                    return String(input[start..<end])
                }
            }
        }
        return nil
    }
    
    // Helper function to simulate streaming from complete text
    private func sendTextAsStreamingChunks(text: String, onDelta: @escaping (String) -> Void) async {
        let chunkSize = 8 // Characters per chunk (increased for smoother typing)
        let delayNs: UInt64 = 30_000_000 // 30ms delay between chunks (faster for smoother feel)
        
        var currentIndex = text.startIndex
        while currentIndex < text.endIndex {
            let endIndex = text.index(currentIndex, offsetBy: chunkSize, limitedBy: text.endIndex) ?? text.endIndex
            let chunk = String(text[currentIndex..<endIndex])
            
            print("🚀 Sending simulated streaming chunk: \(chunk)")
            await MainActor.run { onDelta(chunk) }
            
            currentIndex = endIndex
            if currentIndex < text.endIndex {
                try? await Task.sleep(nanoseconds: delayNs)
            }
        }
    }
    
    // Helper function to process streaming text (for SSE format)
    private func processGeminiStreamingText(
        full: String,
        accumulated: inout String,
        pendingBuffer: inout String,
        maxChunk: Int,
        minDelayNs: UInt64,
        lastFlush: inout DispatchTime,
        onDelta: @escaping (String) -> Void
    ) async {
        // Compute incremental suffix
        if full.count > accumulated.count, full.hasPrefix(accumulated) {
            let suffix = String(full.dropFirst(accumulated.count))
            accumulated = full
            pendingBuffer += suffix
        } else if !full.isEmpty && full != accumulated {
            let suffix = full
            accumulated = full
            pendingBuffer += suffix
        }
        
        // Flush in controlled chunks
        while pendingBuffer.count >= maxChunk {
            let chunk = String(pendingBuffer.prefix(maxChunk))
            pendingBuffer.removeFirst(chunk.count)
            print("🚀 Sending delta chunk: \(chunk.prefix(30))...")
            await MainActor.run { onDelta(chunk) }
            try? await Task.sleep(nanoseconds: minDelayNs)
            lastFlush = DispatchTime.now()
        }
        
        // Time-based flush for remaining small buffer
        let elapsed = DispatchTime.now().uptimeNanoseconds - lastFlush.uptimeNanoseconds
        if !pendingBuffer.isEmpty && elapsed >= minDelayNs {
            let chunk = pendingBuffer
            pendingBuffer = ""
            print("⏰ Sending time-based delta: \(chunk.prefix(30))...")
            await MainActor.run { onDelta(chunk) }
            try? await Task.sleep(nanoseconds: minDelayNs)
            lastFlush = DispatchTime.now()
        }
    }
}
