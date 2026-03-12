//
//  ChatThreadManager.swift
//  Doufu
//

import Foundation

@MainActor
protocol ChatThreadManagerDelegate: AnyObject {
    func threadManagerDidSwitchThread()
    func threadManagerDidEncounterError(_ error: Error)
    /// Called before switching threads so the session can persist all
    /// current state (messages, session memory, model selection).
    func threadManagerWillSwitchThread()
    /// Called after loading a thread's data so the session can update
    /// messageStore and modelSelection without ThreadManager owning them.
    func threadManagerDidLoadThread(messages: [ChatMessage], memory: SessionMemory?)
}

@MainActor
final class ChatThreadManager {

    weak var delegate: ChatThreadManagerDelegate?

    private(set) var threadIndex: ProjectChatThreadIndex?
    private(set) var currentThread: ProjectChatThreadRecord?
    private(set) var sessionMemory: SessionMemory?

    private let dataService: ChatDataService
    private let isExecutingProvider: () -> Bool

    init(
        dataService: ChatDataService,
        isExecutingProvider: @escaping () -> Bool
    ) {
        self.dataService = dataService
        self.isExecutingProvider = isExecutingProvider
    }

    // MARK: - Thread Lifecycle

    func restoreThreadStateIfNeeded() throws {
        // Fast path: session survives UI dismissal — thread state already loaded.
        if currentThread != nil { return }

        if let index = try dataService.loadThreadIndex() {
            threadIndex = index
            try switchToThread(threadID: index.currentThreadID)
        } else {
            // Ensure chat always has a concrete thread once the page is opened,
            // so thread management actions are meaningful immediately.
            try createInitialThread()
        }
    }

    func handleSwitchThread(threadID: String) {
        guard !isExecutingProvider() else { return }
        do {
            try switchToThread(threadID: threadID)
        } catch {
            delegate?.threadManagerDidEncounterError(error)
        }
    }

    /// Creates the first thread without triggering willSwitch (no prior state to persist).
    /// Used when sending a message with no thread yet.
    func createInitialThread() throws {
        let thread = try dataService.createThread(title: nil)
        threadIndex = try dataService.loadOrCreateThreadIndex()
        currentThread = thread
        sessionMemory = nil
    }

    func createAndSwitchThread() {
        guard !isExecutingProvider() else { return }
        do {
            delegate?.threadManagerWillSwitchThread()
            _ = try dataService.createThread(title: nil)
            let index = try dataService.loadOrCreateThreadIndex()
            threadIndex = index
            try switchToThread(threadID: index.currentThreadID)
        } catch {
            delegate?.threadManagerDidEncounterError(error)
        }
    }

    private func switchToThread(threadID: String) throws {
        delegate?.threadManagerWillSwitchThread()

        let result = try dataService.switchThread(threadID: threadID)
        threadIndex = try dataService.loadOrCreateThreadIndex()
        currentThread = result.thread
        sessionMemory = result.memory

        delegate?.threadManagerDidLoadThread(messages: result.messages, memory: result.memory)
        delegate?.threadManagerDidSwitchThread()
    }

    // MARK: - Session Memory

    func updateSessionMemory(_ memory: SessionMemory?) {
        sessionMemory = memory
    }

    // MARK: - Thread Metadata

    func touchCurrentThread() {
        guard let currentThread else { return }
        do {
            try dataService.touchThread(threadID: currentThread.id)
            if var index = threadIndex {
                if let threadIdx = index.threads.firstIndex(where: { $0.id == currentThread.id }) {
                    index.threads[threadIdx].updatedAt = Date()
                    threadIndex = index
                }
            }
        } catch {
            delegate?.threadManagerDidEncounterError(error)
        }
    }

    // MARK: - Thread Management (rename / delete / reorder)

    func renameThread(threadID: String, newTitle: String) throws {
        try dataService.renameThread(threadID: threadID, newTitle: newTitle)
        if var index = threadIndex,
           let idx = index.threads.firstIndex(where: { $0.id == threadID }) {
            index.threads[idx].title = newTitle
            threadIndex = index
        }
    }

    func deleteThread(threadID: String) throws {
        try dataService.deleteThread(threadID: threadID)
        threadIndex = try dataService.loadOrCreateThreadIndex()
        // If we deleted the current thread, switch to the new current.
        if currentThread?.id == threadID {
            currentThread = nil
            if let newCurrentID = threadIndex?.currentThreadID {
                try switchToThread(threadID: newCurrentID)
            }
        }
    }

    func reorderThreads(orderedIDs: [String]) throws {
        try dataService.reorderThreads(orderedIDs: orderedIDs)
        // Re-sort the in-memory index to match.
        if var index = threadIndex {
            let idOrder = Dictionary(uniqueKeysWithValues: orderedIDs.enumerated().map { ($1, $0) })
            index.threads.sort { (idOrder[$0.id] ?? .max) < (idOrder[$1.id] ?? .max) }
            threadIndex = index
        }
    }

    func reloadIndex() {
        do {
            let newIndex = try dataService.loadOrCreateThreadIndex()
            threadIndex = newIndex

            // If the previous current thread was deleted, clear it so that
            // switchToThread does not persist orphan data.
            if let oldThread = currentThread,
               !newIndex.threads.contains(where: { $0.id == oldThread.id }) {
                currentThread = nil
            }

            let currentThreadID = newIndex.currentThreadID
            if currentThreadID != currentThread?.id {
                try switchToThread(threadID: currentThreadID)
            } else {
                currentThread = newIndex.threads.first(where: { $0.id == currentThreadID })
            }
        } catch {
            delegate?.threadManagerDidEncounterError(error)
        }
    }

}
