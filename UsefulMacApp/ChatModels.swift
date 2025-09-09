//
//  ChatModels.swift
//  UsefulMacApp
//
//  Created by Aarav Kapur on 8/20/25.
//

import Foundation
import AppKit
import Combine

enum AIModel: String, CaseIterable {
    case gpt4o = "gpt-4o"
    case gpt5Mini = "gpt-5-mini"
    case geminiFlash = "gemini-2.5-flash"
    case claudeHaiku = "claude-3-5-haiku-20241022"
    // gpt5 removed from UI - now used internally for research
    
    var displayName: String {
        switch self {
        case .gpt4o:
            return "GPT-4o"
        case .gpt5Mini:
            return "GPT-5"
        case .geminiFlash:
            return "Gemini 2.5"
        case .claudeHaiku:
            return "Claude 3.5"
        }
    }
    
    var icon: String {
        switch self {
        case .gpt4o:
            return "brain.head.profile"
        case .gpt5Mini:
            return "sparkles"
        case .geminiFlash:
            return "bolt.horizontal"
        case .claudeHaiku:
            return "quote.bubble"
        }
    }
}

// Internal enum for actual API models (includes GPT-5 for research)
enum InternalAIModel: String {
    case gpt4o = "gpt-4o-mini"
    case gpt5Mini = "gpt-5-mini"
    case gpt5 = "gpt-5"
}

struct ChatMessage: Identifiable, Equatable, Codable {
    let id: UUID
    var content: String
    let isUser: Bool
    let timestamp: Date
    var attachmentData: Data?
    var attachmentDatas: [Data]?
    var attachmentPDFs: [URL]?

    init(content: String, isUser: Bool, id: UUID = UUID(), timestamp: Date = Date(), attachmentData: Data? = nil, attachmentDatas: [Data]? = nil, attachmentPDFs: [URL]? = nil) {
        self.id = id
        self.content = content
        self.isUser = isUser
        self.timestamp = timestamp
        self.attachmentData = attachmentData
        self.attachmentDatas = attachmentDatas
        self.attachmentPDFs = attachmentPDFs
    }
}

@MainActor
class ChatViewModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var currentMessage = ""
    @Published var isLoading = false
    @Published var isAutoResearching = false
    @Published var contextSummary: String = ""
    @Published var followUpsForLastAssistant: [String] = []
    @Published var selectedModel: AIModel = .gpt4o
    @Published var forceInternet: Bool = false
    // If set, a newly sent message (and its reply) will be inserted directly after this anchor message id
    @Published var editAnchorMessageId: UUID? = nil
    
    // Streaming buffer to handle markdown gracefully
    private var streamingBuffer = ""
    private var isInCodeBlock = false
    private var codeBlockDelimiterCount = 0
    private var lastStreamUIUpdate: CFAbsoluteTime = 0
    // Smooth typing: queue incoming chars and drain them at a steady cadence
    private var pendingStreamChars: [Character] = []
    private var streamDrainTask: Task<Void, Never>? = nil
    
    private let openAIService = OpenAIService()
    private var cancellables: Set<AnyCancellable> = []
    
    
    init() {
        // Add welcome message
        messages.append(ChatMessage(content: "Hello! I'm your AI assistant. You can chat with me here, or use shortcuts anywhere on your Mac to have me help directly with whatever you're working on! Here are some Popular Shortcuts:\n\nCommand + Shift + U - Full Screen Helper Panel\nCommand + Shift + L - Lasso Tool\nCommand + Shift + E - Directly edit highlighted text", isUser: false))
        // Load last selected model from preferences
        selectedModel = ModelPreferences.load()
        observeModelSelection()
    }

    /// Initialize with an existing message history (used for persistence restore)
    init(messages: [ChatMessage]) {
        if messages.isEmpty {
            self.messages = [ChatMessage(content: "Hello! I'm your AI assistant. You can chat with me here, or use shortcuts anywhere on your Mac to have me help directly with whatever you're working on! Here are some Popular Shortcuts:\n\nCommand + Shift + U - Full Screen Helper Panel\nCommand + Shift + L - Lasso Tool\nCommand + Shift + E - Directly edit highlighted text", isUser: false)]
        } else {
            self.messages = messages
        }
        // Load last selected model from preferences
        selectedModel = ModelPreferences.load()
        observeModelSelection()
    }

    private func observeModelSelection() {
        $selectedModel
            .removeDuplicates()
            .sink { model in
                ModelPreferences.save(model)
            }
            .store(in: &cancellables)
    }
    
    func sendMessage() {
        guard !currentMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // Tier-based daily limits
        let auth = AuthenticationManager.shared
        if auth.currentUserTier == .free {
            let userId = auth.currentUser?.uid
            if !FreeUsageLimiter.shared.recordSendIfAllowed(userId: userId) {
                let cta = "You have reached your daily limit on the free plan. Try Pro for free today https://blinkapp.ai/pricing"
                messages.append(ChatMessage(content: cta, isUser: false))
                return
            }
        } else if auth.currentUserTier == .pro {
            // Pro: 50 total chat messages/day across all models
            let userId = auth.currentUser?.uid
            let ok = FreeUsageLimiter.shared.recordIfAllowed(userId: userId, feature: "chat_pro", limit: 50)
            if !ok {
                messages.append(ChatMessage(content: "You have reached the daily limit for the Pro plan. Upgrade to Pro Unlimited https://blinkapp.ai/pricing", isUser: false))
                return
            }
        }
        // Determine if we are editing an earlier message. If so, remove that message and all that follow, then append the edited message.
        let anchorId = editAnchorMessageId
        let anchorIndex: Int? = anchorId.flatMap { id in messages.firstIndex(where: { $0.id == id }) }
        if let idx = anchorIndex {
            // Truncate everything from the original message onward (drop the original too)
            messages = Array(messages.prefix(idx))
        }
        let userMessage = ChatMessage(content: currentMessage, isUser: true)
        messages.append(userMessage)
        // Hide previous suggestions immediately; they'll reappear after the next response finalizes
        followUpsForLastAssistant = []
        
        let messageToSend = currentMessage
        currentMessage = ""
        // Clear anchor so subsequent sends go to the end unless user chooses edit again
        editAnchorMessageId = nil
        isLoading = true
        
        // Check if there are PDFs in conversation history - if so, use Gemini for follow-up
        let hasPDFsInHistory = messages.contains { $0.attachmentPDFs != nil && !$0.attachmentPDFs!.isEmpty }
        if hasPDFsInHistory && selectedModel == .geminiFlash {
            Task {
                do {
                    // Use Gemini with PDF context for follow-up questions
                    let responseText = try await sendFollowUpWithPDFContext(messageToSend)
                    await MainActor.run {
                        messages.append(ChatMessage(content: responseText, isUser: false))
                        isLoading = false
                    }
                } catch {
                    await MainActor.run {
                        messages.append(ChatMessage(content: "Sorry, I encountered an error: \(error.localizedDescription)", isUser: false))
                        isLoading = false
                    }
                }
            }
            return
        }
        
        // Capture internet toggle state (will reset after response completion)
        let shouldForceInternet = forceInternet

        Task {
            do {
                // Slight temperature jitter for a more natural, less templated feel
                let baseTemp = 0.65
                let temperature = min(0.8, max(0.5, baseTemp + Double.random(in: -0.05...0.10)))
                // True streaming
                var appendedId: UUID?
                if selectedModel == .geminiFlash {
                    await MainActor.run { self.isAutoResearching = shouldForceInternet }
                }
                // Prepare forced research signal (no prefetch) so the model uses its own web tool
                var forcedResearch: ResearchBundle? = nil
                if shouldForceInternet {
                    await MainActor.run { self.isAutoResearching = true }
                    let isoNow = ISO8601DateFormatter().string(from: Date())
                    forcedResearch = ResearchBundle(query: messageToSend, fetchedAt: isoNow, sources: [], notes: nil)
                }

                try await openAIService.streamChatWithHistory(
                    history: messages,
                    userText: messageToSend,
                    research: forcedResearch,
                    contextSummary: contextSummary.isEmpty ? nil : contextSummary,
                    temperature: temperature,
                    maxTokens: 12000,
                    // Disable auto web detection entirely unless forced
                    autoResearch: false,
                    model: selectedModel,
                    onAutoResearchStart: { [weak self] in
                        self?.isAutoResearching = true
                    },
                    onDelta: { [weak self] delta in
                        guard let self = self else { return }
                        print("🟩 ChatViewModel received delta: '\(delta)' (length: \(delta.count))")
                        if appendedId == nil {
                            let id = UUID()
                            appendedId = id
                            print("🟩 ChatViewModel: Starting new message with ID \(id)")
                            // Reset streaming state for new message
                            self.streamDrainTask?.cancel()
                            self.streamDrainTask = nil
                            self.pendingStreamChars.removeAll(keepingCapacity: false)
                            self.streamingBuffer = ""
                            // Seed buffers with first delta
                            self.streamingBuffer += delta
                            self.pendingStreamChars.append(contentsOf: Array(delta))
                            print("🟩 ChatViewModel: Buffer seeded, streamingBuffer=\(self.streamingBuffer.count) chars, pendingChars=\(self.pendingStreamChars.count)")
                            // Compute insertion position for assistant directly after the just-inserted user message
                            if let idx = self.messages.firstIndex(where: { $0.id == userMessage.id }) {
                                let insertAt = idx + 1
                                self.messages.insert(ChatMessage(content: "", isUser: false, id: id), at: insertAt)
                            } else {
                                // Fallback to append if we can't find the user message (shouldn't happen)
                                self.messages.append(ChatMessage(content: "", isUser: false, id: id))
                            }
                            self.isLoading = false
                            // Start smooth drainer
                            self.startStreamDrainer(for: id)
                        } else if let id = appendedId, let idx = self.messages.firstIndex(where: { $0.id == id }) {
                            self.streamingBuffer += delta
                            self.pendingStreamChars.append(contentsOf: Array(delta))
                            print("🟩 ChatViewModel: Added to existing message, streamingBuffer=\(self.streamingBuffer.count) chars, pendingChars=\(self.pendingStreamChars.count)")
                            // Ensure drainer is running
                            if self.streamDrainTask == nil { self.startStreamDrainer(for: id) }
                        }
                    },
                    onComplete: { [weak self] in
                        guard let self = self else { return }
                        self.isLoading = false
                        self.isAutoResearching = false
                        // Reset internet toggle after response completion
                        self.forceInternet = false
                        // Finalize streaming content
                        if let lastId = appendedId, let idx = self.messages.firstIndex(where: { $0.id == lastId }) {
                            // Only append a Sources section in GPT when Internet mode is explicitly forced
                            let showSourcesForGPT = (self.selectedModel != .geminiFlash) && shouldForceInternet
                            // Stop drainer and flush any remaining buffered characters
                            self.streamDrainTask?.cancel(); self.streamDrainTask = nil
                            if !self.pendingStreamChars.isEmpty {
                                let tail = String(self.pendingStreamChars)
                                self.pendingStreamChars.removeAll(keepingCapacity: false)
                                print("🟥 OnComplete: Flushing tail '\(tail)' (len=\(tail.count)) - NOT adding to streamingBuffer to avoid duplication")
                                // Note: Don't add tail to streamingBuffer - it already contains all the content
                            }
                            let processedBuffer = showSourcesForGPT ? self.openAIService.sanitizeWebCitationsInResponse(self.streamingBuffer) : self.streamingBuffer
                            // Defer one runloop to avoid SwiftUI race with final streaming update
                            let finalIndex = idx
                            DispatchQueue.main.async {
                                if finalIndex < self.messages.count {
                                    // Ensure the final content matches the processed buffer exactly
                                    // The drainer already built up the content incrementally
                                    let currentContent = self.messages[finalIndex].content
                                    let finalProcessedContent = self.processStreamingContent(processedBuffer)
                                    
                                    print("🟥 OnComplete: currentContent=\(currentContent.count) chars, processedBuffer=\(processedBuffer.count) chars, finalProcessed=\(finalProcessedContent.count) chars")
                                    print("🟥 OnComplete: currentContent='\(currentContent.prefix(100))...'")
                                    print("🟥 OnComplete: finalProcessed='\(finalProcessedContent.prefix(100))...'")
                                    
                                    // Only update if the processed version is different (e.g., due to web citation sanitization)
                                    if currentContent != finalProcessedContent {
                                        print("🟥 OnComplete: Content differs, updating message")
                                        self.messages[finalIndex].content = finalProcessedContent
                                    } else {
                                        print("🟥 OnComplete: Content matches, no update needed")
                                    }
                                }
                            }
                        }
                        // Reset streaming state
                        self.streamingBuffer = ""
                        self.isInCodeBlock = false
                        self.codeBlockDelimiterCount = 0
                        self.lastStreamUIUpdate = 0
                        
                        // Update rolling summary and follow-ups after response finalizes
                        Task { @MainActor in
                            do {
                                self.contextSummary = try await self.openAIService.summarizeConversation(history: self.messages)
                            } catch { /* ignore summary errors */ }
                            // Skip follow-ups for pure greetings/small talk
                            if let lastUser = self.messages.last(where: { $0.isUser })?.content,
                               let lastAssistant = self.messages.last(where: { !$0.isUser })?.content {
                                let lower = lastUser.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                                let isSmallTalk = ["hi","hey","hello","yo","sup","wassup","what's up","what's up","how are you","how's it going","how's it going"].contains(where: { lower.contains($0) }) || lower.count <= 8
                                if !isSmallTalk, let ups = try? await self.openAIService.generateFollowUps(lastUser: lastUser, lastAssistant: lastAssistant) {
                                    self.followUpsForLastAssistant = ups
                                } else {
                                    self.followUpsForLastAssistant = []
                                }
                            }
                        }
                    }
                )
            } catch {
                let errorMessage = ChatMessage(content: "Sorry, I encountered an error: \(error.localizedDescription)", isUser: false)
                messages.append(errorMessage)
                isLoading = false
                isAutoResearching = false
            }
        }
    }
    
    func clearChat() {
        messages.removeAll()
        messages.append(ChatMessage(content: "Hello! I'm your AI assistant. You can chat with me here, or use shortcuts anywhere on your Mac to have me help directly with whatever you're working on! Here are some Popular Shortcuts:\n\nCommand + Shift + U - Full Screen Helper Panel\nCommand + Shift + L - Lasso Tool\nCommand + Shift + E - Directly edit highlighted text", isUser: false))
    }

    func sendImageWithCaption(image: NSImage, caption: String) {
        // Use new multi-image path with a single image for consistency
        sendImagesWithCaption(images: [image], caption: caption)
    }
    
    // Send PDFs with caption - only works with Gemini
    func sendPDFsWithCaption(pdfs: [URL], caption: String) {
        guard !pdfs.isEmpty else { return }
        let trimmed = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = trimmed.isEmpty ? "Please read and analyze the attached PDF document(s). Provide a summary and answer any questions I might have." : trimmed

        isLoading = true
        Task {
            do {
                // Add a user message with PDF references at the correct position (edit anchor aware)
                let pdfNames = pdfs.map { $0.lastPathComponent }.joined(separator: ", ")
                // Respect edit anchor: if present, truncate; then append edited user message
                await MainActor.run {
                    if let anchorId = self.editAnchorMessageId, let idx = messages.firstIndex(where: { $0.id == anchorId }) {
                        messages = Array(messages.prefix(idx))
                    }
                    let user = ChatMessage(content: trimmed.isEmpty ? "📄 Attached: \(pdfNames)" : trimmed, isUser: true, attachmentPDFs: pdfs)
                    messages.append(user)
                    self.editAnchorMessageId = nil
                }

                // Only Gemini supports PDFs
                let responseText = try await GeminiService.shared.sendPDFsWithOptionalPrompt(pdfURLs: pdfs, prompt: prompt)

                await MainActor.run {
                    messages.append(ChatMessage(content: responseText, isUser: false))
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    messages.append(ChatMessage(content: "Sorry, I encountered an error: \(error.localizedDescription)", isUser: false))
                    isLoading = false
                }
            }
        }
    }

    // New: multi-image send with routing to selected model and no-prompt handling
    func sendImagesWithCaption(images: [NSImage], caption: String) {
        guard !images.isEmpty else { return }
        let trimmed = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = "Help the user with what they likely need based on this image. Return plain text only."
        let prompt = trimmed.isEmpty ? base : "\(trimmed)\n\n\(base)"

        isLoading = true
        Task {
            do {
                // Convert images to PNG data off the main thread
                let imageDataArray: [Data] = await Task.detached { images.compactMap { $0.pngData() } }.value
                guard !imageDataArray.isEmpty else {
                    await MainActor.run {
                        messages.append(ChatMessage(content: "Sorry, failed to prepare images for sending.", isUser: false))
                        isLoading = false
                    }
                    return
                }

                // Respect edit anchor: if present, truncate; then append edited user message with all thumbnails
                await MainActor.run {
                    if let anchorId = self.editAnchorMessageId, let idx = messages.firstIndex(where: { $0.id == anchorId }) {
                        messages = Array(messages.prefix(idx))
                    }
                    let user = ChatMessage(content: trimmed, isUser: true, attachmentData: imageDataArray.first, attachmentDatas: imageDataArray)
                    messages.append(user)
                    self.editAnchorMessageId = nil
                }

                // Route based on selected model
                let responseText: String
                switch selectedModel {
                case .geminiFlash:
                    responseText = try await GeminiService.shared.sendImagesWithOptionalPrompt(imagesData: imageDataArray, prompt: prompt)
                default:
                    responseText = try await openAIService.sendImagesWithOptionalPrompt(imagesData: imageDataArray, prompt: prompt, model: selectedModel)
                }

                await MainActor.run {
                    messages.append(ChatMessage(content: responseText, isUser: false))
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    messages.append(ChatMessage(content: "Sorry, I encountered an error: \(error.localizedDescription)", isUser: false))
                    isLoading = false
                }
            }
        }
    }
    
    // Handle follow-up questions when PDFs are in conversation history
    private func sendFollowUpWithPDFContext(_ followUpQuestion: String) async throws -> String {
        // Extract all PDFs from conversation history
        var allPDFs: [URL] = []
        for message in messages {
            if let pdfs = message.attachmentPDFs {
                allPDFs.append(contentsOf: pdfs)
            }
        }
        
        // Build conversation context
        var conversationContext = "Previous conversation:\n"
        for message in messages.suffix(10) { // Include last 10 messages for context
            let role = message.isUser ? "User" : "Assistant"
            let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !content.isEmpty {
                conversationContext += "\(role): \(content)\n"
            }
        }
        
        let prompt = """
        \(conversationContext)
        
        New question: \(followUpQuestion)
        
        Please answer the new question taking into account the previous conversation and the PDF documents that were shared earlier. Reference specific information from the documents when relevant.
        """
        
        return try await GeminiService.shared.sendPDFsWithOptionalPrompt(pdfURLs: allPDFs, prompt: prompt)
    }
    
    // Smart streaming processing to handle markdown gracefully
    private func processStreamingDelta(_ delta: String) -> String {
        return processStreamingContent(delta)
    }
    
    private func processStreamingContent(_ content: String) -> String {
        // Count code block delimiters to track if we're inside a code block
        let delimiterCount = content.components(separatedBy: "```").count - 1
        isInCodeBlock = (delimiterCount % 2) == 1
        
        // If we're in the middle of streaming a code block, don't render it yet
        if content.hasSuffix("``") && !content.hasSuffix("```") {
            // Looks like we're in the middle of typing ```
            return String(content.dropLast(2)) + "..."
        }
        
        // If content ends with incomplete markdown elements, buffer them
        var processedContent = content
        
        // Handle incomplete markdown links [text](
        if content.contains("[") && content.hasSuffix("](") {
            if let lastBracket = content.lastIndex(of: "[") {
                processedContent = String(content[..<lastBracket]) + "[...]"
            }
        }
        
        // Handle incomplete markdown table rows
        if content.hasSuffix("|") && content.components(separatedBy: "\n").last?.contains("|") == true {
            processedContent = content + " ..."
        }
        // Replace inline generic domain citations with numeric [n] where possible.
        // Build mapping from either a Sources block (preferred) or any URLs seen so far in content
        if let mapping = buildHostToIndex(from: processedContent) {
            processedContent = replaceInlineDomains(using: mapping, in: processedContent)
        } else {
            // If we cannot map yet, hide bare-domain parentheses to avoid flashing generic badges
            processedContent = stripInlineDomainParens(in: processedContent)
        }
        
        return processedContent
    }
}

private extension ChatViewModel {
    func startStreamDrainer(for messageId: UUID) {
        // Drain queued characters at a steady cadence; slow down for GPT‑5 to feel more natural
        streamDrainTask?.cancel()
        streamDrainTask = Task { [weak self] in
            guard let self = self else { return }
            while !Task.isCancelled {
                // If nothing buffered, idle briefly
                if self.pendingStreamChars.isEmpty {
                    try? await Task.sleep(nanoseconds: 14_000_000) // 14ms idle
                    continue
                }
                // Pull a small batch to smooth output
                let isGPT5 = (self.selectedModel == .gpt5Mini)
                let batchCount = {
                    if isGPT5 {
                        // Smaller groups for smoother, slower GPT‑5 typing
                        return min( max(3, self.pendingStreamChars.count / 28), 28 )
                    } else {
                        return min( max(6, self.pendingStreamChars.count / 20), 48 )
                    }
                }()
                let take = min(batchCount, self.pendingStreamChars.count)
                let chunk = String(self.pendingStreamChars.prefix(take))
                self.pendingStreamChars.removeFirst(take)
                if let idx = self.messages.firstIndex(where: { $0.id == messageId }) {
                    let oldContent = self.messages[idx].content
                    let newContent = self.processStreamingContent(self.messages[idx].content + chunk)
                    self.messages[idx].content = newContent
                    print("🟪 Drainer: Added chunk '\(chunk)' (len=\(chunk.count)), oldContent=\(oldContent.count) chars, newContent=\(newContent.count) chars")
                }
                let delay: UInt64 = (self.selectedModel == .gpt5Mini) ? 34_000_000 : 18_000_000
                try? await Task.sleep(nanoseconds: delay) // cadence
            }
        }
    }
    // Build mapping host -> index from Sources block if present; otherwise from any URLs in text (order of appearance)
    func buildHostToIndex(from text: String) -> [String: Int]? {
        let ns = text as NSString
        var ordered: [String] = []
        if let sourcesRange = text.range(of: "\nSources:", options: [.caseInsensitive, .backwards]) {
            let tail = String(text[sourcesRange.lowerBound...])
            if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
                let matches = detector.matches(in: tail, options: [], range: NSRange(location: 0, length: (tail as NSString).length))
                for m in matches { if let u = m.url, (u.scheme == "http" || u.scheme == "https") {
                    let host = (u.host ?? "").replacingOccurrences(of: "www.", with: "")
                    if !host.isEmpty && !ordered.contains(host) { ordered.append(host) }
                }}
            }
        }
        if ordered.isEmpty, let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            let matches = detector.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length))
            for m in matches { if let u = m.url, (u.scheme == "http" || u.scheme == "https") {
                let host = (u.host ?? "").replacingOccurrences(of: "www.", with: "")
                if !host.isEmpty && !ordered.contains(host) { ordered.append(host) }
            }}
        }
        guard !ordered.isEmpty else { return nil }
        var map: [String: Int] = [:]
        for (i, h) in ordered.enumerated() { map[h] = i + 1 }
        return map
    }

    // Replace any (domain.tld, domain2.tld) inline with [1][2] using mapping
    func replaceInlineDomains(using map: [String: Int], in text: String) -> String {
        let ns = text as NSString
        // Allow optional backticks around each domain token
        let pattern = "\\((`?[A-Za-z0-9_.-]+\\.[A-Za-z]{2,}`?(?:\\s*,\\s*`?[A-Za-z0-9_.-]+\\.[A-Za-z]{2,}`?)*)\\)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length))
        var result = text
        for m in matches.reversed() {
            let inside = ns.substring(with: m.range(at: 1))
            let domains = inside.split(separator: ",").map { token -> String in
                var d = String(token).trimmingCharacters(in: .whitespacesAndNewlines)
                if d.hasPrefix("`") && d.hasSuffix("`") && d.count >= 2 { d = String(d.dropFirst().dropLast()) }
                return d.replacingOccurrences(of: "www.", with: "")
            }
            let indices = domains.compactMap { map[$0] }
            let replacement = indices.isEmpty ? "" : indices.map { "[\($0)]" }.joined()
            let rns = result as NSString
            result = rns.replacingCharacters(in: m.range, with: replacement)
        }
        return result
    }

    // Remove any bare-domain parentheses entirely to avoid flashing generic capsules during streaming
    func stripInlineDomainParens(in text: String) -> String {
        let ns = text as NSString
        // Allow optional backticks around each domain token
        guard let regex = try? NSRegularExpression(pattern: "\\((`?[A-Za-z0-9_.-]+\\.[A-Za-z]{2,}`?(?:\\s*,\\s*`?[A-Za-z0-9_.-]+\\.[A-Za-z]{2,}`?)*)\\)", options: [.caseInsensitive]) else { return text }
        return regex.stringByReplacingMatches(in: text, options: [], range: NSRange(location: 0, length: ns.length), withTemplate: "")
    }
    func streamAIMessage(_ fullText: String) async {
        var displayed = ""
        let id = UUID()
        messages.append(ChatMessage(content: displayed, isUser: false, id: id))
        let characters = Array(fullText)
        var i = 0
        // Hide loader immediately when streaming begins
        isLoading = false
        while i < characters.count {
            let chunkSize = min(max(1, Int.random(in: 4...10)), characters.count - i)
            displayed += String(characters[i..<(i + chunkSize)])
            i += chunkSize
            if let idx = messages.firstIndex(where: { $0.id == id }) {
                messages[idx].content = displayed
            }
            let delay = Double.random(in: 0.012...0.030)
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }
}

// MARK: - Model Preferences
enum ModelPreferences {
    private static let key = "last_selected_ai_model"
    static func save(_ model: AIModel) {
        UserDefaults.standard.set(model.rawValue, forKey: key)
    }
    static func load() -> AIModel {
        if let raw = UserDefaults.standard.string(forKey: key), let m = AIModel(rawValue: raw) {
            return m
        }
        return .gpt4o
    }
}

// MARK: - Typing Mode Preferences
enum TypingModePreferences {
    private static let key = "student_typing_mode_enabled"
    static func save(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: key)
    }
    static func load() -> Bool {
        return UserDefaults.standard.bool(forKey: key)
    }
}

private extension NSImage {
    func pngData() -> Data? {
        // Optimize image before conversion to reduce memory usage
        let maxDimension: CGFloat = 1024 // Limit to reasonable size for chat
        let scaledImage = self.scaledToFit(maxDimension: maxDimension)
        
        guard let tiff = scaledImage.tiffRepresentation, 
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        
        // Use compression to reduce file size
        return rep.representation(using: .png, properties: [.compressionFactor: 0.8])
    }
    
    private func scaledToFit(maxDimension: CGFloat) -> NSImage {
        let imageSize = self.size
        let maxImageDimension = max(imageSize.width, imageSize.height)
        
        // If image is already small enough, return as is
        if maxImageDimension <= maxDimension {
            return self
        }
        
        // Calculate scale factor
        let scaleFactor = maxDimension / maxImageDimension
        let newSize = NSSize(width: imageSize.width * scaleFactor, height: imageSize.height * scaleFactor)
        
        // Create scaled image
        let scaledImage = NSImage(size: newSize)
        scaledImage.lockFocus()
        self.draw(in: NSRect(origin: .zero, size: newSize))
        scaledImage.unlockFocus()
        
        return scaledImage
    }
}
