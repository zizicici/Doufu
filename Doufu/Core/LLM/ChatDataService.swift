//
//  ChatDataService.swift
//  Doufu
//
//  Created by Claude on 2026/03/10.
//

import Foundation

/// Per-project data service that wraps `ChatDataStore` and provides
/// automatic persistence. Each `ChatDataService` instance is bound
/// to a single `projectID`.
@MainActor
final class ChatDataService {

    private static var writeQueuesByProjectID: [String: SerialWriteQueue] = [:]

    private static func acquireWriteQueue(projectID: String) -> SerialWriteQueue {
        if let existing = writeQueuesByProjectID[projectID] {
            return existing
        }

        let queue = SerialWriteQueue()
        writeQueuesByProjectID[projectID] = queue
        return queue
    }

    let projectID: String
    private let dataStore: ChatDataStore
    /// Per-project serial write queue shared across ChatDataService instances,
    /// so settings/chat/controllers all observe writes in a single order.
    private let writeQueue: SerialWriteQueue

    init(projectID: String, dataStore: ChatDataStore = .shared) {
        self.projectID = projectID
        self.dataStore = dataStore
        self.writeQueue = Self.acquireWriteQueue(projectID: projectID)
    }

    // MARK: - Thread Operations

    func loadThreadIndex() async throws -> ProjectChatThreadIndex {
        do {
            return try await dataStore.loadOrCreateIndex(projectID: projectID)
        } catch let error as ProjectChatThreadStoreError {
            if case .indexCorrupted = error {
                // Auto-recover: create fresh index after corruption was detected and backed up
                print("[ChatDataService] Auto-recovering from corrupted index for project \(projectID)")
                return try await dataStore.recoverCorruptedIndex(projectID: projectID)
            }
            throw error
        }
    }

    func switchThread(threadID: String) async throws -> (
        thread: ProjectChatThreadRecord,
        messages: [ChatMessage],
        memory: SessionMemory?,
        modelSelection: ModelSelection?
    ) {
        let thread = try await dataStore.switchCurrentThread(projectID: projectID, threadID: threadID)
        let persisted = await dataStore.loadMessages(projectID: projectID, threadID: threadID)
        let memory = await dataStore.loadSessionMemory(projectID: projectID, threadID: threadID)
        let modelSelection = await dataStore.loadModelSelection(projectID: projectID, threadID: threadID)

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

    func createThread(title: String?) async throws -> ProjectChatThreadRecord {
        try await dataStore.createThread(projectID: projectID, title: title, makeCurrent: true)
    }

    // MARK: - Model Selection (Project-level)

    func loadProjectModelSelection() async -> ModelSelection? {
        await writeQueue.flush()
        return await dataStore.loadProjectModelSelection(projectID: projectID)
    }

    func loadModelSelection(threadID: String) async -> ModelSelection? {
        await writeQueue.flush()
        return await dataStore.loadModelSelection(projectID: projectID, threadID: threadID)
    }

    func loadCurrentModelSelection() async -> ModelSelection? {
        await writeQueue.flush()
        return await dataStore.loadCurrentModelSelection(projectID: projectID)
    }

    func persistProjectModelSelection(_ selection: ModelSelection?) {
        let dataStore = self.dataStore
        let projectID = self.projectID
        writeQueue.enqueue {
            await dataStore.saveProjectModelSelection(selection, projectID: projectID)
        }
    }

    func removeModelSelection(threadID: String) {
        let dataStore = self.dataStore
        let projectID = self.projectID
        writeQueue.enqueue {
            await dataStore.removeModelSelection(projectID: projectID, threadID: threadID)
        }
    }

    func removeModelSelectionAsync(threadID: String) async {
        let dataStore = self.dataStore
        let projectID = self.projectID
        await writeQueue.enqueueAndWait {
            await dataStore.removeModelSelection(projectID: projectID, threadID: threadID)
        }
    }

    func persistProjectModelSelectionAsync(_ selection: ModelSelection?) async {
        let dataStore = self.dataStore
        let projectID = self.projectID
        await writeQueue.enqueueAndWait {
            await dataStore.saveProjectModelSelection(selection, projectID: projectID)
        }
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
        let dataStore = self.dataStore
        let projectID = self.projectID
        writeQueue.enqueue {
            await dataStore.saveMessages(projectID: projectID, threadID: threadID, messages: persisted)
        }
    }

    func persistSessionMemory(_ memory: SessionMemory?, threadID: String) {
        let dataStore = self.dataStore
        let projectID = self.projectID
        writeQueue.enqueue {
            await dataStore.saveSessionMemory(projectID: projectID, threadID: threadID, memory: memory)
        }
    }

    func persistModelSelection(_ selection: ModelSelection, threadID: String) {
        let dataStore = self.dataStore
        let projectID = self.projectID
        writeQueue.enqueue {
            await dataStore.saveModelSelection(selection, projectID: projectID, threadID: threadID)
        }
    }

    // MARK: - Ordered Persistence (awaitable, used before thread switch)

    func persistMessagesAsync(_ messages: [ChatMessage], threadID: String) async {
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
        let dataStore = self.dataStore
        let projectID = self.projectID
        await writeQueue.enqueueAndWait {
            await dataStore.saveMessages(projectID: projectID, threadID: threadID, messages: persisted)
        }
    }

    func persistSessionMemoryAsync(_ memory: SessionMemory?, threadID: String) async {
        let dataStore = self.dataStore
        let projectID = self.projectID
        await writeQueue.enqueueAndWait {
            await dataStore.saveSessionMemory(projectID: projectID, threadID: threadID, memory: memory)
        }
    }

    func persistModelSelectionAsync(_ selection: ModelSelection, threadID: String) async {
        let dataStore = self.dataStore
        let projectID = self.projectID
        await writeQueue.enqueueAndWait {
            await dataStore.saveModelSelection(selection, projectID: projectID, threadID: threadID)
        }
    }

    func touchThread(threadID: String) async throws {
        try await dataStore.touchThread(projectID: projectID, threadID: threadID)
    }
}
