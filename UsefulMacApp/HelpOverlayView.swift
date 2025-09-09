//
//  HelpOverlayView.swift
//  UsefulMacApp
//
//  Created by Aarav Kapur on 8/20/25.
//

import SwiftUI
import AppKit

// Shared state for the overlay
class HelpOverlayState: ObservableObject {
    @Published var response: String = ""
    @Published var isLoading: Bool = true
    @Published var isAnalyzing: Bool = false
    @Published var isGenerating: Bool = false
    @Published var isStreaming: Bool = false
    
    static let shared = HelpOverlayState()
    
    private init() {}
    
    func startLoading() {
        response = ""
        isLoading = true
        isAnalyzing = false
        isGenerating = false
        isStreaming = false
    }
    
    func startAnalyzing() {
        isLoading = false
        isAnalyzing = true
        isGenerating = true  // Keep generating true for the spinner
        isStreaming = false
        response = ""
    }
    
    func startGenerating() {
        isLoading = false
        isAnalyzing = false
        isGenerating = true
        isStreaming = false
        response = ""
    }
    
    func startStreaming() {
        isLoading = false
        isAnalyzing = false
        isGenerating = false
        isStreaming = true
        response = ""
    }
    
    func updateStreamingResponse(_ text: String) {
        response = text
    }
    
    func finishStreaming(_ finalText: String) {
        response = finalText
        isLoading = false
        isAnalyzing = false
        isGenerating = false
        isStreaming = false
    }
}

// Custom window that doesn't steal focus
class NonFocusableWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override var acceptsFirstResponder: Bool { false }
    
    // Prevent the window from becoming key when clicked
    override func mouseDown(with event: NSEvent) {
        // Don't call super to prevent focus changes
        // Handle the event ourselves by finding the clicked view
        let location = event.locationInWindow
        if let contentView = self.contentView,
           let hitView = contentView.hitTest(location) {
            // Only send events to buttons
            if hitView.responds(to: #selector(NSControl.performClick(_:))) {
                hitView.performSelector(onMainThread: #selector(NSControl.performClick(_:)), with: hitView, waitUntilDone: false)
            }
        }
    }
}

struct HelpOverlayView: View {
    @StateObject private var state = HelpOverlayState.shared
    let onClose: () -> Void
    @State private var isVisible = false
    @State private var spinnerRotation: Double = 0
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .foregroundColor(.blue)
                        .font(.system(size: 14, weight: .semibold))
                    
                    Text("GPT 5")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.primary)
                }
                
                Spacer()
                
                // Esc hint (always visible)
                Text("Esc to exit")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
                    .opacity(0.7)

            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.95))
            
            Divider()
                .background(Color.gray.opacity(0.3))
            
            // Content
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if state.isLoading {
                            // Empty loading state - just wait for generating to appear
                            Spacer()
                                .frame(height: 20)
                        } else if state.isGenerating {
                            // Cool purple spinning indicator
                            HStack(spacing: 12) {
                                ZStack {
                                    // Outer spinning ring
                                    Circle()
                                        .stroke(Color.purple.opacity(0.2), lineWidth: 2)
                                        .frame(width: 20, height: 20)
                                    
                                    // Inner spinning arc
                                    Circle()
                                        .trim(from: 0.0, to: 0.7)
                                        .stroke(Color.purple, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                                        .frame(width: 20, height: 20)
                                        .rotationEffect(.degrees(spinnerRotation))
                                        .onAppear {
                                            withAnimation(.linear(duration: 1.0).repeatForever(autoreverses: false)) {
                                                spinnerRotation = 360
                                            }
                                        }
                                }
                                
                                Text(state.isAnalyzing ? "Analyzing" : "Generating")
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                                
                                Spacer()
                            }
                        } else if !state.response.isEmpty {
                            // Response content (streaming or complete)
                            VStack(alignment: .leading, spacing: 8) {
                                FormattedAIText(text: state.response, highlight: "")
                                    .font(.system(size: 13))
                                    .foregroundColor(.primary)
                                    .allowsHitTesting(false) // Prevent text interaction
                                
                                // Invisible anchor for auto-scrolling
                                Color.clear
                                    .frame(height: 1)
                                    .id("bottom")
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .frame(maxHeight: 600)
                .onChange(of: state.response) { _ in
                    // Auto-scroll to bottom when response updates
                    if !state.response.isEmpty {
                        withAnimation(.easeOut(duration: 0.3)) {
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                    }
                }
            }
        }
        .frame(width: 320)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.15), radius: 20, x: 0, y: 8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.2), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .scaleEffect(isVisible ? 1.0 : 0.8)
        .opacity(isVisible ? 1.0 : 0.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isVisible)
        .onAppear {
            withAnimation {
                isVisible = true
            }
        }
    }
    

}

class HelpOverlayWindowController: NSWindowController {
    static var shared: HelpOverlayWindowController?
    var keyMonitor: Any?
    var keyLocalMonitor: Any?
    
    static func showLoading() {
        // Close existing overlay if any
        shared?.close()
        
        // Update state to loading
        HelpOverlayState.shared.startLoading()
        
        // Get the main screen
        guard let screen = NSScreen.main else { return }
        
        // Create window in top right corner
        let windowWidth: CGFloat = 340
        let windowHeight: CGFloat = 134  // ~2/3 of previous 200 for loading state
        let margin: CGFloat = 20
        
        let windowRect = NSRect(
            x: screen.visibleFrame.maxX - windowWidth - margin,
            y: screen.visibleFrame.maxY - windowHeight - margin,
            width: windowWidth,
            height: windowHeight
        )
        
        let overlayWindow = NonFocusableWindow(
            contentRect: windowRect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        
        overlayWindow.level = .floating
        overlayWindow.backgroundColor = .clear
        overlayWindow.isOpaque = false
        overlayWindow.hasShadow = false
        overlayWindow.ignoresMouseEvents = false
        overlayWindow.hidesOnDeactivate = false
        overlayWindow.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        
        // Create controller and show loading state
        let controller = HelpOverlayWindowController(window: overlayWindow)
        shared = controller
        
        let overlayView = HelpOverlayView(
            onClose: {
                controller.close()
            }
        )
        
        overlayWindow.contentView = NSHostingView(rootView: overlayView)
        
        // Show the window without stealing focus
        overlayWindow.orderFront(nil)
        
        // Set up global keyboard monitoring for Escape key to dismiss (when other apps are active)
        let monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // Escape key
                HelpOverlayWindowController.shared?.close()
            }
        }
        
        // Also set up a local monitor to catch Escape while our own app is active
        let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {
                HelpOverlayWindowController.shared?.close()
                return nil // Swallow the event
            }
            return event
        }
        
        // Store monitors to remove later
        if let monitor = monitor {
            controller.keyMonitor = monitor
        }
        controller.keyLocalMonitor = local
    }
    
    static func startAnalyzing() {
        guard let controller = shared else { return }
        
        // Update state to analyzing (shows purple spinner + "Analyzing")
        HelpOverlayState.shared.startAnalyzing()
        
        // Update window size for response content
        let windowWidth: CGFloat = 340
        let windowHeight: CGFloat = 267  // ~2/3 of previous 400
        let margin: CGFloat = 20
        
        if let screen = NSScreen.main {
            let windowRect = NSRect(
                x: screen.visibleFrame.maxX - windowWidth - margin,
                y: screen.visibleFrame.maxY - windowHeight - margin,
                width: windowWidth,
                height: windowHeight
            )
            controller.window?.setFrame(windowRect, display: true, animate: true)
        }
    }
    
    static func startGenerating() {
        // Just update the state - window is already sized correctly
        HelpOverlayState.shared.startGenerating()
    }
    
    static func startStreaming() {
        // Just update the state - window is already sized correctly
        HelpOverlayState.shared.startStreaming()
    }
    
    static func updateStreamingResponse(_ response: String) {
        // Avoid overwriting with empty streaming chunks
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        HelpOverlayState.shared.updateStreamingResponse(response)
    }
    
    static func finishStreaming(_ finalResponse: String) {
        // Just update the state - the view will automatically update
        HelpOverlayState.shared.finishStreaming(finalResponse)
    }
    
    static func updateWithResponse(_ response: String) {
        // Just update the state - the view will automatically update
        HelpOverlayState.shared.finishStreaming(response)
    }
    
    static func show(response: String) {
        // Close existing overlay if any
        shared?.close()
        
        // Get the main screen
        guard let screen = NSScreen.main else { return }
        
        // Create window in top right corner (compact height for CTA)
        let windowWidth: CGFloat = 340
        let windowHeight: CGFloat = 234  // Half of previous 467 for CTA-only panel
        let margin: CGFloat = 20
        
        let windowRect = NSRect(
            x: screen.visibleFrame.maxX - windowWidth - margin,
            y: screen.visibleFrame.maxY - windowHeight - margin,
            width: windowWidth,
            height: windowHeight
        )
        
        let overlayWindow = NonFocusableWindow(
            contentRect: windowRect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        
        overlayWindow.level = .floating
                overlayWindow.backgroundColor = .clear
        overlayWindow.isOpaque = false
        overlayWindow.hasShadow = false
        overlayWindow.ignoresMouseEvents = false
        overlayWindow.hidesOnDeactivate = false
        overlayWindow.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

        // Update state and create the SwiftUI view
        HelpOverlayState.shared.finishStreaming(response)
        
        let helpView = HelpOverlayView(
            onClose: {
                HelpOverlayWindowController.shared?.close()
            }
        )
        
        overlayWindow.contentView = NSHostingView(rootView: helpView)
        
        // Create and store the window controller
        let controller = HelpOverlayWindowController(window: overlayWindow)
        shared = controller
        
        // Show the window without stealing focus
        overlayWindow.orderFront(nil)
        
        // Set up global keyboard monitoring for Escape key to dismiss (when other apps are active)
        let monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // Escape key
                HelpOverlayWindowController.shared?.close()
            }
        }
        
        // Also set up a local monitor to catch Escape while our own app is active
        let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {
                HelpOverlayWindowController.shared?.close()
                return nil // Swallow the event
            }
            return event
        }

        // Store monitors to remove later
        if let monitor = monitor {
            controller.keyMonitor = monitor
        }
        controller.keyLocalMonitor = local
        
        // Auto-dismiss after 8 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            if HelpOverlayWindowController.shared === controller {
                controller.close()
            }
        }
    }
    
    override func close() {
        // Clean up keyboard monitor
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
        if let local = keyLocalMonitor {
            NSEvent.removeMonitor(local)
            keyLocalMonitor = nil
        }
        
        window?.orderOut(nil)
        window?.contentView = nil
        window = nil
        if HelpOverlayWindowController.shared === self {
            HelpOverlayWindowController.shared = nil
        }
    }
}

#Preview {
    // Set up preview state
    let _ = {
        HelpOverlayState.shared.finishStreaming("Based on what I can see in your screen, it looks like you're working on a document. Here are some suggestions that might help:\n\n• **Save your work** - Press Cmd+S to save your current progress\n• **Find specific text** - Use Cmd+F to search within the document\n• **Undo changes** - Press Cmd+Z if you need to revert recent changes\n\nIs there something specific you'd like help with?")
    }()
    
    return HelpOverlayView(
        onClose: {}
    )
    .frame(width: 340, height: 400)
    .background(.ultraThinMaterial)
}
