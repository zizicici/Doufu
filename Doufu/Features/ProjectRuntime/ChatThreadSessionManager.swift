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

    private let threadStore: ProjectChatThreadStore
    private let projectURL: URL
    private let messageStore: ChatMessageStore
    private let modelSelection: ChatModelSelectionManager
    private let isExecutingProvider: () -> Bool

    init(
        threadStore: ProjectChatThreadStore,
        projectURL: URL,
        messageStore: ChatMessageStore,
        modelSelection: ChatModelSelectionManager,
        isExecutingProvider: @escaping () -> Bool
    ) {
        self.threadStore = threadStore
        self.projectURL = projectURL
        self.messageStore = messageStore
        self.modelSelection = modelSelection
        self.isExecutingProvider = isExecutingProvider
    }

    // MARK: - Thread Lifecycle

    func restoreThreadStateIfNeeded() {
        do {
            threadIndex = try threadStore.loadOrCreateIndex(projectURL: projectURL)
            if let currentThreadID = threadIndex?.currentThreadID {
                try switchToThread(threadID: currentThreadID)
            }
        } catch {
            delegate?.threadSessionDidEncounterError(error)
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
            messageStore.persistMessages()
            _ = try threadStore.createThread(projectURL: projectURL, title: nil, makeCurrent: true)
            threadIndex = try threadStore.loadOrCreateIndex(projectURL: projectURL)
            guard let currentThreadID = threadIndex?.currentThreadID else {
                throw ChatProviderError.noThreadAvailable
            }
            try switchToThread(threadID: currentThreadID)
            messageStore.persistMessages()
        } catch {
            delegate?.threadSessionDidEncounterError(error)
        }
    }

    func switchToThread(threadID: String) throws {
        messageStore.persistMessages()
        modelSelection.persistCurrentThreadModelSelection()
        persistSessionMemory()

        let switched = try threadStore.switchCurrentThread(projectURL: projectURL, threadID: threadID)
        threadIndex = try threadStore.loadOrCreateIndex(projectURL: projectURL)
        currentThread = switched
        sessionMemory = threadStore.loadSessionMemory(projectURL: projectURL, threadID: switched.id)
        modelSelection.restoreThreadModelSelection(threadID: switched.id)

        let persisted = threadStore.loadMessages(projectURL: projectURL, threadID: switched.id)
        let restoredMessages: [ChatMessage] = persisted.compactMap { persistedMessage in
            let normalizedRole = persistedMessage.role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard let role = ChatMessage.Role(rawValue: normalizedRole) else {
                return nil
            }
            let text = persistedMessage.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                return nil
            }
            let startedAt = persistedMessage.startedAt ?? persistedMessage.createdAt
            let finishedAt: Date? = {
                if let finishedAt = persistedMessage.finishedAt {
                    return finishedAt
                }
                if persistedMessage.isProgress {
                    return startedAt
                }
                return persistedMessage.createdAt
            }()
            return ChatMessage(
                role: role,
                text: text,
                createdAt: persistedMessage.createdAt,
                startedAt: startedAt,
                finishedAt: finishedAt,
                isProgress: persistedMessage.isProgress,
                requestTokenUsage: {
                    let input = max(0, persistedMessage.inputTokens ?? 0)
                    let output = max(0, persistedMessage.outputTokens ?? 0)
                    guard input > 0 || output > 0 else {
                        return nil
                    }
                    return ProjectChatService.RequestTokenUsage(
                        inputTokens: input,
                        outputTokens: output
                    )
                }(),
                toolSummary: persistedMessage.toolSummary
            )
        }

        messageStore.replaceMessages(restoredMessages)
        delegate?.threadSessionDidSwitchThread()
    }

    // MARK: - Session Memory

    func updateSessionMemory(_ memory: SessionMemory?) {
        sessionMemory = memory
        persistSessionMemory()
    }

    // MARK: - Thread Metadata

    func touchCurrentThread() throws {
        guard let currentThread else { return }
        try threadStore.touchThread(
            projectURL: projectURL,
            threadID: currentThread.id
        )
        if var index = threadIndex {
            if let threadIdx = index.threads.firstIndex(where: { $0.id == currentThread.id }) {
                index.threads[threadIdx].updatedAt = Date()
                threadIndex = index
            }
        }
    }

    func reloadIndex() throws {
        threadIndex = try threadStore.loadOrCreateIndex(projectURL: projectURL)
        if let currentThreadID = threadIndex?.currentThreadID,
           currentThreadID != currentThread?.id {
            try switchToThread(threadID: currentThreadID)
        } else if let currentThreadID = threadIndex?.currentThreadID {
            currentThread = threadIndex?.threads.first(where: { $0.id == currentThreadID })
        }
    }

    // MARK: - Private

    private func persistSessionMemory() {
        guard let currentThread else { return }
        threadStore.saveSessionMemory(
            projectURL: projectURL,
            threadID: currentThread.id,
            memory: sessionMemory
        )
    }
}
