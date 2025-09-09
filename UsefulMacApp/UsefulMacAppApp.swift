//
//  UsefulMacAppApp.swift
//  UsefulMacApp
//
//  Created by Aarav Kapur on 8/20/25.
//

import SwiftUI

@main
struct UsefulMacAppApp: App {
    // Start fresh every run
    @StateObject private var sessions = ChatSessionsStore(startFresh: true)
    @StateObject private var aiAssistantManager = AIAssistantManager.shared
    @StateObject private var authManager = AuthenticationManager.shared
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(sessions)
                .environmentObject(aiAssistantManager)
                .environmentObject(authManager)
                // Ensure the SwiftUI-managed window uses unified titlebar as well
                .background(WindowAccessor { window in
                    configureUnifiedTitlebar(window)
                    // Register the main window so keyboard shortcuts work
                    let delegate = WindowLifetimeDelegate(store: sessions, manager: aiAssistantManager)
                    window.delegate = delegate
                    WindowKeeper.shared.register(window: window, delegate: delegate)
                })
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Tab") {
                    // Send notification to the key window's session store
                    if let keyWindow = NSApp.keyWindow,
                       let sessions = findSessionsStore(in: keyWindow) {
                        NotificationCenter.default.post(
                            name: NSNotification.Name("WindowSpecificNewTab"),
                            object: sessions
                        )
                    }
                }
                .keyboardShortcut("t", modifiers: [.command])
                
                Button("New Window") { openNewChatWindow(resetTabs: true) }
                    .keyboardShortcut("n", modifiers: [.command])
            }
            
            CommandGroup(after: .newItem) {
                Button("Close Tab") {
                    // Send notification to the key window's session store
                    if let keyWindow = NSApp.keyWindow,
                       let sessions = findSessionsStore(in: keyWindow) {
                        NotificationCenter.default.post(
                            name: NSNotification.Name("WindowSpecificCloseTab"),
                            object: sessions
                        )
                    }
                }
                .keyboardShortcut("w", modifiers: [.command])
            }
            
            CommandMenu("Find") {
                Button("Find…") {
                    NotificationCenter.default.post(name: .init("ChatShowFindBar"), object: nil)
                }
                .keyboardShortcut("f", modifiers: [.command])

                Button("Find Next") {
                    NotificationCenter.default.post(name: .init("ChatFindNext"), object: nil)
                }
                .keyboardShortcut("g", modifiers: [.command])

                Button("Find Previous") {
                    NotificationCenter.default.post(name: .init("ChatFindPrev"), object: nil)
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])
            }
        }
    }
}

// MARK: - App-level window helpers
@MainActor
func openNewChatWindow(resetTabs: Bool = false) {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
        styleMask: [.titled, .closable, .resizable, .miniaturizable],
        backing: .buffered,
        defer: false
    )
    window.title = ""
    window.center()
    window.isReleasedWhenClosed = false
    // Unify the titlebar with content so traffic lights sit in the same block
    configureUnifiedTitlebar(window)

    let sessions = resetTabs ? ChatSessionsStore(initialTitle: "New Chat", startFresh: true) : ChatSessionsStore()
    let manager = AIAssistantManager.shared
    let authManager = AuthenticationManager.shared
  

    let root = ContentView()
        .environmentObject(sessions)
        .environmentObject(manager)
        .environmentObject(authManager)
    window.contentView = NSHostingView(rootView: root)
    let delegate = WindowLifetimeDelegate(store: sessions, manager: manager)
    window.delegate = delegate
    WindowKeeper.shared.register(window: window, delegate: delegate)
    window.makeKeyAndOrderFront(nil)
}

final class WindowLifetimeDelegate: NSObject, NSWindowDelegate {
    let store: ChatSessionsStore
    private let manager: AIAssistantManager
    init(store: ChatSessionsStore, manager: AIAssistantManager) {
        self.store = store
        self.manager = manager
    }
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        // Detach from this window's VM if attached
 
        // Try to activate another window; if none, terminate.
        let activated = WindowKeeper.shared.activateFallbackWindow(excluding: window)
        if !activated { DispatchQueue.main.async { NSApp.terminate(nil) } }
        WindowKeeper.shared.unregister(window: window)
    }
}

// MARK: - Window Appearance Helpers
@MainActor
func configureUnifiedTitlebar(_ window: NSWindow) {
    window.title = ""
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.isMovableByWindowBackground = true
    // Let content extend into the titlebar area
    window.styleMask.insert(.fullSizeContentView)
    if #available(macOS 11.0, *) {
        window.toolbarStyle = .unifiedCompact
        window.titlebarSeparatorStyle = .none
    }
}

// MARK: - SwiftUI helper to access NSWindow
struct WindowAccessor: NSViewRepresentable {
    let callback: (NSWindow) -> Void
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                callback(window)
            }
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = nsView.window {
                callback(window)
            }
        }
    }
}

// Native titlebar vibrancy background that visually matches the area with traffic lights
struct TitlebarVibrantBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        if #available(macOS 12.0, *) {
            view.material = .headerView
        } else {
            view.material = .titlebar
        }
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

final class WindowKeeper {
    static let shared = WindowKeeper()
    fileprivate var keepers: [NSWindow: WindowLifetimeDelegate] = [:]
    func register(window: NSWindow, delegate: WindowLifetimeDelegate) {
        keepers[window] = delegate
    }
    func unregister(window: NSWindow) {
        keepers.removeValue(forKey: window)
    }
    @MainActor
    func activateFallbackWindow(excluding closed: NSWindow) -> Bool {
        // Prefer any visible window other than the one closing
        let registered = keepers.keys.filter { $0 != closed && $0.isVisible }
        let systemWindows = NSApp.windows.filter { $0 != closed && $0.isVisible }
        let candidates = !registered.isEmpty ? registered : systemWindows
        if let next = candidates.first {
            next.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return true
        }
        return false
    }
    
    func getSessionsStore(for window: NSWindow) -> ChatSessionsStore? {
        return keepers[window]?.store
    }
}

// Helper function to find the ChatSessionsStore for a specific window
func findSessionsStore(in window: NSWindow) -> ChatSessionsStore? {
    return WindowKeeper.shared.getSessionsStore(for: window)
}
