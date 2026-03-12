//
//  ChatThreadManager.swift
//  Doufu
//

import Foundation

@MainActor
protocol ChatThreadManagerDelegate: AnyObject {
    func threadManagerDidSwitchThread()
    func threadManagerDidEncounterError(_ error: Error)
    /// Called before persisting current state (e.g. thread switch) so the
    /// session can flush any pending debounced persistence.
    func threadManagerWillPersistCurrentState()
}

@MainActor
final class ChatThreadManager {

    weak var delegate: ChatThreadManagerDelegate?

    private(set) var threadIndex: ProjectChatThreadIndex?
    private(set) var currentThread: ProjectChatThreadRecord?
    private(set) var sessionMemory: SessionMemory?

    private let dataService: ChatDataService
    private let messageStore: ChatMessageStore
    private let modelSelection: ChatModelSelectionManager
    private let isExecutingProvider: () -> Bool

    init(
        dataService: ChatDataService,
        messageStore: ChatMessageStore,
        modelSelection: ChatModelSelectionManager,
        isExecutingProvider: @escaping () -> Bool
    ) {
        self.dataService = dataService
        self.messageStore = messageStore
        self.modelSelection = modelSelection
        self.isExecutingProvider = isExecutingProvider
    }

    // MARK: - Thread Lifecycle

    func restoreThreadStateIfNeeded() throws {
        threadIndex = try dataService.loadThreadIndex()
        if let currentThreadID = threadIndex?.currentThreadID {
            try switchToThread(threadID: currentThreadID)
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

    func createAndSwitchThread() {
        guard !isExecutingProvider() else { return }
        do {
            try persistCurrentState()
            _ = try dataService.createThread(title: nil)
            threadIndex = try dataService.loadThreadIndex()
            guard let currentThreadID = threadIndex?.currentThreadID else {
                throw ChatProviderError.noThreadAvailable
            }
            try switchToThread(threadID: currentThreadID)
        } catch {
            delegate?.threadManagerDidEncounterError(error)
        }
    }

    private func switchToThread(threadID: String) throws {
        try persistCurrentState()

        let result = try dataService.switchThread(threadID: threadID)
        threadIndex = try dataService.loadThreadIndex()
        currentThread = result.thread
        sessionMemory = result.memory

        modelSelection.reloadModelSelectionContext(triggerModelRefresh: false)

        messageStore.replaceMessages(result.messages)
        delegate?.threadManagerDidSwitchThread()
    }

    // MARK: - Session Memory

    func updateSessionMemory(_ memory: SessionMemory?) {
        sessionMemory = memory
        do {
            try persistSessionMemory()
        } catch {
            delegate?.threadManagerDidEncounterError(error)
        }
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

    func reloadIndex() {
        do {
            let newIndex = try dataService.loadThreadIndex()
            threadIndex = newIndex

            // If the previous current thread was deleted, clear it so that
            // switchToThread → persistCurrentState does not write orphan data.
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

    // MARK: - Private

    private func persistCurrentState() throws {
        guard let currentThread else { return }
        // Flush any debounced persistence from the session first, then
        // perform a full write to guarantee nothing is lost.
        delegate?.threadManagerWillPersistCurrentState()
        try dataService.persistMessages(messageStore.messages, threadID: currentThread.id)
        modelSelection.persistCurrentModelSelection()
        try dataService.persistSessionMemory(sessionMemory, threadID: currentThread.id)
    }

    private func persistSessionMemory() throws {
        guard let currentThread else { return }
        try dataService.persistSessionMemory(sessionMemory, threadID: currentThread.id)
    }
}
