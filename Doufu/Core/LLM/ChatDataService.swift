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

    func loadThreadIndex() throws -> ProjectChatThreadIndex {
        try dataStore.loadOrCreateIndex(projectID: projectID)
    }

    func switchThread(threadID: String) throws -> (
        thread: ProjectChatThreadRecord,
        messages: [ChatMessage],
        memory: SessionMemory?,
        modelSelection: ModelSelection?
    ) {
        let thread = try dataStore.switchCurrentThread(projectID: projectID, threadID: threadID)
        let persisted = dataStore.loadMessages(projectID: projectID, threadID: threadID)
        let memory = dataStore.loadSessionMemory(projectID: projectID, threadID: threadID)
        let modelSelection = LLMProviderSettingsStore.shared.loadThreadModelSelection(
            projectID: projectID, threadID: threadID
        )

        let messages = persisted.compactMap { persistedMessage -> ChatMessage? in
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
                    guard input > 0 || output > 0 else { return nil }
                    return ProjectChatService.RequestTokenUsage(
                        inputTokens: input,
                        outputTokens: output
                    )
                }(),
                toolSummary: persistedMessage.toolSummary
            )
        }

        return (thread, messages, memory, modelSelection)
    }

    func createThread(title: String?) throws -> ProjectChatThreadRecord {
        try dataStore.createThread(projectID: projectID, title: title, makeCurrent: true)
    }

    // MARK: - Auto-Persistence

    func persistMessages(_ messages: [ChatMessage], threadID: String) {
        let persisted = messages.compactMap { message -> ProjectChatPersistedMessage? in
            let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return ProjectChatPersistedMessage(
                role: message.role.rawValue,
                text: text,
                createdAt: message.createdAt,
                startedAt: message.startedAt,
                finishedAt: message.finishedAt,
                isProgress: message.isProgress,
                inputTokens: message.requestTokenUsage?.inputTokens,
                outputTokens: message.requestTokenUsage?.outputTokens,
                toolSummary: message.toolSummary
            )
        }
        dataStore.saveMessages(projectID: projectID, threadID: threadID, messages: persisted)
    }

    func persistSessionMemory(_ memory: SessionMemory?, threadID: String) {
        dataStore.saveSessionMemory(projectID: projectID, threadID: threadID, memory: memory)
    }

    // MARK: - Ordered Persistence (used before thread switch)

    func persistMessagesAsync(_ messages: [ChatMessage], threadID: String) {
        persistMessages(messages, threadID: threadID)
    }

    func persistSessionMemoryAsync(_ memory: SessionMemory?, threadID: String) {
        persistSessionMemory(memory, threadID: threadID)
    }

    func touchThread(threadID: String) throws {
        try dataStore.touchThread(projectID: projectID, threadID: threadID)
    }
}
