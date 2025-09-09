//
//  ContentView.swift
//  UsefulMacApp
//
//  Created by Aarav Kapur on 8/20/25.
//

import SwiftUI
import AppKit
import Carbon
import Combine
import UniformTypeIdentifiers

// Simple image cache to avoid recreating NSImage repeatedly
class ImageCache {
    static let shared = ImageCache()
    private var cache: [Data: NSImage] = [:]
    private let cacheQueue = DispatchQueue(label: "imageCache", qos: .utility)
    private let maxCacheSize = 50 // Limit cache size to prevent memory issues
    
    private init() {}
    
    func image(for data: Data) -> NSImage? {
        return cacheQueue.sync {
            return cache[data]
        }
    }
    
    func setImage(_ image: NSImage, for data: Data) {
        cacheQueue.async { [weak self] in
            guard let self = self else { return }
            
            // Simple cache eviction if too many items
            if self.cache.count >= self.maxCacheSize {
                // Remove oldest half of cache entries (simple strategy)
                let keysToRemove = Array(self.cache.keys.prefix(self.maxCacheSize / 2))
                for key in keysToRemove {
                    self.cache.removeValue(forKey: key)
                }
            }
            
            self.cache[data] = image
        }
    }
}

struct ContentView: View {
    @StateObject private var permissionsManager = PermissionsManager()
    @EnvironmentObject var sessions: ChatSessionsStore
    @EnvironmentObject var aiAssistantManager: AIAssistantManager
    @EnvironmentObject var authManager: AuthenticationManager
    
    var body: some View {
        Group {
            switch authManager.authState {
            case .loading:
                // Show loading state while Firebase initializes
                VStack(spacing: 20) {
                    ProgressView()
                        .scaleEffect(1.5)
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    
                    Text("Loading...")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(red: 0.08, green: 0.08, blue: 0.09).ignoresSafeArea())
                
            case .unauthenticated, .error:
                // Show login view when not authenticated
                LoginView()
                    .environmentObject(authManager)
                
            case .authenticated:
                // Show main app when authenticated
                if permissionsManager.allPermissionsGranted {
                    ChatTabsContainer()
                        .environmentObject(sessions)
                        .environmentObject(aiAssistantManager)
                        .environmentObject(authManager)
                } else {
                    PermissionsView()
                        .environmentObject(permissionsManager)
                }
            }
        }
        .frame(minWidth: 400, minHeight: 600)
        .background(WindowAccessor { window in
            configureUnifiedTitlebar(window)
        })
        .onAppear {
            permissionsManager.checkPermissions()
            aiAssistantManager.attachChatViewModel(sessions.activeViewModel)
        }
    }
}
// MARK: - Chat Tabs Container and UI
struct ChatTabsContainer: View {
    @EnvironmentObject var sessions: ChatSessionsStore
    @EnvironmentObject var aiAssistantManager: AIAssistantManager

    var body: some View {
        ChatView(chatViewModel: sessions.activeViewModel)
            .id(sessions.activeSessionId)
            .onChange(of: sessions.activeSessionId) { _ in
                aiAssistantManager.attachChatViewModel(sessions.activeViewModel)
            }
    }
}

struct ChatTabsBar: View {
    @EnvironmentObject var sessions: ChatSessionsStore
    @EnvironmentObject var aiAssistantManager: AIAssistantManager
    
    let availableWidth: CGFloat
    private let minTabWidth: CGFloat = 80
    private let maxTabWidth: CGFloat = 200

    var body: some View {
        let tabWidth = calculateTabWidth(for: availableWidth)
        let totalTabsWidth = CGFloat(sessions.sessions.count) * tabWidth + CGFloat(max(0, sessions.sessions.count - 1)) * 2
        
        HStack(spacing: 2) {
            // Reverse the order so newest tabs appear on the right  
            ForEach(sessions.sessions.reversed(), id: \.id) { session in
                let isActive = session.id == sessions.activeSessionId
                
                HStack(spacing: 4) {
                    Text(session.title.isEmpty ? "New Chat" : session.title)
                        .font(.system(size: 10, weight: isActive ? .semibold : .regular, design: .rounded))
                        .foregroundColor(isActive ? .white : .secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    
                    if sessions.sessions.count > 1 {
                        Button(action: { sessions.closeSession(id: session.id) }) {
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .frame(width: 16, height: 16)
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 6)
                .frame(width: tabWidth)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isActive ? Color.white.opacity(0.10) : Color.white.opacity(0.04))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.white.opacity(isActive ? 0.12 : 0.06), lineWidth: 1)
                )
                .onTapGesture {
                    sessions.switchTo(id: session.id)
                    aiAssistantManager.attachChatViewModel(session.viewModel)
                }
                .contextMenu {
                    Button("Rename") { sessions.rename(id: session.id, to: suggestTitle(session.viewModel)) }
                    Button("Close", role: .destructive) { sessions.closeSession(id: session.id) }
                }
            }
        }
        .frame(width: totalTabsWidth, height: 32)
    }
    
    private func calculateTabWidth(for containerWidth: CGFloat) -> CGFloat {
        let tabCount = CGFloat(sessions.sessions.count)
        guard tabCount > 0 else { return maxTabWidth }
        
        // Calculate spacing between tabs
        let totalSpacing = (tabCount - 1) * 2 // 2pt spacing between tabs
        let availableWidthForTabs = containerWidth - totalSpacing
        
        // Calculate ideal width per tab
        let idealWidth = availableWidthForTabs / tabCount
        
        // Chrome behavior: always fit all tabs, compress if needed
        return max(minTabWidth, min(maxTabWidth, idealWidth))
    }

    private func suggestTitle(_ vm: ChatViewModel) -> String {
        if let first = vm.messages.first(where: { $0.isUser })?.content { return String(first.prefix(40)) }
        return "New Chat"
    }
}

struct NewChatButton: View {
    @EnvironmentObject var sessions: ChatSessionsStore
    @EnvironmentObject var aiAssistantManager: AIAssistantManager
    var body: some View {
        Button(action: {
            let s = sessions.newSession()
            aiAssistantManager.attachChatViewModel(s.viewModel)
        }) {
            HStack(spacing: 3) {
                Image(systemName: "square.and.pencil")
                Text("New Chat")
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(.primary)
            .padding(.vertical, 8)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

struct NewWindowButton: View {
    var body: some View {
        Button(action: {
            openNewChatWindow(resetTabs: true)
        }) {
            HStack(spacing: 3) {
                Image(systemName: "rectangle.badge.plus")
                Text("New Window")
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(.primary)
            .padding(.vertical, 8)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// Use the global openNewChatWindow(resetTabs:) defined in UsefulMacAppApp.swift

struct HistoryButton: View {
    @EnvironmentObject var sessions: ChatSessionsStore
    @EnvironmentObject var aiAssistantManager: AIAssistantManager
    @Binding var isOpen: Bool
    var body: some View {
        Button(action: { withAnimation { isOpen.toggle() } }) {
            HStack(spacing: 3) {
                Image(systemName: "clock.arrow.circlepath")
                Text("History")
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(.primary)
            .padding(.vertical, 8)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .popover(isPresented: .constant(false)) { EmptyView() }
    }

    private func formattedDate(_ date: Date) -> String {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        return df.string(from: date)
    }
}

// Custom history popover style similar to screenshot
struct HistoryPopover: View {
    @EnvironmentObject var sessions: ChatSessionsStore
    @EnvironmentObject var aiAssistantManager: AIAssistantManager
    @Binding var isVisible: Bool
    @State private var anchorFrame: CGRect = .zero
    @State private var searchText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Conversations")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button(action: { withAnimation { isVisible = false } }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                }
                .buttonStyle(.plain)
            }
            .padding(10)
            .background(Color.black.opacity(0.8))

            // Search field
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search conversations...", text: $searchText)
                    .textFieldStyle(.plain)
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
            .background(Color.black.opacity(0.8))
            .onChange(of: searchText) { newValue in
                sessions.updateHistorySearch(query: newValue)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    // Use published, debounced background results for smooth typing
                    ForEach(historyResults) { s in
                        HStack(alignment: .center) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.title.isEmpty ? "New Chat" : s.title)
                                    .font(.system(size: 12, weight: .medium))
                                Text(formattedDate(s.updatedAt))
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Button(action: {
                                // If searching, find a matching message to scroll to once opened
                                let q = searchText
                                let targetId = sessions.firstMatchingMessageId(inStored: s.id, query: q)
                                sessions.openFromHistory(id: s.id)
                                sessions.pendingScrollTargetMessageId = targetId
                                aiAssistantManager.attachChatViewModel(sessions.activeViewModel)
                                withAnimation { isVisible = false }
                            }) {
                                Text("Open")
                                    .font(.system(size: 11))
                            }
                            .buttonStyle(.bordered)
                            Button(role: .destructive, action: {
                                sessions.deleteStored(id: s.id)
                            }) {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.black.opacity(0.85))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Color.white.opacity(0.15), lineWidth: 1)
                        )
                        .padding(.horizontal, 8)
                        .padding(.top, 6)
                    }
                }
                .padding(.bottom, 8)
            }
            // Fill horizontal space; fixed height for usability
            .frame(maxWidth: .infinity)
            .frame(height: 380)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.2), lineWidth: 1)
        )
    }

    private static let historyDateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        return df
    }()

    private func formattedDate(_ date: Date) -> String {
        Self.historyDateFormatter.string(from: date)
    }

    // Typed results array to help the Swift type-checker and reduce complexity in the body
    private var historyResults: [ChatSessionsStore.SessionSummary] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty {
            return Array(sessions.storedSummaries.prefix(400))
        } else {
            return sessions.historySearchResults
        }
    }
}

struct PermissionsView: View {
    @EnvironmentObject var permissionsManager: PermissionsManager
    
    var body: some View {
        VStack(spacing: 30) {
            Image(systemName: "shield.checkered")
                .font(.system(size: 80))
                .foregroundColor(.blue)
            
            Text("AI Assistant Setup")
                .font(.largeTitle)
                .fontWeight(.bold)
            
            
            VStack(alignment: .leading, spacing: 20) {
                PermissionRow(
                    icon: "video.circle",
                    title: "Screen Recording",
                    description: "Allows the AI to see your screen and understand context",
                    isGranted: permissionsManager.screenRecordingPermission
                )
                
                PermissionRow(
                    icon: "hand.point.up.left",
                    title: "Accessibility",
                    description: "Enables typing responses directly where you need them",
                    isGranted: permissionsManager.accessibilityPermission
                )
            }
            .padding()
            .background(.ultraThinMaterial)
            .overlay(Divider(), alignment: .bottom)
            .cornerRadius(12)
            
            VStack(spacing: 15) {
                Button("Grant Permissions") {
                    permissionsManager.requestPermissions()
                }
                .buttonStyle(.borderedProminent)
                .font(.headline)
                
                Button("Open System Preferences") {
                    permissionsManager.openSystemPreferences()
                }
                .buttonStyle(.bordered)
                
                Button("Refresh Status") {
                    permissionsManager.checkPermissions()
                }
                .buttonStyle(.borderless)
                .foregroundColor(.secondary)
            }
            
            
        }
        .padding(40)
        .frame(maxWidth: 600)
    }
}

struct PermissionRow: View {
    let icon: String
    let title: String
    let description: String
    let isGranted: Bool
    
    var body: some View {
        HStack(spacing: 15) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(.blue)
                .frame(width: 30)
            
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Image(systemName: isGranted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.title2)
                .foregroundColor(isGranted ? .green : .red)
        }
    }
}

struct ChatView: View {
    @ObservedObject var chatViewModel: ChatViewModel
    @EnvironmentObject var aiAssistantManager: AIAssistantManager
    @EnvironmentObject var authManager: AuthenticationManager
    @EnvironmentObject var sessions: ChatSessionsStore
    @FocusState private var isInputFocused: Bool
    @State private var showHistory = false
    // Find-in-chat state
    @State private var showFindBar = false
    @State private var findQuery: String = ""
    @State private var findMatches: [UUID] = []
    @State private var findIndex: Int = 0
    // Loading intro animation state
    @State private var showIntroDots: Bool = false
    // Auto-scroll state (disabled when user actively scrolls)
    @State private var autoScrollEnabled: Bool = true
    // Composer dynamic height
    @State private var composerHeight: CGFloat = 96
    private let composerBaseHeight: CGFloat = 96
    private let composerMaxHeight: CGFloat = 192
    // Width tracking for precise horizontal expansion
    @State private var composerRowWidth: CGFloat = 0
    @State private var attachButtonWidth: CGFloat = 0
    @State private var sendButtonWidth: CGFloat = 0

    
    var body: some View {
        VStack(spacing: 0) {
            // Debug View for Screenshot Analysis
            // Debug panel removed for clean UI
            
            // Messages
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(alignment: .leading, spacing: 10, pinnedViews: []) {
                        // Show Create Presentation button when chat is empty and no text in input
                        if false && chatViewModel.messages.count <= 1 && chatViewModel.currentMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            VStack(spacing: 20) {
                                Spacer()
                                
                                Button(action: {
                                    
                                }) {
                                    HStack(spacing: 12) {
                                        Image(systemName: "presentation.person.fill")
                                            .font(.title2)
                                        Text("Create Presentation")
                                            .font(.title2)
                                            .fontWeight(.semibold)
                                    }
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 32)
                                    .padding(.vertical, 16)
                                    .background(
                                        LinearGradient(
                                            gradient: Gradient(colors: [Color.blue, Color.purple]),
                                            startPoint: .leading,
                                            endPoint: .trailing
                                        )
                                    )
                                    .cornerRadius(25)
                                    .shadow(color: .blue.opacity(0.3), radius: 10, x: 0, y: 5)
                                }
                                .buttonStyle(.plain)
                                .scaleEffect(1.0)
                                .onHover { isHovered in
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        // Add subtle scale effect on hover if desired
                                    }
                                }
                                
                                Text("Create stunning presentations with AI assistance")
                                    .font(.system(size: 13, weight: .light))
                                    .foregroundColor(.primary)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .fill(Color.white.opacity(0.06))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                                    )
                                    .multilineTextAlignment(.center)
                                
                                Spacer()
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        
                        ForEach(chatViewModel.messages) { message in
                            VStack(alignment: .leading, spacing: 6) {
                                MessageBubble(
                                    message: message,
                                    highlightQuery: findQuery.trimmingCharacters(in: .whitespacesAndNewlines),
                                    isSelectedFindMatch: (!findMatches.isEmpty && findIndex < findMatches.count && message.id == findMatches[findIndex])
                                )
                                .id(message.id)

                                // Follow-up chips shown under the last assistant message
                                if !message.isUser, message.id == chatViewModel.messages.last(where: { !$0.isUser })?.id, !chatViewModel.followUpsForLastAssistant.isEmpty {
                                    ScrollView(.horizontal, showsIndicators: false) {
                                        HStack(spacing: 6) {
                                            ForEach(chatViewModel.followUpsForLastAssistant, id: \.self) { up in
                                                Button(action: {
                                                    // Insert suggestion into composer instead of auto-sending
                                                    NotificationCenter.default.post(name: .init("ChatInsertFollowUpIntoComposer"), object: up)
                                                }) {
                                                    Text(up)
                                                        .font(.system(size: 11, weight: .medium))
                                                        .foregroundColor(.primary)
                                                        .padding(.vertical, 6)
                                                        .padding(.horizontal, 10)
                                                        .background(
                                                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                                .fill(Color.white.opacity(0.06))
                                                        )
                                                        .overlay(
                                                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                                .stroke(Color.white.opacity(0.08), lineWidth: 1)
                                                        )
                                                }
                                                .buttonStyle(.plain)
                                            }
                                        }
                                    }
                                    .padding(.leading, 6)
                                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                                }
                            }
                        }
                        
                        if chatViewModel.isLoading {
                            VStack(alignment: .leading, spacing: 6) {
                                if showIntroDots {
                                    LoadingDotsView()
                                        .frame(width: 40, height: 14)
                                } else {
                                    LoadingLineView(height: 3)
                                        .frame(maxWidth: 290)
                                    Text(chatViewModel.isAutoResearching ? "Searching for current information…" : "Thinking…")
                                        .font(.system(size: 12, weight: .regular, design: .rounded))
                                        .foregroundColor(.secondary)
                                }
                            }
                            .padding(.vertical, 8)
                            .padding(.bottom, 16)
                        }
                        // Invisible bottom anchor for reliable scrolling
                        Color.clear
                            .frame(height: 1)
                            .id("bottomAnchor")
                            .onAppear { autoScrollEnabled = true }
                    }
                    .padding()
                }
                // Mark user interaction to temporarily disable auto-scroll
                .gesture(DragGesture().onChanged { _ in autoScrollEnabled = false })
                // Scroll to bottom on initial appear
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo("bottomAnchor", anchor: .bottom)
                        }
                    }
                }
                // Keep pinned at bottom as messages stream in, unless user is scrolling
                .onChange(of: chatViewModel.messages) { _ in
                    if autoScrollEnabled {
                        DispatchQueue.main.async {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                proxy.scrollTo("bottomAnchor", anchor: .bottom)
                            }
                        }
                    }
                }
                // Also scroll when loading starts (e.g., loader appears before first delta)
                .onChange(of: chatViewModel.isLoading) { loading in
    if loading {
        showIntroDots = true
        // Use 1 second for internet mode, 5 seconds for regular chat
        let timeout = (chatViewModel.forceInternet || chatViewModel.isAutoResearching) ? 1.0 : 5.0
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
            if chatViewModel.isLoading {
                showIntroDots = false
            }
        }
        if autoScrollEnabled {
            DispatchQueue.main.async {
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo("bottomAnchor", anchor: .bottom)
                }
            }
        }
    } else {
        showIntroDots = false
    }
}
                // When switching tabs/sessions, jump to the bottom of that conversation
                .onChange(of: sessions.activeSessionId) { _ in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            proxy.scrollTo("bottomAnchor", anchor: .bottom)
                        }
                    }
                }
                .onChange(of: sessions.pendingScrollTargetMessageId) { target in
                    guard let target = target else { return }
                    // Scroll after a tiny delay to ensure layout is done after switching/opening
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        if chatViewModel.messages.contains(where: { $0.id == target }) {
                            withAnimation(.easeInOut(duration: 0.3)) {
                                proxy.scrollTo(target, anchor: .center)
                            }
                        }
                        sessions.pendingScrollTargetMessageId = nil
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .init("ChatShowFindBar"))) { _ in
                    withAnimation { showFindBar = true }
                }
                .onReceive(NotificationCenter.default.publisher(for: .init("ChatFindNext"))) { _ in
                    guard showFindBar, !findMatches.isEmpty else { return }
                    findIndex = (findIndex + 1) % findMatches.count
                    withAnimation { proxy.scrollTo(findMatches[findIndex], anchor: .center) }
                }
                .onReceive(NotificationCenter.default.publisher(for: .init("ChatFindPrev"))) { _ in
                    guard showFindBar, !findMatches.isEmpty else { return }
                    findIndex = (findIndex - 1 + findMatches.count) % findMatches.count
                    withAnimation { proxy.scrollTo(findMatches[findIndex], anchor: .center) }
                }
                .onReceive(NotificationCenter.default.publisher(for: .init("ChatFindScrollTo"))) { notif in
                    if let id = notif.object as? UUID {
                        withAnimation { proxy.scrollTo(id, anchor: .center) }
                    }
                }
                .onChange(of: findIndex) {
                    guard !findMatches.isEmpty, findIndex < findMatches.count else { return }
                    withAnimation { proxy.scrollTo(findMatches[findIndex], anchor: .center) }
                }
            }
            
            // Input
            VStack(alignment: .leading, spacing: 8) {
                // Editing banner
                if let anchorId = chatViewModel.editAnchorMessageId, let anchor = chatViewModel.messages.first(where: { $0.id == anchorId }) {
                    HStack(spacing: 8) {
                        Image(systemName: "pencil.circle.fill")
                            .foregroundColor(.secondary)
                        Text("Editing message from " + formatTime(anchor.timestamp))
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        Spacer()
                        Button(action: {
                            // Cancel edit: clear anchor and pending attachments, keep current text
                            chatViewModel.editAnchorMessageId = nil
                            aiAssistantManager.pendingAttachmentImages = []
                            aiAssistantManager.pendingAttachmentImage = nil
                            aiAssistantManager.pendingAttachmentPDFs = []
                        }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Cancel editing")
                    }
                    .padding(.horizontal, 42)
                }
                // Chip-style toggle above the textbox, attached to the composer
                HStack(spacing: 8) {
                    ModelSelectorChip(selectedModel: $chatViewModel.selectedModel, researchEnabled: false)
                    ToggleChip(isOn: $chatViewModel.forceInternet, title: "Internet", iconOn: "globe.americas.fill", iconOff: "globe.americas")
                        .padding(.leading, 4)
                        .help("Force an internet search for this message. Auto-turns off after sending.")
                        .opacity(chatViewModel.selectedModel == .claudeHaiku ? 0.5 : 1.0)
                        .disabled(chatViewModel.selectedModel == .claudeHaiku)
                    Spacer()
                }
                .padding(.leading, 42)

                // Composer preview above the textbox
                if !aiAssistantManager.pendingAttachmentImages.isEmpty || !aiAssistantManager.pendingAttachmentPDFs.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            // Show images
                            ForEach(Array(aiAssistantManager.pendingAttachmentImages.enumerated()), id: \.offset) { index, img in
                                ZStack(alignment: .topTrailing) {
                                    Image(nsImage: img)
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                        .frame(width: 72, height: 72)
                                        .clipped()
                                        .cornerRadius(8)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.25), lineWidth: 1)
                                        )
                                    Button(action: {
                                        withAnimation(.easeInOut(duration: 0.15)) {
                                            aiAssistantManager.pendingAttachmentImages.remove(at: index)
                                            if aiAssistantManager.pendingAttachmentImages.isEmpty { aiAssistantManager.pendingAttachmentImage = nil }
                                        }
                                    }) {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundColor(.secondary)
                                            .background(Circle().fill(Color(NSColor.controlBackgroundColor)))
                                    }
                                    .buttonStyle(.plain)
                                    .offset(x: 6, y: -6)
                                }
                            }
                            // Show PDFs
                            ForEach(Array(aiAssistantManager.pendingAttachmentPDFs.enumerated()), id: \.offset) { index, pdfURL in
                                ZStack(alignment: .topTrailing) {
                                    VStack(spacing: 4) {
                                        Image(systemName: "doc.fill")
                                            .font(.title2)
                                            .foregroundColor(.red)
                                        Text(pdfURL.lastPathComponent)
                                            .font(.system(size: 9, weight: .medium))
                                            .lineLimit(2)
                                            .multilineTextAlignment(.center)
                                    }
                                    .frame(width: 72, height: 72)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8)
                                            .fill(Color.red.opacity(0.1))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.25), lineWidth: 1)
                                    )
                                    Button(action: {
                                        withAnimation(.easeInOut(duration: 0.15)) {
                                            aiAssistantManager.pendingAttachmentPDFs.remove(at: index)
                                            // Check if model should be unlocked
                                            if aiAssistantManager.pendingAttachmentPDFs.isEmpty {
                                                // Reset to previous model if no PDFs remain
                                            }
                                        }
                                    }) {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundColor(.secondary)
                                            .background(Circle().fill(Color(NSColor.controlBackgroundColor)))
                                    }
                                    .buttonStyle(.plain)
                                    .offset(x: 6, y: -6)
                                }
                            }
                        }
                        .padding(.horizontal, 12)
                    }
                }

                composerArea
            }
            .padding(.vertical, 16)
            .padding(.leading, 24)
            .padding(.trailing, 16)
            .frame(maxWidth: .infinity)
            .background(
                .ultraThinMaterial
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.gray.opacity(0.12), lineWidth: 1)
            )
            .onDrop(of: [UTType.image, UTType.fileURL, UTType.png, UTType.jpeg, UTType.tiff, UTType.text, UTType.pdf], isTargeted: nil) { providers in
                handleDrop(providers: providers)
            }
            .onChange(of: aiAssistantManager.pendingSelectedText) { newValue in
                if newValue != nil {
                    // Focus input so caret is under the just-inserted quote
                    DispatchQueue.main.async {
                        isInputFocused = true
                        moveComposerCaretToEnd()
                    }
                }
            }
            .onAppear {
                // Always focus the input when the app appears
                DispatchQueue.main.async {
                    isInputFocused = true
                    moveComposerCaretToEnd()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .init("ChatSendFollowUp"))) { notif in
                if let text = notif.object as? String {
                    chatViewModel.currentMessage = text
                    chatViewModel.sendMessage()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .init("ChatInsertFollowUpIntoComposer"))) { notif in
                if let text = notif.object as? String {
                    chatViewModel.currentMessage = text
                    // Focus input so user can edit/press Enter
                    DispatchQueue.main.async {
                        isInputFocused = true
                        moveComposerCaretToEnd()
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .init("ChatBeginEditMessage"))) { notif in
                if let msg = notif.object as? ChatMessage {
                    // Set anchor to insert after this user message
                    chatViewModel.editAnchorMessageId = msg.id
                    // Prefill text
                    chatViewModel.currentMessage = msg.content
                    // Prefill attachments
                    if let pdfs = msg.attachmentPDFs, !pdfs.isEmpty {
                        aiAssistantManager.pendingAttachmentPDFs = pdfs
                        // Lock model to Gemini when PDFs present
                        chatViewModel.selectedModel = .geminiFlash
                    } else if let datas = msg.attachmentDatas, !datas.isEmpty {
                        let images: [NSImage] = datas.compactMap { NSImage(data: $0) }
                        aiAssistantManager.pendingAttachmentImages = images
                        aiAssistantManager.pendingAttachmentImage = images.first
                    } else if let data = msg.attachmentData, let img = NSImage(data: data) {
                        aiAssistantManager.pendingAttachmentImages = [img]
                        aiAssistantManager.pendingAttachmentImage = img
                    } else {
                        // Clear any pending attachments if editing a plain text
                        aiAssistantManager.pendingAttachmentImages = []
                        aiAssistantManager.pendingAttachmentImage = nil
                        aiAssistantManager.pendingAttachmentPDFs = []
                    }
                    // Focus input
                    DispatchQueue.main.async {
                        isInputFocused = true
                        moveComposerCaretToEnd()
                    }
                }
            }

        }
        .background(Color(red: 0.08, green: 0.08, blue: 0.09).ignoresSafeArea())
        .navigationTitle("")
        .safeAreaInset(edge: .top) {
            VStack(spacing: 0) {
                // Tabs row - same background as macOS titlebar
                TitlebarTabs()
                    .environmentObject(aiAssistantManager)
                    .environmentObject(sessions)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background(Color(red: 0.15, green: 0.15, blue: 0.16)) // Same as titlebar
                    .overlay(
                        Rectangle()
                            .frame(height: 1)
                            .foregroundColor(Color.white.opacity(0.1)),
                        alignment: .bottom
                    )
                
                // Second row of buttons
                HStack(spacing: 8) {
                    TitlebarModeToggle()
                        .environmentObject(aiAssistantManager)
                        .fixedSize()
                    
                    Spacer()
                    
                    HStack(spacing: 8) {
                        NewChatButton().fixedSize()
                        NewWindowButton().fixedSize()
                        HistoryButton(isOpen: $showHistory).fixedSize()
                        SettingsButton().fixedSize()
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 0)
                .background(Color(red: 0.11, green: 0.11, blue: 0.12))
                .overlay(
                    Rectangle()
                        .frame(height: 1)
                        .foregroundColor(Color.white.opacity(0.1)),
                    alignment: .bottom
                )
            }
        }
        .toolbarBackground(.visible, for: .windowToolbar)
        .toolbarBackground(Color(red: 0.15, green: 0.15, blue: 0.16), for: .windowToolbar)
        .overlay(alignment: .topTrailing) {
            if showHistory {
                HistoryPopover(isVisible: $showHistory)
                    .environmentObject(sessions)
                    .environmentObject(aiAssistantManager)
                    .zIndex(10000)
                    .padding(.trailing, 12)
                    .padding(.top, 58)
            }
            if showFindBar {
                FindBar(
                    query: $findQuery,
                    matches: $findMatches,
                    index: $findIndex,
                    allMessages: chatViewModel.messages,
                    onClose: {
                        showFindBar = false
                        findQuery = ""
                        findMatches = []
                        findIndex = 0
                    }
                )
                .padding(.trailing, 12)
                .padding(.top, 58)
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(10001)
            }
            // Absolute top-right CTA badge (outside toolbar rows) — align with traffic-light level
            if authManager.currentUserTier == .free {
                Button(action: {
                    if let url = URL(string: "https://blinkapp.ai/pricing") { NSWorkspace.shared.open(url) }
                }) {
                    Text("Try Pro For Free")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 10)
                        .background(
                            LinearGradient(gradient: Gradient(colors: [Color.purple, Color.blue]), startPoint: .leading, endPoint: .trailing)
                                .opacity(0.95)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(Color.white.opacity(0.25), lineWidth: 1)
                        )
                        .cornerRadius(10)
                        .shadow(color: .black.opacity(0.25), radius: 8, x: 0, y: 6)
                }
                .buttonStyle(.plain)
                .padding(.trailing, 8)
                .padding(.top, 0)
                .zIndex(10002)
            }
        }
        .onChange(of: showFindBar) { visible in
            if !visible {
                findQuery = ""
                findMatches = []
                findIndex = 0
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("WindowSpecificNewTab"))) { notification in
            // Check if this notification is for the current window
            if let targetSessions = notification.object as? ChatSessionsStore, targetSessions === sessions {
                let newSession = sessions.newSession()
                aiAssistantManager.attachChatViewModel(newSession.viewModel)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("WindowSpecificCloseTab"))) { notification in
            // Check if this notification is for the current window
            if let targetSessions = notification.object as? ChatSessionsStore, targetSessions === sessions {
                if sessions.sessions.count > 1 {
                    // Multiple tabs: close the current tab
                    sessions.closeSession(id: sessions.activeSessionId)
                } else {
                    // Single tab: close the window (unless it's the last window)
                    if NSApp.windows.filter({ $0.isVisible }).count > 1 {
                        // Find and close this window
                        DispatchQueue.main.async {
                            if let window = NSApp.keyWindow {
                                window.close()
                            }
                        }
                    }
                    // If it's the last window with one tab, do nothing (Chrome behavior)
                }
            }
        }
    }
}

// Tabs on the left of the titlebar, with pleasant leading inset
struct TitlebarTabs: View {
    @EnvironmentObject var aiAssistantManager: AIAssistantManager
    @EnvironmentObject var sessions: ChatSessionsStore
    var body: some View {
        // Chrome-like tabs in dedicated row
        GeometryReader { geometry in
            HStack(alignment: .center, spacing: 0) {
                ChatTabsBar(availableWidth: geometry.size.width)
                    .environmentObject(aiAssistantManager)
            }
        }
        .frame(height: 32) // Match the actual tab height
    }
}

// Mode toggle shown next to tabs in the titlebar
struct TitlebarModeToggle: View {
    @EnvironmentObject var aiAssistantManager: AIAssistantManager
    @EnvironmentObject var authManager: AuthenticationManager
    var body: some View {
        HStack(spacing: 6) {
            Text("Human Type")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white)
            Toggle("", isOn: Binding(get: {
                aiAssistantManager.studentTypingMode
            }, set: { newValue in
                // Free tier: block enabling and show CTA text instead
                if authManager.currentUserTier == .free && newValue {
                    // Keep it off
                    aiAssistantManager.studentTypingMode = false
                    // Append inline CTA text momentarily by toggling a flag via lastAction
                    aiAssistantManager.lastAction = "This is a Pro feature. Try Pro for free today https://blinkapp.ai/pricing"
                } else {
                    aiAssistantManager.studentTypingMode = newValue
                }
            }))
            .toggleStyle(.switch)
            .labelsHidden()
            .scaleEffect(0.7)
            if aiAssistantManager.studentTypingMode {
                Text(aiAssistantManager.typingPaused
                     ? "Human type in progress. Command + Control + Option + R resumes."
                     : "Click Command + Y to start human typing any copied text. Clicking the mouse pauses.")
                    .font(.system(size: 10, weight: .regular))
                    .foregroundColor(.white)
                    .lineLimit(1)
            } else if authManager.currentUserTier == .free, !aiAssistantManager.lastAction.isEmpty {
                Text(aiAssistantManager.lastAction)
                    .font(.system(size: 10, weight: .regular))
                    .foregroundColor(.white)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 12)
        .help("When enabled, AI types like a human student: realistic speed, occasional typos corrected live.")
    }
}

// MARK: - Find Bar
struct FindBar: View {
    @Binding var query: String
    @Binding var matches: [UUID]
    @Binding var index: Int
    let allMessages: [ChatMessage]
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
            TextField("Find in conversation", text: $query)
                .textFieldStyle(.plain)
                .frame(width: 240)
                .foregroundColor(.white)
                .onChange(of: query) { _ in recompute() }
                .onSubmit { findNext() }

            Text("\(matches.isEmpty ? 0 : index + 1)/\(matches.count)")
                .font(.caption)
                .foregroundColor(.secondary)

            Button(action: findPrev) { Image(systemName: "chevron.up") }
                .buttonStyle(.plain)
            Button(action: findNext) { Image(systemName: "chevron.down") }
                .buttonStyle(.plain)
            Divider().frame(height: 14)
            Button(action: onClose) { Image(systemName: "xmark") }
                .buttonStyle(.plain)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.black)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .onAppear(perform: recompute)
    }

    private func recompute() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty {
            matches = []
            index = 0
            return
        }
        matches = allMessages.filter { $0.content.lowercased().contains(q) }.map { $0.id }
        if matches.isEmpty {
            index = 0
        } else {
            // If we just populated matches, reset index and scroll to first match via notification
            let wasEmpty = index >= matches.count
            index = min(index, matches.count - 1)
            if wasEmpty || index == 0 {
                NotificationCenter.default.post(name: .init("ChatFindScrollTo"), object: matches[0])
            }
        }
    }

    private func findNext() { guard !matches.isEmpty else { return }; index = (index + 1) % matches.count }
    private func findPrev() { guard !matches.isEmpty else { return }; index = (index - 1 + matches.count) % matches.count }
}

// MARK: - Chip-style toggle button
struct ToggleChip: View {
    @Binding var isOn: Bool
    let title: String
    let iconOn: String
    let iconOff: String
    
    var body: some View {
        Button(action: { isOn.toggle() }) {
            HStack(spacing: 6) {
                Image(systemName: isOn ? iconOn : iconOff)
                Text(title)
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(isOn ? .white : .primary)
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .background(
                Group {
                    if isOn {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.gray.opacity(0.35))
                    } else {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                    }
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isOn ? Color.white.opacity(0.9) : Color.white.opacity(0.08), lineWidth: isOn ? 1.2 : 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Model selector chip
struct ModelSelectorChip: View {
    @Binding var selectedModel: AIModel
    let researchEnabled: Bool
    @State private var showMenu = false
    @EnvironmentObject var aiAssistantManager: AIAssistantManager
    @EnvironmentObject var authManager: AuthenticationManager
    private var isFree: Bool { authManager.currentUserTier == .free }
    
    var displayText: String {
        selectedModel.displayName
    }
    
    var displayIcon: String {
        selectedModel.icon
    }
    
    var isLocked: Bool {
        !aiAssistantManager.pendingAttachmentPDFs.isEmpty
    }
    
    var body: some View {
        Button(action: { withAnimation(.easeInOut(duration: 0.12)) { showMenu.toggle() } }) {
            HStack(spacing: 6) {
                Image(systemName: displayIcon)
                Text(displayText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(.primary)
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .fixedSize(horizontal: true, vertical: false)
            .background(
                Capsule()
                    .fill(Color.white.opacity(0.06))
            )
            .overlay(
                Capsule()
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help("Select AI model")
        .popover(isPresented: $showMenu) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(AIModel.allCases, id: \.self) { model in
                    Button(action: { handleSelect(model) }) {
                        ModelRow(
                            model: model,
                            isSelected: selectedModel == model,
                            showProBadge: (isFree && model != .gpt4o)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled((isLocked && model != selectedModel) || (isFree && model != .gpt4o))
                }
                if isLocked {
                    Divider().padding(.top, 4)
                    HStack(spacing: 6) {
                        Image(systemName: "lock.fill").font(.system(size: 10, weight: .bold))
                        Text("Model locked while PDF attached")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
                }
                if authManager.currentUserTier == .free {
                    Divider().padding(.vertical, 4)
                    Button(action: {
                        if let url = URL(string: "https://blinkapp.ai/pricing") { NSWorkspace.shared.open(url) }
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "bolt.fill")
                            Text("Unlock GPT‑5, Gemini, Claude — Try Pro for free")
                        }
                        .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .frame(width: 220)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.black.opacity(0.92))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )
        }
    }

    private func handleSelect(_ model: AIModel) {
        if isLocked && model != selectedModel { return }
        if isFree && model != .gpt4o { return }
        selectedModel = model
        showMenu = false
    }

    private struct ModelRow: View {
        let model: AIModel
        let isSelected: Bool
        let showProBadge: Bool

        var body: some View {
            HStack(spacing: 8) {
                Image(systemName: model.icon)
                    .foregroundColor(.primary)
                Text(model.displayName)
                    .foregroundColor(.primary)
                Spacer()
                if showProBadge {
                    Text("Pro")
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.purple.opacity(0.25))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(Color.purple.opacity(0.6), lineWidth: 1)
                        )
                        .cornerRadius(6)
                }
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundColor(.secondary)
                }
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(isSelected ? 0.10 : 0.04))
            )
        }
    }
}





// MARK: - Custom TextField with cursor positioning
struct CustomTextField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    @Binding var shouldFocus: Bool
    let onSubmit: () -> Void
    var onHeightChange: ((CGFloat) -> Void)? = nil
    
    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor.controlBackgroundColor
        scrollView.autohidesScrollers = false
        scrollView.scrollerStyle = .overlay
        
        let textView = NSTextView()
        textView.isRichText = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        // Force visible colors for text
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        textView.textColor = isDark ? NSColor.white : NSColor.black
        textView.insertionPointColor = isDark ? NSColor.white : NSColor.black
        textView.backgroundColor = isDark ? NSColor(calibratedWhite: 0.12, alpha: 1.0) : NSColor.white
        textView.drawsBackground = true
        textView.allowsUndo = true
        textView.delegate = context.coordinator
        textView.textContainerInset = NSSize(width: 0, height: 6)
        if let tc = textView.textContainer {
            tc.widthTracksTextView = true
            tc.containerSize = NSSize(width: scrollView.contentSize.width, height: .greatestFiniteMagnitude)
        }
        
        // Set typing attributes to ensure visible text
        textView.typingAttributes = [
            .foregroundColor: isDark ? NSColor.white : NSColor.black,
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize)
        ]
        
        // Set initial text
                    if text.isEmpty {
                textView.string = placeholder
                textView.textColor = NSColor.placeholderTextColor
            } else {
                textView.string = text
                textView.textColor = isDark ? NSColor.white : NSColor.black
            }
        
        // Set up submit on Enter
        context.coordinator.textView = textView
        context.coordinator.onSubmit = onSubmit
        
        scrollView.documentView = textView
        return scrollView
    }
    
    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        
        // Ensure text view is always editable
        textView.isEditable = true
        textView.isSelectable = true
        
        // Force visible colors for text
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        
        // Ensure typing attributes are set for visible text
        textView.typingAttributes = [
            .foregroundColor: isDark ? NSColor.white : NSColor.black,
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize)
        ]
        
        // Track wrapping width to follow container
        if let tc = textView.textContainer {
            let targetWidth = scrollView.contentSize.width
            if abs(tc.containerSize.width - targetWidth) > 0.5 {
                tc.containerSize = NSSize(width: targetWidth, height: .greatestFiniteMagnitude)
            }
        }

        // Update text if different
        if textView.string != text && !(text.isEmpty && textView.string == placeholder) {
            let wasEmpty = text.isEmpty
            
            if text.isEmpty {
                textView.string = placeholder
                textView.textColor = NSColor.placeholderTextColor
            } else {
                textView.string = text
                textView.textColor = NSColor.textColor
                
                // Apply visible attributes to existing text
                let range = NSRange(location: 0, length: text.count)
                textView.textStorage?.setAttributes([
                    .foregroundColor: isDark ? NSColor.white : NSColor.black,
                    .font: NSFont.systemFont(ofSize: NSFont.systemFontSize)
                ], range: range)
            }
            
            // If we just added text (like from shortcut), position cursor at end
            if !wasEmpty {
                let textLength = text.count
                textView.setSelectedRange(NSRange(location: textLength, length: 0))
            }
        }
        
        // Report content height to SwiftUI for dynamic sizing
        if let lm = textView.layoutManager, let tc = textView.textContainer {
            let used = lm.usedRect(for: tc).size.height + textView.textContainerInset.height * 2
            onHeightChange?(used)
        }

        // Handle focus
        if shouldFocus {
            textView.window?.makeFirstResponder(textView)
            
            // Position cursor at end if there's text
            if !text.isEmpty {
                let textLength = text.count
                textView.setSelectedRange(NSRange(location: textLength, length: 0))
            }
            
            DispatchQueue.main.async {
                shouldFocus = false
            }
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, NSTextViewDelegate {
        let parent: CustomTextField
        var textView: NSTextView?
        var onSubmit: (() -> Void)?
        
        init(_ parent: CustomTextField) {
            self.parent = parent
        }
        
        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            
            // Handle placeholder
            if textView.string == parent.placeholder {
                parent.text = ""
            } else {
                parent.text = textView.string
                
                // Ensure newly typed text is visible
                let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                textView.textColor = isDark ? NSColor.white : NSColor.black
                textView.typingAttributes = [
                    .foregroundColor: isDark ? NSColor.white : NSColor.black,
                    .font: NSFont.systemFont(ofSize: NSFont.systemFontSize)
                ]
            }
        }
        
        func textDidBeginEditing(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            
            // Remove placeholder when editing begins
            if textView.string == parent.placeholder {
                textView.string = ""
                let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                textView.textColor = isDark ? NSColor.white : NSColor.black
                parent.text = ""
            }
        }
        
        func textDidEndEditing(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            
            // Add placeholder if empty
            if textView.string.isEmpty {
                textView.string = parent.placeholder
                textView.textColor = NSColor.placeholderTextColor
            }
        }
        
        // Handle Enter key for submit
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSTextView.insertNewline(_:)) {
                // Check if Shift is held down
                let currentEvent = NSApp.currentEvent
                if currentEvent?.modifierFlags.contains(.shift) == true {
                    // Shift+Enter: insert newline (default behavior)
                    return false
                } else {
                    // Enter: submit
                    onSubmit?()
                    return true
                }
            }
            return false
        }
    }
}

private extension ChatView {
    @ViewBuilder
    var composerArea: some View {
        HStack(alignment: .center, spacing: 8) {
            Button(action: { openAttachmentPicker() }) {
                Image(systemName: "paperclip")
                    .font(.system(size: 14, weight: .medium))
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .opacity(chatViewModel.selectedModel == .claudeHaiku ? 0.5 : 1.0)
            .disabled(chatViewModel.selectedModel == .claudeHaiku)
            .background(GeometryReader { proxy in
                Color.clear.preference(key: AttachWidthKey.self, value: proxy.size.width)
            })

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(NSColor.controlBackgroundColor))
                TextEditor(text: $chatViewModel.currentMessage)
                    .font(.system(size: 14))
                    .padding(.vertical, 8)
                    .padding(.horizontal, 10)
                    .focused($isInputFocused)
                    .background(Color.clear)
                    .scrollContentBackground(.hidden)
                    .onChange(of: chatViewModel.currentMessage) { _ in
                        recomputeComposerHeight()
                        if composerHeight >= composerMaxHeight - 0.5 { scrollComposerCaretIntoView() }
                    }
                    .onAppear { recomputeComposerHeight() }
                    .tint(.white)
                    .overlay(
                        KeyCaptureView(isActive: isInputFocused) { event in
                            if event.keyCode == UInt16(kVK_Return) {
                                if event.modifierFlags.contains(.shift) {
                                    // Allow default newline
                                    return false
                                } else {
                                    handleSend()
                                    return true // consume
                                }
                            }
                            return false
                        }
                        .allowsHitTesting(false)
                    )
                if chatViewModel.currentMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Ask here…")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 10)
                        .offset(x: 4)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: min(max(composerBaseHeight, composerHeight), composerMaxHeight))
            .frame(minWidth: 120, maxWidth: .infinity)
            .layoutPriority(3)
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.gray.opacity(0.18), lineWidth: 1)
                    .allowsHitTesting(false)
            )

            Button(action: { handleSend() }) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.black)
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.white)
                    )
            }
            .buttonStyle(.plain)
            .opacity(((chatViewModel.currentMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && aiAssistantManager.pendingAttachmentImages.isEmpty && aiAssistantManager.pendingAttachmentPDFs.isEmpty) || chatViewModel.isLoading) ? 0.5 : 1.0)
            .disabled((chatViewModel.currentMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && aiAssistantManager.pendingAttachmentImages.isEmpty && aiAssistantManager.pendingAttachmentPDFs.isEmpty) || chatViewModel.isLoading)
            .background(GeometryReader { proxy in
                Color.clear.preference(key: SendWidthKey.self, value: proxy.size.width)
            })
        }
        .frame(maxWidth: .infinity)
        .background(GeometryReader { proxy in
            Color.clear.preference(key: RowWidthKey.self, value: proxy.size.width)
        })
        .onPreferenceChange(RowWidthKey.self) { composerRowWidth = $0; recomputeComposerHeight() }
        .onPreferenceChange(AttachWidthKey.self) { attachButtonWidth = $0 }
        .onPreferenceChange(SendWidthKey.self) { sendButtonWidth = $0 }
        // Force GPT-4o when user is on Free tier
        .onAppear {
            if authManager.currentUserTier == .free { chatViewModel.selectedModel = .gpt4o }
        }
        .onReceive(authManager.$authState) { state in
            switch state {
            case .authenticated(let profile):
                if profile.tier == .free { chatViewModel.selectedModel = .gpt4o }
            default:
                chatViewModel.selectedModel = .gpt4o
            }
        }
    }
    func recomputeComposerHeight() {
        // Approximate intrinsic height based on text line count; TextEditor doesn't expose content height directly
        let minH = composerBaseHeight
        let maxH = composerMaxHeight
        let text = chatViewModel.currentMessage
        let width = max(300.0, Double(composerRowWidth - attachButtonWidth - sendButtonWidth - 56))
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14)
        ]
        let ns = NSString(string: text)
        let rect = ns.boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes
        )
        let contentHeight = ceil(rect.height) + 20
        composerHeight = CGFloat(min(max(Double(minH), Double(contentHeight)), Double(maxH)))
    }
    func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
    // Ensure caret is at end without selecting all, and enable scrolling when needed
    func moveComposerCaretToEnd() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            guard let textView = NSApp.keyWindow?.firstResponder as? NSTextView else { return }
            let length = textView.string.count
            let range = NSRange(location: length, length: 0)
            textView.setSelectedRange(range)
            // Do not scroll inner NSTextView; outer ScrollView controls scrolling
            textView.enclosingScrollView?.hasVerticalScroller = false
        }
    }
    // Keep caret visible after paste/content updates without moving selection
    func scrollComposerCaretIntoView() {
        DispatchQueue.main.async {
            guard let textView = NSApp.keyWindow?.firstResponder as? NSTextView else { return }
            // Avoid inner scroll jumps; outer ScrollView will handle positioning
            textView.enclosingScrollView?.hasVerticalScroller = false
        }
    }
    func handleSend() {
        if !aiAssistantManager.pendingAttachmentPDFs.isEmpty {
            if authManager.currentUserTier == .free {
                // Block PDF sends on free tier
                aiAssistantManager.pendingAttachmentPDFs = []
                chatViewModel.messages.append(ChatMessage(content: "Uploading documents is a Pro feature. Try Pro for free today https://blinkapp.ai/pricing", isUser: false))
                return
            }
            let caption = chatViewModel.currentMessage
            chatViewModel.currentMessage = ""
            let pdfs = aiAssistantManager.pendingAttachmentPDFs
            aiAssistantManager.pendingAttachmentPDFs = []
            chatViewModel.sendPDFsWithCaption(pdfs: pdfs, caption: caption)
        } else if !aiAssistantManager.pendingAttachmentImages.isEmpty || aiAssistantManager.pendingAttachmentImage != nil {
            let caption = chatViewModel.currentMessage
            chatViewModel.currentMessage = ""
            let images = aiAssistantManager.pendingAttachmentImages.isEmpty && aiAssistantManager.pendingAttachmentImage != nil ? [aiAssistantManager.pendingAttachmentImage!] : aiAssistantManager.pendingAttachmentImages
            aiAssistantManager.pendingAttachmentImages = []
            aiAssistantManager.pendingAttachmentImage = nil
            chatViewModel.sendImagesWithCaption(images: images, caption: caption)
        } else if aiAssistantManager.pendingSelectedText != nil {
            let message = chatViewModel.currentMessage
            chatViewModel.currentMessage = ""
            Task { @MainActor in
                await aiAssistantManager.generateFromSelectionAndPasteBack(using: message)
            }
        } else {
            chatViewModel.sendMessage()
        }
    }
    
    func handleDrop(providers: [NSItemProvider]) -> Bool {
        var handledAny = false
        // Collect all images from providers
        let group = DispatchGroup()
        var images: [NSImage] = []
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                handledAny = true
                group.enter()
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    defer { group.leave() }
                    guard let data = data, let img = NSImage(data: data) else { return }
                    images.append(img)
                }
                continue
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handledAny = true
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    defer { group.leave() }
                    guard let url = item as? URL else { return }
                    if let img = NSImage(contentsOf: url) { images.append(img); return }
                    // Non-image payloads handled immediately on main
                    Task { @MainActor in
                        let result = await Self.processDroppedFile(url: url)
                        switch result {
                        case .image(let img):
                            images.append(img)
                        case .text(let text):
                            if chatViewModel.currentMessage.isEmpty { chatViewModel.currentMessage = text } else { chatViewModel.currentMessage += "\n\n" + text }
                        case .pdf(let pdfURL):
                            if authManager.currentUserTier == .free {
                                // Block PDFs on free tier
                                chatViewModel.messages.append(ChatMessage(content: "Uploading documents is a Pro feature. Try Pro for free today https://blinkapp.ai/pricing", isUser: false))
                            } else {
                                aiAssistantManager.pendingAttachmentPDFs.append(pdfURL)
                                // Lock model to Gemini when PDF is attached
                                chatViewModel.selectedModel = .geminiFlash
                            }
                        case .none:
                            break
                        }
                    }
                }
            }
        }
        group.notify(queue: .main) {
            if !images.isEmpty {
                aiAssistantManager.pendingAttachmentImages = images
                aiAssistantManager.pendingAttachmentImage = images.first
            }
        }
        return handledAny
    }
    
    private static func processDroppedFile(url: URL) async -> FileDropResult {
        // Try image first
        if let img = NSImage(contentsOf: url) {
            return .image(img)
        }
        
        // Try text content
        if let text = try? String(contentsOf: url) {
            return .text(text)
        }
        
        // Check if it's a PDF
        if url.pathExtension.lowercased() == "pdf" {
            return .pdf(url)
        }
        
        return .none
    }
    
    private enum FileDropResult {
        case image(NSImage)
        case text(String)
        case pdf(URL)
        case none
    }
    
    func openAttachmentPicker() {
        let panel = NSOpenPanel()
        // On free tier, do not allow selecting PDFs
        if authManager.currentUserTier == .free {
            panel.allowedContentTypes = [UTType.image, .png, .jpeg, .tiff]
        } else {
            panel.allowedContentTypes = [UTType.image, .png, .jpeg, .tiff, .pdf]
        }
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.begin { resp in
            guard resp == .OK else { return }
            let urls = panel.urls
            if urls.isEmpty { return }
            // Separate images and PDFs
            Task.detached {
                var images: [NSImage] = []
                var pdfs: [URL] = []
                
                for url in urls {
                    if url.pathExtension.lowercased() == "pdf" {
                        pdfs.append(url)
                    } else if let image = NSImage(contentsOf: url) {
                        images.append(image)
                    }
                }
                
                await MainActor.run {
                    if !images.isEmpty {
                        aiAssistantManager.pendingAttachmentImages = images
                        aiAssistantManager.pendingAttachmentImage = images.first
                    }
                    if !pdfs.isEmpty {
                        if authManager.currentUserTier == .free {
                            // Block PDFs on free tier
                            chatViewModel.messages.append(ChatMessage(content: "Uploading documents is a Pro feature. Try Pro for free today https://blinkapp.ai/pricing", isUser: false))
                        } else {
                            aiAssistantManager.pendingAttachmentPDFs = pdfs
                            // Lock model to Gemini when PDF is attached
                            chatViewModel.selectedModel = .geminiFlash
                        }
                    }
                }
            }
        }
    }
    
    
}

struct MessageBubble: View {
    let message: ChatMessage
    var highlightQuery: String = ""
    var isSelectedFindMatch: Bool = false
    @EnvironmentObject var aiAssistantManager: AIAssistantManager
    let gridWidth: CGFloat = 270 
    var body: some View {
        HStack {
            if message.isUser { Spacer() }

            VStack(alignment: message.isUser ? .trailing : .leading, spacing: 6) {
                Group {
                    if message.isUser {
                        // For user messages, render content without a surrounding bubble.
                        // Bubble styling is applied only to the caption text inside userContent.
                        userContent
                            .frame(maxWidth: 800, alignment: .trailing)
                    } else {
                        FormattedAIText(text: message.content, highlight: normalizedHighlight())
                            .padding(8)
                            .frame(maxWidth: 800, alignment: .leading)
                            .tint(.primary)
                    }
                }
                .overlay(alignment: .leading) {
                    if isSelectedFindMatch {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.accentColor.opacity(0.8), lineWidth: 2)
                            .padding(-1)
                    }
                }

                HStack(spacing: 6) {
                    Text(formatTime(message.timestamp))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    if message.isUser {
                        Button(action: {
                            NotificationCenter.default.post(name: .init("ChatBeginEditMessage"), object: message)
                        }) {
                            Image(systemName: "square.and.pencil")
                                .font(.system(size: 10, weight: .regular))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Edit and resend from here")
                    }
                }
            }

            if !message.isUser { Spacer() }
        }
        .frame(maxWidth: .infinity, alignment: message.isUser ? .trailing : .leading)
    }
    
    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func copyToPasteboard(_ text: String) {}
    private func sendFollowUp(_ text: String) {}

    private func linkedAttributedString(_ string: String) -> AttributedString { AttributedString(string) }

    @ViewBuilder
    private var userContent: some View {
        if let pdfs = message.attachmentPDFs, !pdfs.isEmpty {
            VStack(alignment: .trailing, spacing: 6) {
                // Show PDF attachments
                let pdfThumbW: CGFloat = 60
                let pdfThumbH: CGFloat = 80
                let spacing: CGFloat = 6
                let colCount = max(1, min(pdfs.count, 3))
                let gridWidth: CGFloat = CGFloat(colCount) * pdfThumbW + CGFloat(max(0, colCount - 1)) * spacing
                let columns = Array(repeating: GridItem(.fixed(pdfThumbW), spacing: spacing), count: colCount)
                LazyVGrid(columns: columns, alignment: .trailing, spacing: spacing) {
                    ForEach(Array(pdfs.enumerated()), id: \.offset) { _, pdfURL in
                        VStack(spacing: 4) {
                            Image(systemName: "doc.fill")
                                .font(.title)
                                .foregroundColor(.red)
                            Text(pdfURL.lastPathComponent)
                                .font(.system(size: 8, weight: .medium))
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                        }
                        .frame(width: pdfThumbW, height: pdfThumbH)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.red.opacity(0.1))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.25), lineWidth: 1)
                        )
                    }
                }
                .frame(width: gridWidth, alignment: .trailing)
                .fixedSize(horizontal: false, vertical: true)
                if !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(message.content)
                        .font(.system(size: 12))
                        .foregroundColor(.primary)
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color.white.opacity(0.09))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(Color.white.opacity(0.12), lineWidth: 1)
                        )
                        .textSelection(.enabled)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        } else if let datas = message.attachmentDatas, !datas.isEmpty {
            VStack(alignment: .trailing, spacing: 6) {
                // Images in their own container
                VStack(alignment: .trailing, spacing: 6) {
                    // Left-aligned very small thumbnails. Grid width adapts to actual column count to keep the block hugging the right edge.
                    let thumbW: CGFloat = 64
                    let thumbH: CGFloat = 48
                    let spacing: CGFloat = 6
                    let colCount = max(1, min(datas.count, 4))
                    let gridWidth: CGFloat = CGFloat(colCount) * thumbW + CGFloat(max(0, colCount - 1)) * spacing
                    let columns = Array(repeating: GridItem(.fixed(thumbW), spacing: spacing), count: colCount)
                    LazyVGrid(columns: columns, alignment: .trailing, spacing: spacing) {
                        ForEach(Array(datas.enumerated()), id: \.offset) { _, d in
                            if let image = cachedImage(from: d) {
                                Image(nsImage: image)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: thumbW, height: thumbH)
                                    .clipped()
                                    .cornerRadius(6)
                            } else {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.gray.opacity(0.3))
                                    .frame(width: thumbW, height: thumbH)
                            }
                        }
                    }
                    .frame(width: gridWidth, alignment: .trailing)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                
                // Text in its own container with full width
                if !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(message.content)
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                        .frame(maxWidth: 800, alignment: .trailing)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        } else if let data = message.attachmentData {
            // Fallback single image
            if let image = cachedImage(from: data) {
                VStack(alignment: .trailing, spacing: 6) {
                    // Image in its own container
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 120, alignment: .trailing)
                        .cornerRadius(6)
                        .clipped()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    
                    // Text in its own container with full width
                    if !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(message.content)
                            .multilineTextAlignment(.trailing)
                            .textSelection(.enabled)
                            .frame(maxWidth: 800, alignment: .trailing)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 120, height: 90)
                    .overlay(ProgressView().scaleEffect(0.8))
            }
        } else {
            if normalizedHighlight().isEmpty {
                Text(message.content)
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
            } else {
                // Highlight occurrences in user text using AttributedString
                AttributedText(text: message.content, highlight: normalizedHighlight())
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
            }
        }
    }
    
    private func cachedImage(from data: Data) -> NSImage? {
        // Simple caching mechanism to avoid recreating NSImage repeatedly
        if let cached = ImageCache.shared.image(for: data) {
            return cached
        }
        
        let image = NSImage(data: data)
        if let image = image {
            ImageCache.shared.setImage(image, for: data)
        }
        return image
    }

    private func normalizedHighlight() -> String {
        let q = highlightQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return q
    }

    
}

// Simple attributed text that highlights matches for user messages
struct AttributedText: View {
    let text: String
    let highlight: String

    var body: some View {
        Text(make())
            .textSelection(.enabled)
    }

    private func make() -> AttributedString {
        let mutable = NSMutableAttributedString(string: text)
        if !highlight.isEmpty {
            let ns = text as NSString
            var search = NSRange(location: 0, length: ns.length)
            while true {
                let range = ns.range(of: highlight, options: [.caseInsensitive], range: search)
                if range.location == NSNotFound { break }
                mutable.addAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.35), range: range)
                let next = range.location + range.length
                if next >= ns.length { break }
                search = NSRange(location: next, length: ns.length - next)
            }
        }
        return AttributedString(mutable)
    }
}

// MARK: - Inline Linked Text (badge-style links inline)
struct InlineLinkedText: View {
    let content: String

    var body: some View {
        let parts = tokenize(content)
        return HStack(alignment: .firstTextBaseline, spacing: 4) {
            ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                switch part {
                case .text(let t):
                    Text(t)
                        .font(.system(size: 15, weight: .light))
                case .link(let label, let urlString):
                    if let url = URL(string: urlString) {
                        Link(destination: url) {
                            HStack(spacing: 6) {
                                Image(systemName: "link")
                                    .font(.system(size: 10, weight: .bold))
                                Text(label)
                                    .font(.system(size: 11, weight: .bold))
                            }
                            .foregroundColor(.primary)
                            .padding(.vertical, 2)
                            .padding(.horizontal, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(Color.white.opacity(0.10))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .stroke(Color.white.opacity(0.14), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                    } else {
                        Text(label)
                            .font(.system(size: 15, weight: .light))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private enum Part { case text(String), link(String, String) }

    private func tokenize(_ s: String) -> [Part] {
        var parts: [Part] = []
        let ns = s as NSString
        let fullRange = NSRange(location: 0, length: ns.length)
        var consumed = 0

        // First collect markdown links
        let mdPattern = #"\[(.+?)\]\((https?:[^\)\s]+)\)"#
        let mdRegex = try? NSRegularExpression(pattern: mdPattern, options: [])
        let mdMatches = mdRegex?.matches(in: s, options: [], range: fullRange) ?? []
        var mdRanges: [NSRange] = []
        for m in mdMatches { mdRanges.append(m.range) }

        // Merge markdown and bare URLs; process in-order
        var pointer = 0
        while pointer < ns.length {
            // If next md match starts here
            if let nextMD = mdRanges.first, nextMD.location == pointer {
                if let m = mdMatches.first(where: { $0.range.location == nextMD.location }) {
                    let label = ns.substring(with: m.range(at: 1))
                    let url = ns.substring(with: m.range(at: 2))
                    parts.append(.link(label, url))
                    pointer = nextMD.location + nextMD.length
                    mdRanges.removeFirst()
                    continue
                }
            }
            // Check for bare URL at pointer
            if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
                let range = NSRange(location: pointer, length: ns.length - pointer)
                if let m = detector.firstMatch(in: s, options: [.anchored], range: range), let url = m.url {
                    let host = url.host ?? url.absoluteString
                    let label = host.replacingOccurrences(of: "www.", with: "")
                    parts.append(.link(label, url.absoluteString))
                    pointer = m.range.location + m.range.length
                    continue
                }
            }
            // Otherwise, append one character of text and advance
            let chRange = NSRange(location: pointer, length: 1)
            parts.append(.text(ns.substring(with: chRange)))
            pointer += 1
        }
        // Coalesce adjacent text parts
        var coalesced: [Part] = []
        for p in parts {
            if case .text(let t) = p, case .text(let lastT)? = coalesced.last {
                coalesced.removeLast()
                coalesced.append(.text(lastT + t))
            } else {
                coalesced.append(p)
            }
        }
        return coalesced
    }
}



#Preview {
    ContentView()
}

// Preference key to track composer intrinsic height inside ScrollView
private struct ComposerHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 48
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// Force overlay scrollers to show when the inner content exceeds the frame
private struct ScrollIndicatorsConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        // Ensure the window uses overlay scrollbars so indicators appear
        NSApp.appearance = NSApp.appearance // no-op to keep compiler happy; overlay is system controlled
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        // Find enclosing NSScrollView and force indicators on
        if let scrollView = nsView.enclosingScrollView {
            scrollView.hasVerticalScroller = true
            scrollView.autohidesScrollers = false
            scrollView.scrollerStyle = .overlay
        } else {
            // Walk up the hierarchy to find a scroll view
            var ancestor: NSView? = nsView.superview
            while let a = ancestor {
                if let sv = a as? NSScrollView {
                    sv.hasVerticalScroller = true
                    sv.autohidesScrollers = false
                    sv.scrollerStyle = .overlay
                    break
                }
                ancestor = a.superview
            }
        }
    }
}

// Width preference keys to keep the composer stretch in sync with window resizing
private struct RowWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
private struct AttachWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
private struct SendWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct KeyCaptureView: NSViewRepresentable {
    let isActive: Bool
    let handler: (NSEvent) -> Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.wantsLayer = false
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.isActive = isActive
        context.coordinator.handler = handler
        if context.coordinator.monitor == nil {
            context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
                guard context.coordinator.isActive else { return event }
                if handler(event) { return nil }
                return event
            }
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let mon = coordinator.monitor { NSEvent.removeMonitor(mon) }
        coordinator.monitor = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator {
        var monitor: Any?
        var isActive: Bool = false
        var handler: (NSEvent) -> Bool = { _ in false }
    }
}
