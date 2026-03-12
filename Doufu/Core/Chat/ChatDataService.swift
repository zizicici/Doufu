//
//  ChatDataService.swift
//  Doufu
//

import Foundation

/// Per-project data service that wraps `ChatDataStore` and provides
/// automatic persistence. Each `ChatDataService` instance is bound
/// to a single `projectID`.
@MainActor
final class ChatDataService {

    let projectID: String
    private let dataStore: ChatDataStore

    init(projectID: String, dataStore: ChatDataStore = .shared) {
        self.projectID = projectID
        self.dataStore = dataStore
    }

    // MARK: - Thread Operations

    /// Pure read — returns `nil` when no threads exist yet.
    func loadThreadIndex() throws -> ProjectChatThreadIndex? {
        try dataStore.loadIndex(projectID: projectID)
    }

    /// Loads the thread index, creating an initial thread if none exist.
    func loadOrCreateThreadIndex() throws -> ProjectChatThreadIndex {
        try dataStore.loadOrCreateIndex(projectID: projectID)
    }

    func switchThread(threadID: String) throws -> (
        thread: ProjectChatThreadRecord,
        messages: [ChatMessage],
        memory: SessionMemory?
    ) {
        let thread = try dataStore.switchCurrentThread(projectID: projectID, threadID: threadID)
        let messages = try dataStore.loadMessages(projectID: projectID, threadID: threadID)
        let memory = try dataStore.loadSessionMemory(projectID: projectID, threadID: threadID)

        // Initialize persisted count so subsequent incremental saves
        // know how many rows already exist in DB for this thread.
        persistedCountByThread[threadID] = messages.count

        return (thread, messages, memory)
    }

    func createThread(title: String?) throws -> ProjectChatThreadRecord {
        try dataStore.createThread(projectID: projectID, title: title, makeCurrent: true)
    }

    // MARK: - Auto-Persistence

    /// Number of messages known to be persisted for the current thread.
    /// Used by ``persistMessagesIncrementally`` to skip unchanged rows.
    private var persistedCountByThread: [String: Int] = [:]

    /// The maximum number of trailing rows to re-write when doing an
    /// incremental save, covering the messages most likely to have been
    /// updated (finishedAt, tokenUsage, toolSummary, text).
    private static let incrementalTailWindow = 3

    /// Full-replace persistence (DELETE ALL + INSERT ALL).
    /// Used before thread switches where we need a clean, authoritative write.
    func persistMessages(_ messages: [ChatMessage], threadID: String) throws {
        let filtered = filteredMessages(messages)
        try dataStore.saveMessages(projectID: projectID, threadID: threadID, messages: filtered)
        persistedCountByThread[threadID] = filtered.count
    }

    /// Incremental persistence that avoids rewriting the entire table.
    /// Only UPDATEs the trailing rows that may have changed and INSERTs
    /// any new messages.  Falls back to full-replace when the message
    /// list shrank (rare: should not happen in normal append-only flow).
    func persistMessagesIncrementally(_ messages: [ChatMessage], threadID: String) throws {
        let filtered = filteredMessages(messages)
        let previousCount = persistedCountByThread[threadID] ?? 0

        // Fall back to full-replace if the list shrank (e.g. unexpected
        // state) — incremental delete logic is handled inside the store
        // but a full replace is simpler and this path is rare.
        if filtered.count < previousCount {
            try dataStore.saveMessages(projectID: projectID, threadID: threadID, messages: filtered)
            persistedCountByThread[threadID] = filtered.count
            return
        }

        let unchangedPrefix = max(0, previousCount - Self.incrementalTailWindow)
        try dataStore.saveMessagesIncrementally(
            projectID: projectID,
            threadID: threadID,
            messages: filtered,
            unchangedPrefixCount: unchangedPrefix
        )
        persistedCountByThread[threadID] = filtered.count
    }

    /// Reset persisted count tracking (e.g. after loading a thread from DB).
    func resetPersistedCount(threadID: String, count: Int) {
        persistedCountByThread[threadID] = count
    }

    func persistSessionMemory(_ memory: SessionMemory?, threadID: String) throws {
        try dataStore.saveSessionMemory(projectID: projectID, threadID: threadID, memory: memory)
    }

    // MARK: - Helpers

    /// Filter out messages with empty content before persisting.
    private func filteredMessages(_ messages: [ChatMessage]) -> [ChatMessage] {
        messages.filter { !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    func touchThread(threadID: String) throws {
        try dataStore.touchThread(projectID: projectID, threadID: threadID)
    }

    func renameThread(threadID: String, newTitle: String) throws {
        try dataStore.renameThread(projectID: projectID, threadID: threadID, newTitle: newTitle)
    }

    func deleteThread(threadID: String) throws {
        try dataStore.deleteThread(projectID: projectID, threadID: threadID)
    }

    func reorderThreads(orderedIDs: [String]) throws {
        try dataStore.reorderThreads(projectID: projectID, orderedIDs: orderedIDs)
    }
}
