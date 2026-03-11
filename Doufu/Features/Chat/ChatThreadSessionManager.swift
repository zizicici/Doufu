//
//  ChatThreadSessionManager.swift
//  Doufu
//

import Foundation

@MainActor
protocol ChatThreadSessionManagerDelegate: AnyObject {
    func threadSessionDidSwitchThread()
    func threadSessionDidEncounterError(_ error: Error)
}

@MainActor
final class ChatThreadSessionManager {

    weak var delegate: ChatThreadSessionManagerDelegate?

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
            delegate?.threadSessionDidEncounterError(error)
        }
    }

    func createAndSwitchThread() {
        guard !isExecutingProvider() else { return }
        do {
            persistCurrentState()
            _ = try dataService.createThread(title: nil)
            threadIndex = try dataService.loadThreadIndex()
            guard let currentThreadID = threadIndex?.currentThreadID else {
                throw ChatProviderError.noThreadAvailable
            }
            try switchToThread(threadID: currentThreadID)
        } catch {
            delegate?.threadSessionDidEncounterError(error)
        }
    }

    private func switchToThread(threadID: String) throws {
        persistCurrentState()

        let result = try dataService.switchThread(threadID: threadID)
        threadIndex = try dataService.loadThreadIndex()
        currentThread = result.thread
        sessionMemory = result.memory

        modelSelection.reloadModelSelectionContext(triggerModelRefresh: false)

        messageStore.replaceMessages(result.messages)
        delegate?.threadSessionDidSwitchThread()
    }

    // MARK: - Session Memory

    func updateSessionMemory(_ memory: SessionMemory?) {
        sessionMemory = memory
        persistSessionMemory()
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
            delegate?.threadSessionDidEncounterError(error)
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
            delegate?.threadSessionDidEncounterError(error)
        }
    }

    // MARK: - Private

    private func persistCurrentState() {
        guard let currentThread else { return }
        dataService.persistMessages(messageStore.messages, threadID: currentThread.id)
        modelSelection.persistCurrentModelSelection()
        dataService.persistSessionMemory(sessionMemory, threadID: currentThread.id)
    }

    private func persistSessionMemory() {
        guard let currentThread else { return }
        dataService.persistSessionMemory(sessionMemory, threadID: currentThread.id)
    }
}
