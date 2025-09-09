//
//  AnthropicService.swift
//  UsefulMacApp
//
//  Provides Claude 3.5 Haiku chat (non-browsing) with optional streaming.
//

import Foundation

struct AnthropicMessageContent: Codable {
    let type: String
    let text: String
}

struct AnthropicMessage: Codable {
    let role: String
    let content: [AnthropicMessageContent]
}

struct AnthropicRequest: Codable {
    let model: String
    let max_tokens: Int
    let system: String?
    let messages: [AnthropicMessage]
    let stream: Bool?
}

final class AnthropicService {
    static let shared = AnthropicService()
    private init() {}

    private let baseURL = "\(AppConfig.workerBaseURL)/anthropic/v1/messages"
    private let model = "claude-3-5-haiku-20241022"
    private var appToken: String { AppConfig.appToken }

    func generate(messages: [(role: String, text: String)], system: String? = nil, maxTokens: Int = 6000) async throws -> String {
        guard let url = URL(string: baseURL) else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(appToken)", forHTTPHeaderField: "Authorization")
        
        // Only send app token - no user auth needed for simplified worker

        let msgs = messages.map { AnthropicMessage(role: $0.role, content: [AnthropicMessageContent(type: "text", text: $0.text)]) }
        let payload = AnthropicRequest(model: model, max_tokens: min(maxTokens, 8192), system: system, messages: msgs, stream: nil)
        req.httpBody = try JSONEncoder().encode(payload)

        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            let msg = String(data: data, encoding: .utf8) ?? "Server error"
            throw NSError(domain: "Anthropic", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: msg])
        }
        // Parse Anthropic JSON: { content: [{type:"text", text:"..."}, ...] }
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let content = obj["content"] as? [[String: Any]] {
            var out = ""
            for block in content {
                if let type = block["type"] as? String, type == "text", let text = block["text"] as? String {
                    out += text
                }
            }
            if !out.isEmpty { return out }
        }
        // Fallback to raw body
        return String(data: data, encoding: .utf8) ?? ""
    }

    // SSE streaming. Emits growing text deltas by reading content_block_delta events.
    func streamGenerate(messages: [(role: String, text: String)], system: String? = nil, maxTokens: Int = 6000, onDelta: @escaping (String) -> Void) async throws {
        guard let url = URL(string: baseURL) else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(appToken)", forHTTPHeaderField: "Authorization")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        
        // Only send app token - no user auth needed for simplified worker

        let msgs = messages.map { AnthropicMessage(role: $0.role, content: [AnthropicMessageContent(type: "text", text: $0.text)]) }
        let payload = AnthropicRequest(model: model, max_tokens: min(maxTokens, 8192), system: system, messages: msgs, stream: true)
        req.httpBody = try JSONEncoder().encode(payload)

        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            // Try fetch error body
            let (edata, _) = try await URLSession.shared.data(for: req)
            let msg = String(data: edata, encoding: .utf8) ?? "Server error"
            throw NSError(domain: "Anthropic", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: msg])
        }

        var pendingBuffer = ""
        let maxChunk = 80 // characters per UI update for smooth typing
        let minDelayNs: UInt64 = 18_000_00 // ~18ms between flushes
        var lastFlush = DispatchTime.now()

        for try await line in bytes.lines {
            if !line.hasPrefix("data:") { continue }
            let dataPart = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if dataPart.isEmpty { continue }
            if dataPart == "[DONE]" { break }
            guard let jsonData = dataPart.data(using: .utf8) else { continue }
            if let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                // Anthropic streaming types: message_start, content_block_start, content_block_delta, content_block_stop, message_delta, message_stop
                if let type = obj["type"] as? String, type == "content_block_delta",
                   let delta = obj["delta"] as? [String: Any],
                   let text = delta["text"] as? String, !text.isEmpty {
                    pendingBuffer += text
                    // Flush in controlled chunks
                    while pendingBuffer.count >= maxChunk {
                        let chunk = String(pendingBuffer.prefix(maxChunk))
                        pendingBuffer.removeFirst(chunk.count)
                        await MainActor.run { onDelta(chunk) }
                        try? await Task.sleep(nanoseconds: minDelayNs)
                        lastFlush = DispatchTime.now()
                    }
                    // Time-based flush for remaining small buffer
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
        }
        if !pendingBuffer.isEmpty {
            await MainActor.run { onDelta(pendingBuffer) }
        }
    }
}


