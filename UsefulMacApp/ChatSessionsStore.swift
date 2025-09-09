//
//  ChatSessionsStore.swift
//  UsefulMacApp
//
//  Created by AI on 8/30/25.
//

import Foundation
import Combine

@MainActor
final class ChatSessionsStore: ObservableObject {
    struct Session: Identifiable {
        let id: UUID
        var title: String
        let viewModel: ChatViewModel
        var createdAt: Date
        var updatedAt: Date
    }
    struct SessionSummary: Identifiable {
        let id: UUID
        let title: String
        let updatedAt: Date
    }

    @Published private(set) var sessions: [Session] = []
    @Published var activeSessionId: UUID
    // Published snapshot of all stored history summaries for instant UI updates
    @Published var storedSummaries: [SessionSummary] = []
    // Debounced/published results for history popover live search
    @Published var historySearchResults: [SessionSummary] = []
    // When set, views should scroll to this message id then clear it
    @Published var pendingScrollTargetMessageId: UUID?

    private var cancellables: [UUID: AnyCancellable] = [:]
    private let persistence = SessionsPersistence()
    // Debounced, background persistence to avoid UI hitches on frequent updates
    private let persistQueue = DispatchQueue(label: "ChatSessionsStore.persist", qos: .utility)
    private var persistWorkItem: DispatchWorkItem?
    private let persistDebounceSeconds: TimeInterval = 0.5
    // Background queue and work item for debounced history search
    private let searchQueue = DispatchQueue(label: "ChatSessionsStore.search", qos: .userInitiated)
    private var searchWorkItem: DispatchWorkItem?
    // In-memory cache of stored sessions to avoid disk reads during search
    private var storedCache: [SessionsPersistence.StoredSession] = []

    init(initialTitle: String = "New Chat", startFresh: Bool = false) {
        if !startFresh, let restored = persistence.restore() {
            self.sessions = restored.sessions.map { stored in
                let vm = ChatViewModel(messages: stored.messages)
                return Session(id: stored.id, title: stored.title, viewModel: vm, createdAt: stored.createdAt, updatedAt: stored.updatedAt)
            }
            self.activeSessionId = restored.activeId ?? restored.sessions.first?.id ?? UUID()
            for s in sessions { observe(viewModel: s.viewModel, for: s.id) }
            reloadStoredSummaries()
            // Initialize search results to full list
            self.historySearchResults = self.storedSummaries
        } else {
            let vm = ChatViewModel()
            let now = Date()
            let session = Session(id: UUID(), title: initialTitle, viewModel: vm, createdAt: now, updatedAt: now)
            self.sessions = [session]
            self.activeSessionId = session.id
            observe(viewModel: vm, for: session.id)
            persist()
            reloadStoredSummaries()
            self.historySearchResults = self.storedSummaries
        }
    }

    var activeSession: Session? {
        sessions.first(where: { $0.id == activeSessionId })
    }

    var activeViewModel: ChatViewModel {
        activeSession?.viewModel ?? sessions[0].viewModel
    }

    func newSession(title: String = "New Chat") -> Session {
        let vm = ChatViewModel()
        let now = Date()
        let session = Session(id: UUID(), title: title, viewModel: vm, createdAt: now, updatedAt: now)
        sessions.insert(session, at: 0)
        activeSessionId = session.id
        observe(viewModel: vm, for: session.id)
        persist()
        return session
    }

    func closeSession(id: UUID) {
        // Prevent removing the last session
        guard sessions.count > 1 else { return }
        cancellables[id]?.cancel()
        cancellables[id] = nil
        sessions.removeAll { $0.id == id }
        if activeSessionId == id { activeSessionId = sessions.first?.id ?? UUID() }
        persist()
    }

    func switchTo(id: UUID) {
        activeSessionId = id
        persist()
    }

    func rename(id: UUID, to title: String) {
        if let idx = sessions.firstIndex(where: { $0.id == id }) {
            sessions[idx].title = title
            persist()
        }
    }

    func historySorted() -> [Session] {
        sessions.sorted { $0.updatedAt > $1.updatedAt }
    }

    func deleteSession(_ id: UUID) {
        closeSession(id: id)
    }

    private func observe(viewModel: ChatViewModel, for id: UUID) {
        // Only react to finalized message list changes, not every keystroke in currentMessage
        cancellables[id] = viewModel.$messages
            .receive(on: DispatchQueue.main)
            .debounce(for: .milliseconds(250), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self, let idx = self.sessions.firstIndex(where: { $0.id == id }) else { return }
                self.sessions[idx].updatedAt = Date()
                // Auto-title based on first user message
                if self.sessions[idx].title == "New Chat" {
                    if let firstUser = viewModel.messages.first(where: { $0.isUser }) {
                        let trimmed = firstUser.content.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            self.sessions[idx].title = String(trimmed.prefix(40))
                        }
                    }
                }
                self.persist()
            }
    }

    private func persist() {
        // Debounce and offload disk IO to background queue
        persistWorkItem?.cancel()

        // Capture a lightweight snapshot on main actor
        let snapshotSessions: [SessionsPersistence.StoredSession] = sessions.compactMap { s in
            let hasUserMessage = s.viewModel.messages.contains { $0.isUser }
            guard hasUserMessage else { return nil }
            return SessionsPersistence.StoredSession(
                id: s.id,
                title: s.title,
                messages: s.viewModel.messages,
                createdAt: s.createdAt,
                updatedAt: s.updatedAt
            )
        }
        let snapshotActiveId = activeSessionId

        let work = DispatchWorkItem { [persistence] in
            // Merge with existing stored history so other windows are preserved
            var byId: [UUID: SessionsPersistence.StoredSession] = [:]
            if let existing = persistence.restore() {
                for s in existing.sessions { byId[s.id] = s }
            }
            for s in snapshotSessions { byId[s.id] = s }
            let merged = SessionsPersistence.Stored(
                sessions: Array(byId.values),
                activeId: snapshotActiveId
            )
            persistence.save(merged)
            // Refresh summaries on main thread after save
            DispatchQueue.main.async { [weak self] in self?.reloadStoredSummaries() }
        }

        persistWorkItem = work
        persistQueue.asyncAfter(deadline: .now() + persistDebounceSeconds, execute: work)
    }

    // Open a conversation from persisted history into this window's tabs
    func openFromHistory(id: UUID) {
        guard !sessions.contains(where: { $0.id == id }) else {
            switchTo(id: id)
            return
        }
        guard let stored = persistence.restore()?.sessions.first(where: { $0.id == id }) else { return }
        let vm = ChatViewModel(messages: stored.messages)
        let session = Session(id: stored.id, title: stored.title, viewModel: vm, createdAt: stored.createdAt, updatedAt: stored.updatedAt)
        sessions.insert(session, at: 0)
        activeSessionId = session.id
        observe(viewModel: vm, for: session.id)
        persist()
    }

    // Stored history summaries (all past conversations), sorted by recency
    func allStoredSummaries() -> [SessionSummary] {
        let stored = storedCache
        return stored
            .sorted { $0.updatedAt > $1.updatedAt }
            .map { SessionSummary(id: $0.id, title: $0.title, updatedAt: $0.updatedAt) }
    }

    // Permanently delete a conversation from storage (and current window if present)
    func deleteStored(id: UUID) {
        if sessions.contains(where: { $0.id == id }) {
            closeSession(id: id)
        }
        guard var existing = persistence.restore() else { return }
        existing = SessionsPersistence.Stored(
            sessions: existing.sessions.filter { $0.id != id },
            activeId: existing.activeId == id ? nil : existing.activeId
        )
        persistence.save(existing)
        reloadStoredSummaries()
    }

    // Live snapshot of stored history for UI
    private func reloadStoredSummaries() {
        let stored = persistence.restore()?.sessions ?? []
        // Refresh cache for fast searches
        self.storedCache = stored
        self.storedSummaries = stored
            .sorted { $0.updatedAt > $1.updatedAt }
            .map { SessionSummary(id: $0.id, title: $0.title, updatedAt: $0.updatedAt) }
        // If no active query, keep search results in sync with all summaries
        if (searchWorkItem == nil) {
            self.historySearchResults = self.storedSummaries
        }
    }

    // Search across titles and message contents in stored history
    func searchStoredSummaries(query: String) -> [SessionSummary] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return storedSummaries }
        let lower = trimmed.lowercased()
        let stored = storedCache
        return stored
            .filter { s in
                if s.title.lowercased().contains(lower) { return true }
                return s.messages.contains { $0.content.lowercased().contains(lower) }
            }
            .sorted { $0.updatedAt > $1.updatedAt }
            .map { SessionSummary(id: $0.id, title: $0.title, updatedAt: $0.updatedAt) }
    }

    // Find the first message id in a stored conversation that matches query (title or content)
    func firstMatchingMessageId(inStored id: UUID, query: String) -> UUID? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()
        guard let stored = storedCache.first(where: { $0.id == id }) else { return nil }
        if stored.title.lowercased().contains(lower) {
            // If title matched, prefer first user message as an anchor; else first message
            return stored.messages.first(where: { $0.isUser })?.id ?? stored.messages.first?.id
        }
        return stored.messages.first(where: { $0.content.lowercased().contains(lower) })?.id
    }

    // MARK: - Debounced background history search
    func updateHistorySearch(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // Cancel any pending work
        searchWorkItem?.cancel()
        if trimmed.isEmpty {
            // Immediate reset to full list on main
            self.historySearchResults = self.storedSummaries
            return
        }
        let lower = trimmed.lowercased()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            let results: [SessionSummary] = self.storedCache
                .filter { s in
                    if s.title.lowercased().contains(lower) { return true }
                    return s.messages.contains { $0.content.lowercased().contains(lower) }
                }
                .sorted { $0.updatedAt > $1.updatedAt }
                .map { SessionSummary(id: $0.id, title: $0.title, updatedAt: $0.updatedAt) }
            DispatchQueue.main.async { [weak self] in
                self?.historySearchResults = results
            }
        }
        searchWorkItem = work
        searchQueue.asyncAfter(deadline: .now() + 0.15, execute: work)
    }
}

// MARK: - Persistence
private struct SessionsPersistence {
    struct Stored: Codable {
        let sessions: [StoredSession]
        let activeId: UUID?
    }
    struct StoredSession: Codable {
        let id: UUID
        let title: String
        let messages: [ChatMessage]
        let createdAt: Date
        let updatedAt: Date
    }

    private let fm = FileManager.default
    private var url: URL {
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = dir.appendingPathComponent("UsefulMacApp", isDirectory: true)
        if !fm.fileExists(atPath: appDir.path) {
            try? fm.createDirectory(at: appDir, withIntermediateDirectories: true)
        }
        return appDir.appendingPathComponent("chat_sessions.json")
    }

    func save(_ stored: Stored) {
        do {
            let data = try JSONEncoder().encode(stored)
            try data.write(to: url, options: [.atomic])
        } catch {
            print("Failed to save sessions: \(error)")
        }
    }

    func restore() -> Stored? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Stored.self, from: data)
    }
}


