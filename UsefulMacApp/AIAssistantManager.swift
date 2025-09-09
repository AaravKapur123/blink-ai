//
//  AIAssistantManager.swift
//  UsefulMacApp
//
//  Created by Aarav Kapur on 8/20/25.
//

import Foundation
import AppKit
import Carbon
import Combine

@MainActor
class AIAssistantManager: ObservableObject {
    static let shared = AIAssistantManager()
    @Published var isProcessing = false
    @Published var lastAction = ""
    @Published var lastResponse = ""
    @Published var screenshotImage: NSImage?
    @Published var showDebugView = false
    @Published var pendingAttachmentImage: NSImage?
    @Published var pendingAttachmentImages: [NSImage] = []
    @Published var pendingAttachmentPDFs: [URL] = []
    @Published var pendingSelectedText: String?
    @Published var studentTypingMode: Bool = false
    
    private let openAIService = OpenAIService()
    private let screenshotService = ScreenshotService.shared
    private let textTypingService = TextTypingService.shared
    private let keyboardManager = KeyboardShortcutManager.shared
    private weak var chatViewModel: ChatViewModel?
    private var previousApp: NSRunningApplication?
    private var savedClipboardString: String?
    private var typingShouldStop: Bool = false
    @Published var typingPaused: Bool = false
    @Published var typingResumeHint: String = ""
    private var typingText: String = ""
    private var typingIndex: Int = 0
    private var keyMonitor: Any?
    private var mouseMonitor: Any?
    private var resumeHotkeyId: UInt32 = 9999
    private var cancellables: Set<AnyCancellable> = []
 
    init() {
        // Load persisted typing mode preference
        studentTypingMode = TypingModePreferences.load()
        setupKeyboardShortcut()
        registerTypeClipboardHotkey()
        observeTypingModeChanges()
    }
    
    private func setupKeyboardShortcut() {
        // 1) Cmd+Shift+U: helper overlay (Responses API, GPT-5 mini streaming)
        keyboardManager.registerHotkey(
            id: UInt32(6),
            keyCode: UInt32(kVK_ANSI_U),
            modifiers: (UInt32(cmdKey) | UInt32(shiftKey))
        ) { [weak self] in
            Task { @MainActor in
                print("⌨️ Cmd+Shift+O pressed: starting Responses overlay stream…")
                await self?.handleQuickHelpResponses()
            }
        }

        // 2) Cmd+Shift+L: show lasso, attach to app, let user caption
        keyboardManager.registerHotkey(
            id: UInt32(3),
            keyCode: UInt32(kVK_ANSI_L),
            modifiers: (UInt32(cmdKey) | UInt32(shiftKey))
        ) { [weak self] in
            Task { @MainActor in
                await self?.handleLassoAndAttach()
            }
        }

        // 3) Cmd+Shift+E: capture selected text → open app in a NEW TAB → let user add directions → generate → paste back
        keyboardManager.registerHotkey(
            id: UInt32(4),
            keyCode: UInt32(kVK_ANSI_E),
            modifiers: (UInt32(cmdKey) | UInt32(shiftKey))
        ) { [weak self] in
            Task { @MainActor in
                await self?.handleSelectionPolish()
            }
        }
    }

    func attachChatViewModel(_ vm: ChatViewModel) {
        self.chatViewModel = vm
    }

    func detachIfMatches(_ vm: ChatViewModel) {
        if chatViewModel === vm {
            chatViewModel = nil
        }
    }
    
    private func observeTypingModeChanges() {
        $studentTypingMode
            .removeDuplicates()
            .sink { enabled in
                TypingModePreferences.save(enabled)
            }
            .store(in: &cancellables)
    }
    
    func handleScreenshotAndType() async {
        guard !isProcessing else { return }
        
        isProcessing = true
        lastAction = "📸 Taking screenshot..."
        
        do {
            // Take screenshot
            guard let screenshotData = await screenshotService.captureScreen() else {
                lastAction = "❌ Failed to capture screen"
                isProcessing = false
                return
            }
            
            // Convert screenshot data to NSImage for display
            if let image = NSImage(data: screenshotData) {
                screenshotImage = image
                showDebugView = true
            }
            
            lastAction = "🧭 Locating question..."
            let question = try await openAIService.extractQuestion(from: screenshotData)
            print("Identified question: \(question)")

            lastAction = "🤖 Answering..."
            let response = try await openAIService.answerQuestionOnly(question)
            lastAction = "✅ AI Answer Received"
            lastResponse = response
            if studentTypingMode {
                // Type exactly like the Cmd+Y flow (session-based, resumable, with typos)
                typingText = response
                typingIndex = 0
                setupUserInterruptionMonitors()
                lastAction = "⌨️ Typing like a student..."
                Task.detached { [weak self] in
                    guard let self = self else { return }
                    await self.textTypingService.beginSession()
                    let next = await self.textTypingService.typeTextHumanLikeSession(self.typingText, startAt: self.typingIndex, allowTypos: true)
                    await MainActor.run {
                        self.typingIndex = next
                        if next < self.typingText.count {
                            self.typingPaused = true
                            self.lastAction = "⏸️ Typing paused"
                            self.installResumeHotkeyIfAvailable()
                        } else {
                            self.clearInterruptionMonitors()
                            self.typingPaused = false
                            self.lastAction = "✅ Typed answer"
                        }
                    }
                }
            } else {
                textTypingService.pasteText(response)
            }
            lastAction = "⌨️ Typed answer"
       
            
        } catch {
            print("Error in AI assistant: \(error)")
            lastAction = "❌ Error occurred: \(error.localizedDescription)"
            lastResponse = "Try Again"
        }
        
        isProcessing = false
    }

    // MARK: - Quick Help (overlay) flow
    func handleQuickHelp() async {
        // Show loading overlay immediately
        await MainActor.run {
            HelpOverlayWindowController.showLoading()
        }
        
        do {
            // Capture only the active window
            guard let screenshotData = await screenshotService.captureActiveWindow() else {
                print("❌ Failed to capture active window")
                // Close loading overlay on error
                await MainActor.run {
                    HelpOverlayWindowController.shared?.close()
                }
                return
            }
            
            print("📸 Captured active window screenshot")
            
            // Show analyzing state immediately (purple spinner + "Analyzing")
            await MainActor.run {
                HelpOverlayWindowController.startAnalyzing()
            }
            
            // Start a timer to switch to "Generating" if no response after 2 seconds
            let generatingTimer = Task {
                try? await Task.sleep(nanoseconds: 4_000_000_000) // 2 seconds
                await MainActor.run {
                    HelpOverlayWindowController.startGenerating()
                }
            }
            
            // Start streaming in background immediately, but keep showing "Analyzing" until first token
            var hasReceivedFirstToken = false
            var latestText: String = ""
            
            // Use REAL streaming - starts immediately in background
            try await openAIService.streamScreenshotForContextualHelp(
                imageData: screenshotData,
                onDelta: { streamedText in
                    if !hasReceivedFirstToken {
                        hasReceivedFirstToken = true
                        // Cancel the generating timer since we got our first token
                        generatingTimer.cancel()
                        // First token received - switch from Analyzing/Generating to streaming display
                        HelpOverlayWindowController.startStreaming()
                        print("🟢 First streaming token received, switching to streaming UI")
                    }
                    latestText = streamedText
                    // Update with streaming content
                    HelpOverlayWindowController.updateStreamingResponse(streamedText)
                },
                onComplete: {
                    // Streaming is complete - the overlay will auto-dismiss after 8 seconds
                    print("🟢 Real streaming completed successfully")
                    // Ensure the final text is shown even if no further deltas arrive
                    if !latestText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        HelpOverlayWindowController.finishStreaming(latestText)
                    }
                }
            )
            
        } catch {
            print("❌ Quick help error: \(error)")
            // Show error message in overlay
            await MainActor.run {
                HelpOverlayWindowController.finishStreaming("Sorry, I couldn't analyze your screen right now. Please try again.")
            }
        }
    }

    // MARK: - Quick Help via Non-streaming GPT-5 mini (Cmd+Shift+O)
    func handleQuickHelpResponses() async {
        // Free tier: block and show CTA panel instead of sending request
        if AuthenticationManager.shared.currentUserTier == .free {
            await MainActor.run {
                HelpOverlayWindowController.show(response: "This is a Pro feature. Try Pro for free today https://blinkapp.ai/pricing")
            }
            return
        }
        // Pro tier: enforce 40/day overlay invocations
        if AuthenticationManager.shared.currentUserTier == .pro {
            let userId = AuthenticationManager.shared.currentUser?.uid
            let ok = FreeUsageLimiter.shared.recordIfAllowed(userId: userId, feature: "overlay_pro", limit: 40)
            if !ok {
                await MainActor.run {
                    HelpOverlayWindowController.show(response: "You have reached the daily limit for the Pro plan. Upgrade to Pro Unlimited https://blinkapp.ai/pricing")
                }
                return
            }
        }
        await MainActor.run { HelpOverlayWindowController.showLoading() }
        do {
            guard let screenshotData = await screenshotService.captureActiveWindow() else {
                await MainActor.run { HelpOverlayWindowController.shared?.close() }
                return
            }
            print("📸 Cmd+Shift+O: captured active window screenshot")
            await MainActor.run { HelpOverlayWindowController.startAnalyzing() }

            // Schedule switch to "Generating" after 4 seconds (UI-only; does not delay the request)
            let generatingTimer = Task {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                await MainActor.run { HelpOverlayWindowController.startGenerating() }
            }

            // Use non-streaming GPT-5 mini for faster, more reliable responses
            let response = try await openAIService.analyzeScreenshotForContextualHelp(imageData: screenshotData)
            
            await MainActor.run {
                // Cancel the pending UI switch if we already have a response
                generatingTimer.cancel()
                if response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    HelpOverlayWindowController.finishStreaming("I couldn't analyze this screen. Please try again.")
                } else {
                    HelpOverlayWindowController.finishStreaming(response)
                }
            }
        } catch {
            print("❌ Cmd+Shift+O error: \(error)")
            await MainActor.run {
                HelpOverlayWindowController.finishStreaming("Sorry, I couldn't analyze your screen right now. Please try again.")
            }
        }
    }
    
    // MARK: - Lasso and attach flow
    func handleLassoAndAttach() async {
        guard !isProcessing else { return }
        isProcessing = true
        lastAction = "✂️ Select a region..."
        do {
            guard let regionData = await screenshotService.captureInteractiveRegion(), let image = NSImage(data: regionData) else {
                lastAction = "❌ No region captured"
                isProcessing = false
                return
            }
            pendingAttachmentImage = image
            pendingAttachmentImages = [image]
            lastAction = "📎 Image attached. Add a caption and send."
            // Bring app to front so user can type a caption
            NSApp.activate(ignoringOtherApps: true)
        }
        isProcessing = false
    }

    // MARK: - Selection → Improve/Continue → Paste Back flow
    func handleSelectionPolish() async {
        guard !isProcessing else { return }
        isProcessing = true
        lastAction = "📋 Capturing selected text..."

        // Remember the current frontmost app to return to later
        previousApp = NSWorkspace.shared.frontmostApplication

        // Capture selected text via Cmd+C without disturbing user too much
        let (selected, originalClipboard) = captureSelectedTextViaCopy()
        savedClipboardString = originalClipboard

        guard let selectedText = selected, !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            lastAction = "❌ No text selection detected"
            isProcessing = false
            return
        }

        pendingSelectedText = selectedText

        // Bring our app to the front and open a NEW TAB in the current window
        NSApp.activate(ignoringOtherApps: true)
        if let targetWindow = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }),
           let sessions = findSessionsStore(in: targetWindow) {
            let newSession = sessions.newSession()
            attachChatViewModel(newSession.viewModel)
            newSession.viewModel.currentMessage = "\"\(selectedText)\"\n"
        } else if let vm = chatViewModel {
            // Fallback: prefill on the currently attached view model
            vm.currentMessage = "\"\(selectedText)\"\n"
        }

        lastAction = "📝 Add directions and press Send to paste back"
        isProcessing = false
    }

    func generateFromSelectionAndPasteBack(using inputMessage: String) async {
        guard let selected = pendingSelectedText else {
            // Fallback to normal send if no selection is pending
            return
        }
        guard !isProcessing else { return }
        isProcessing = true
        lastAction = "🤖 Generating..."

        // Derive directions from the input by removing the quoted selection prefix if present
        let quoted = "\"\(selected)\""
        var directions = inputMessage
        if directions.hasPrefix(quoted) {
            directions = String(directions.dropFirst(quoted.count))
        }
        directions = directions.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            // Show user message immediately
            let userPrompt = "\"\(selected)\"\n\(directions)".trimmingCharacters(in: .whitespacesAndNewlines)
            if let vm = chatViewModel {
                vm.messages.append(ChatMessage(content: userPrompt, isUser: true))
            }

            let response = try await openAIService.rewriteOrContinueText(selected: selected, direction: directions)
            lastResponse = response
            lastAction = "✅ Generated"

            // Append AI response after it returns
            if let vm = chatViewModel {
                vm.messages.append(ChatMessage(content: "Last Typed: \(response)", isUser: false))
            }

            // Switch back to the previous app and paste when response is ready
            if let app = previousApp {
                app.activate(options: [.activateIgnoringOtherApps])
                // Small delay to ensure focus
                usleep(120000)
            }
            if studentTypingMode {
                typingText = response
                typingIndex = 0
                setupUserInterruptionMonitors()
                lastAction = "⌨️ Typing like a student..."
                Task.detached { [weak self] in
                    guard let self = self else { return }
                    await self.textTypingService.beginSession()
                    let next = await self.textTypingService.typeTextHumanLikeSession(self.typingText, startAt: self.typingIndex, allowTypos: true)
                    await MainActor.run {
                        self.typingIndex = next
                        if next < self.typingText.count {
                            self.typingPaused = true
                            self.lastAction = "⏸️ Typing paused"
                            self.installResumeHotkeyIfAvailable()
                        } else {
                            self.clearInterruptionMonitors()
                            self.typingPaused = false
                            self.lastAction = "✅ Pasted back"
                        }
                    }
                }
            } else {
                textTypingService.pasteText(response)
                lastAction = "⌨️ Pasted back"
            }



            // Restore original clipboard contents if available
            // Give the target app a moment to consume the pasteboard before restoring
            usleep(300000)
            if let saved = savedClipboardString {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(saved, forType: .string)
            }
        } catch {
            lastAction = "❌ Error: \(error.localizedDescription)"
        }

        // Cleanup
        pendingSelectedText = nil
        previousApp = nil
        savedClipboardString = nil
        isProcessing = false
    }

    private func captureSelectedTextViaCopy() -> (String?, String?) {
        let pb = NSPasteboard.general
        let original = pb.string(forType: .string)

        // Send Cmd+C
        let source = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: true)
        keyDown?.flags = .maskCommand
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: false)
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)

        // Wait briefly for pasteboard to update
        usleep(180000)

        let selected = pb.string(forType: .string)
        return (selected, original)
    }

    // MARK: - Interruption + Resume
    private func setupUserInterruptionMonitors() {
        clearInterruptionMonitors()
        // Only pause on mouse clicks; do NOT pause on keyboard since we generate keystrokes
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            self?.pauseTypingDueToUser()
        }
    }
    
    private func clearInterruptionMonitors() {
        if let keyMonitor = keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let mouseMonitor = mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        self.keyMonitor = nil
        self.mouseMonitor = nil
    }
    
    private func pauseTypingDueToUser() {
        guard studentTypingMode else { return }
        textTypingService.requestStop()
        typingPaused = true
        lastAction = "⏸️ Paused due to user input"
        installResumeHotkeyIfAvailable()
    }
    
    private func installResumeHotkeyIfAvailable() {
        // Try to register Ctrl+Opt+Cmd+R for resume
        let success = keyboardManager.registerHotkeyIfAvailable(id: resumeHotkeyId, keyCode: UInt32(kVK_ANSI_R), modifiers: (UInt32(controlKey) | UInt32(optionKey) | UInt32(cmdKey))) { [weak self] in
            Task { @MainActor in
                self?.resumeTyping()
            }
        }
        if success {
            typingResumeHint = "Press Ctrl+Opt+Cmd+R to resume typing where you want it"
        } else {
            typingResumeHint = "Ctrl+Opt+Cmd+R is in use. Free it and press it to resume."
        }
    }

    // Cmd+Y: in student mode, type clipboard contents immediately, replacing any paused session
    func registerTypeClipboardHotkey() {
        keyboardManager.registerHotkey(
            id: UInt32(5),
            keyCode: UInt32(kVK_ANSI_Y),
            modifiers: UInt32(cmdKey)
        ) { [weak self] in
            Task { @MainActor in
                guard let self = self, self.studentTypingMode else { return }
                let pb = NSPasteboard.general
                if let text = pb.string(forType: .string), !text.isEmpty {
                    self.typingText = text
                    self.typingIndex = 0
                    self.typingPaused = false
                    self.lastAction = "⌨️ Typing clipboard..."
                    self.setupUserInterruptionMonitors()
                    Task.detached { [weak self] in
                        guard let self = self else { return }
                        await self.textTypingService.beginSession()
                        let next = await self.textTypingService.typeTextHumanLikeSession(self.typingText, startAt: self.typingIndex, allowTypos: true)
                        await MainActor.run {
                            self.typingIndex = next
                            if next < self.typingText.count {
                                self.typingPaused = true
                                self.lastAction = "⏸️ Typing paused"
                                self.installResumeHotkeyIfAvailable()
                            } else {
                                self.clearInterruptionMonitors()
                                self.typingPaused = false
                                self.lastAction = "✅ Done"
                            }
                        }
                    }
                }
            }
        }
    }
    
    func resumeTyping() {
        guard studentTypingMode else { return }
        // If we have no staged text, attempt to pull from clipboard and start typing from scratch
        if typingText.isEmpty || typingIndex >= typingText.count {
            let pb = NSPasteboard.general
            if let text = pb.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                typingText = text
                typingIndex = 0
            } else {
                lastAction = "❌ Nothing to type: copy text first"
                return
            }
        }
        typingPaused = false
        lastAction = "⌨️ Resuming typing..."
        setupUserInterruptionMonitors()
        Task.detached { [weak self] in
            guard let self = self else { return }
            await self.textTypingService.beginSession()
            // Ensure resume uses the same style (with typos) as initial student typing
            let next = await self.textTypingService.typeTextHumanLikeSession(self.typingText, startAt: self.typingIndex, allowTypos: true)
            await MainActor.run {
                self.typingIndex = next
                if next < self.typingText.count {
                    self.typingPaused = true
                    self.lastAction = "⏸️ Typing paused"
                    self.installResumeHotkeyIfAvailable()
                } else {
                    self.clearInterruptionMonitors()
                    self.typingPaused = false
                    self.lastAction = "✅ Done"
                    self.keyboardManager.unregisterHotkey(id: self.resumeHotkeyId)
                    self.typingResumeHint = ""
                }
            }
        }
    }

    // Prepare student typing flow from a direct answer without starting immediately
    func stageStudentTyping(text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // Enable student typing mode for this session
        studentTypingMode = true
        typingText = text
        typingIndex = 0
        typingPaused = true
        lastAction = "📝 Ready to type. Place cursor and press Ctrl+Opt+Cmd+R"
        installResumeHotkeyIfAvailable()
        // Prep interruption monitors so a click immediately after starting will pause properly
        setupUserInterruptionMonitors()
        // Convenience: copy to clipboard as well
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}
