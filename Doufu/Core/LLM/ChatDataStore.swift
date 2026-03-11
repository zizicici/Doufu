//
//  ChatDataStore.swift
//  Doufu
//
//  Created by Claude on 2026/03/10.
//

import Foundation

/// Centralized, concurrency-safe store for all chat data.
/// Uses `projectID` as the storage key, decoupling chat data from the project directory.
///
/// Storage layout:
/// ```
/// Documents/ChatData/{projectID}/
///   thread_index.json
///   threads/{threadID}/
///     messages.json
///     memory.json
///   model_config.json
///   thread_selections.json
/// ```
actor ChatDataStore {

    static let shared = ChatDataStore()

    private let fileManager: FileManager

    private init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    // MARK: - Thread Index

    func loadOrCreateIndex(projectID: String) throws -> ProjectChatThreadIndex {
        let indexURL = threadIndexURL(projectID: projectID)

        guard fileManager.fileExists(atPath: indexURL.path) else {
            return try createFreshIndex(projectID: projectID)
        }

        let data: Data
        do {
            data = try Data(contentsOf: indexURL)
        } catch {
            throw ProjectChatThreadStoreError.indexReadFailed(underlying: error)
        }

        do {
            let index = try makeDecoder().decode(ProjectChatThreadIndex.self, from: data)
            guard !index.threads.isEmpty else {
                return try createFreshIndex(projectID: projectID)
            }
            return sanitizeIndex(index)
        } catch {
            let backupURL = indexURL.deletingLastPathComponent()
                .appendingPathComponent("thread_index_corrupted_\(Int(Date().timeIntervalSince1970)).json")
            try? fileManager.copyItem(at: indexURL, to: backupURL)
            print("[ChatDataStore] WARNING: Corrupted thread index for project \(projectID). Backed up to \(backupURL.lastPathComponent). Error: \(error.localizedDescription)")
            throw ProjectChatThreadStoreError.indexCorrupted(
                backupPath: backupURL.lastPathComponent,
                underlying: error
            )
        }
    }

    /// Explicitly recover from a corrupted index by creating a fresh one.
    /// Call this after catching `indexCorrupted` to allow the user to continue.
    func recoverCorruptedIndex(projectID: String) throws -> ProjectChatThreadIndex {
        try createFreshIndex(projectID: projectID)
    }

    private func createFreshIndex(projectID: String) throws -> ProjectChatThreadIndex {
        let now = Date()
        let thread = ProjectChatThreadRecord(
            id: makeThreadID(),
            title: String(localized: "thread.default_title"),
            createdAt: now,
            updatedAt: now,
            currentVersion: 0
        )
        let index = ProjectChatThreadIndex(currentThreadID: thread.id, threads: [thread])
        try saveIndex(index, projectID: projectID)
        return index
    }

    // MARK: - Thread Management

    @discardableResult
    func createThread(projectID: String, title: String?, makeCurrent: Bool) throws -> ProjectChatThreadRecord {
        var index = try loadOrCreateIndex(projectID: projectID)
        let now = Date()
        let nextCount = index.threads.count + 1
        let thread = ProjectChatThreadRecord(
            id: makeThreadID(),
            title: normalizedThreadTitle(
                title,
                fallback: String(format: String(localized: "thread.default_title_format"), nextCount)
            ),
            createdAt: now,
            updatedAt: now,
            currentVersion: 0
        )
        index.threads.append(thread)
        if makeCurrent {
            index.currentThreadID = thread.id
        }
        try saveIndex(index, projectID: projectID)
        return thread
    }

    @discardableResult
    func switchCurrentThread(projectID: String, threadID: String) throws -> ProjectChatThreadRecord {
        var index = try loadOrCreateIndex(projectID: projectID)
        guard let thread = index.threads.first(where: { $0.id == threadID }) else {
            throw ProjectChatThreadStoreError.threadNotFound
        }
        index.currentThreadID = threadID
        try saveIndex(index, projectID: projectID)
        return thread
    }

    func deleteThread(projectID: String, threadID: String) throws {
        var index = try loadOrCreateIndex(projectID: projectID)
        guard index.threads.contains(where: { $0.id == threadID }) else {
            throw ProjectChatThreadStoreError.threadNotFound
        }
        index.threads.removeAll(where: { $0.id == threadID })

        // Clean up thread files and model selection
        let threadDir = threadDirectoryURL(projectID: projectID, threadID: threadID)
        try? fileManager.removeItem(at: threadDir)
        removeThreadModelSelection(projectID: projectID, threadID: threadID)

        // If deleted thread was current, switch to another
        if index.currentThreadID == threadID {
            index.currentThreadID = index.threads.first?.id ?? ""
        }

        if index.threads.isEmpty {
            let now = Date()
            let newThread = ProjectChatThreadRecord(
                id: makeThreadID(),
                title: String(localized: "thread.default_title"),
                createdAt: now,
                updatedAt: now,
                currentVersion: 0
            )
            index.threads.append(newThread)
            index.currentThreadID = newThread.id
        }

        try saveIndex(index, projectID: projectID)
    }

    func renameThread(projectID: String, threadID: String, newTitle: String) throws {
        var index = try loadOrCreateIndex(projectID: projectID)
        guard let threadIndex = index.threads.firstIndex(where: { $0.id == threadID }) else {
            throw ProjectChatThreadStoreError.threadNotFound
        }
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        index.threads[threadIndex].title = trimmed
        index.threads[threadIndex].updatedAt = Date()
        try saveIndex(index, projectID: projectID)
    }

    func touchThread(projectID: String, threadID: String) throws {
        var index = try loadOrCreateIndex(projectID: projectID)
        guard let threadIndex = index.threads.firstIndex(where: { $0.id == threadID }) else {
            throw ProjectChatThreadStoreError.threadNotFound
        }
        index.threads[threadIndex].updatedAt = Date()
        try saveIndex(index, projectID: projectID)
    }

    func reorderThreads(projectID: String, orderedIDs: [String]) throws {
        var index = try loadOrCreateIndex(projectID: projectID)
        let lookup = Dictionary(uniqueKeysWithValues: index.threads.map { ($0.id, $0) })
        var reordered: [ProjectChatThreadRecord] = []
        for id in orderedIDs {
            if let thread = lookup[id] {
                reordered.append(thread)
            }
        }
        for thread in index.threads where !orderedIDs.contains(thread.id) {
            reordered.append(thread)
        }
        index.threads = reordered
        try saveIndex(index, projectID: projectID)
    }

    // MARK: - Messages

    func loadMessages(projectID: String, threadID: String) -> [ProjectChatPersistedMessage] {
        let fileURL = messagesFileURL(projectID: projectID, threadID: threadID)
        guard let data = try? Data(contentsOf: fileURL) else {
            return []
        }
        return (try? JSONDecoder().decode([ProjectChatPersistedMessage].self, from: data)) ?? []
    }

    func saveMessages(projectID: String, threadID: String, messages: [ProjectChatPersistedMessage]) {
        let fileURL = messagesFileURL(projectID: projectID, threadID: threadID)
        ensureDirectory(at: fileURL.deletingLastPathComponent())
        guard let data = try? JSONEncoder().encode(messages) else {
            return
        }
        try? data.write(to: fileURL, options: .atomic)
    }

    // MARK: - Session Memory

    func loadSessionMemory(projectID: String, threadID: String) -> SessionMemory? {
        let fileURL = memoryFileURL(projectID: projectID, threadID: threadID)
        guard let data = try? Data(contentsOf: fileURL) else {
            return nil
        }
        return try? JSONDecoder().decode(SessionMemory.self, from: data)
    }

    func saveSessionMemory(projectID: String, threadID: String, memory: SessionMemory?) {
        let fileURL = memoryFileURL(projectID: projectID, threadID: threadID)
        guard let memory else {
            try? fileManager.removeItem(at: fileURL)
            return
        }
        ensureDirectory(at: fileURL.deletingLastPathComponent())
        guard let data = try? JSONEncoder().encode(memory) else {
            return
        }
        try? data.write(to: fileURL, options: .atomic)
    }

    // MARK: - Model Selection (Project-level)

    func loadProjectModelSelection(projectID: String) -> ModelSelection? {
        let config = loadProjectConfig(projectID: projectID)
        guard let providerID = config?.selectedProviderID,
              !providerID.isEmpty,
              let modelRecordID = config?.selectedModelRecordID,
              !modelRecordID.isEmpty
        else {
            return nil
        }
        return ModelSelection(providerID: providerID, modelRecordID: modelRecordID)
    }

    func saveProjectModelSelection(_ selection: ModelSelection?, projectID: String) {
        var config = loadProjectConfig(projectID: projectID) ?? ChatDataProjectConfig()
        config.selectedProviderID = selection?.providerID
        config.selectedModelRecordID = selection?.modelRecordID
        saveProjectConfig(config, projectID: projectID)
    }

    // MARK: - Model Selection (Thread-level)

    func loadThreadModelSelection(projectID: String, threadID: String) -> ThreadModelSelection? {
        let selections = loadThreadSelections(projectID: projectID)
        return selections[threadID]
    }

    func loadCurrentThreadModelSelection(projectID: String) -> ThreadModelSelection? {
        let indexURL = threadIndexURL(projectID: projectID)
        guard let data = try? Data(contentsOf: indexURL),
              let index = try? makeDecoder().decode(ProjectChatThreadIndex.self, from: data)
        else {
            return nil
        }

        let sanitized = sanitizeIndex(index)
        guard !sanitized.currentThreadID.isEmpty else {
            return nil
        }

        return loadThreadModelSelection(projectID: projectID, threadID: sanitized.currentThreadID)
    }

    func saveThreadModelSelection(_ selection: ThreadModelSelection, projectID: String, threadID: String) {
        var selections = loadThreadSelections(projectID: projectID)
        selections[threadID] = selection
        saveThreadSelections(selections, projectID: projectID)
    }

    func removeThreadModelSelection(projectID: String, threadID: String) {
        var selections = loadThreadSelections(projectID: projectID)
        selections.removeValue(forKey: threadID)
        saveThreadSelections(selections, projectID: projectID)
    }

    // MARK: - Project Lifecycle

    func deleteProjectData(projectID: String) throws {
        let projectDir = projectDataURL(projectID: projectID)
        guard fileManager.fileExists(atPath: projectDir.path) else { return }
        try fileManager.removeItem(at: projectDir)
    }

    // MARK: - Path Helpers

    private func chatDataRootURL() -> URL {
        let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        return documentsURL.appendingPathComponent("ChatData", isDirectory: true)
    }

    private func projectDataURL(projectID: String) -> URL {
        chatDataRootURL().appendingPathComponent(projectID, isDirectory: true)
    }

    private func threadIndexURL(projectID: String) -> URL {
        projectDataURL(projectID: projectID).appendingPathComponent("thread_index.json")
    }

    private func threadDirectoryURL(projectID: String, threadID: String) -> URL {
        projectDataURL(projectID: projectID)
            .appendingPathComponent("threads", isDirectory: true)
            .appendingPathComponent(threadID, isDirectory: true)
    }

    private func messagesFileURL(projectID: String, threadID: String) -> URL {
        threadDirectoryURL(projectID: projectID, threadID: threadID)
            .appendingPathComponent("messages.json")
    }

    private func memoryFileURL(projectID: String, threadID: String) -> URL {
        threadDirectoryURL(projectID: projectID, threadID: threadID)
            .appendingPathComponent("memory.json")
    }

    private func modelConfigURL(projectID: String) -> URL {
        projectDataURL(projectID: projectID).appendingPathComponent("model_config.json")
    }

    private func threadSelectionsURL(projectID: String) -> URL {
        projectDataURL(projectID: projectID).appendingPathComponent("thread_selections.json")
    }

    // MARK: - Private Helpers

    private func ensureDirectory(at url: URL) {
        if !fileManager.fileExists(atPath: url.path) {
            try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    private func saveIndex(_ index: ProjectChatThreadIndex, projectID: String) throws {
        let sanitized = sanitizeIndex(index)
        let url = threadIndexURL(projectID: projectID)
        ensureDirectory(at: url.deletingLastPathComponent())
        let data = try makeEncoder().encode(sanitized)
        try data.write(to: url, options: .atomic)
    }

    private func sanitizeIndex(_ index: ProjectChatThreadIndex) -> ProjectChatThreadIndex {
        var bestByID: [String: ProjectChatThreadRecord] = [:]
        for thread in index.threads {
            if let existing = bestByID[thread.id] {
                if thread.updatedAt > existing.updatedAt {
                    bestByID[thread.id] = thread
                }
            } else {
                bestByID[thread.id] = thread
            }
        }
        var seen = Set<String>()
        var uniqueThreads: [ProjectChatThreadRecord] = []
        for thread in index.threads {
            if seen.insert(thread.id).inserted, let best = bestByID[thread.id] {
                uniqueThreads.append(best)
            }
        }
        guard !uniqueThreads.isEmpty else {
            return ProjectChatThreadIndex(currentThreadID: "", threads: [])
        }
        let currentThreadID = uniqueThreads.contains(where: { $0.id == index.currentThreadID })
            ? index.currentThreadID
            : uniqueThreads[0].id
        return ProjectChatThreadIndex(currentThreadID: currentThreadID, threads: uniqueThreads)
    }

    private func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func makeThreadID() -> String {
        UUID().uuidString.lowercased()
    }

    private func normalizedThreadTitle(_ rawTitle: String?, fallback: String) -> String {
        let normalized = rawTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return normalized.isEmpty ? fallback : normalized
    }

    // MARK: - Project Config (private model)

    private func loadProjectConfig(projectID: String) -> ChatDataProjectConfig? {
        let url = modelConfigURL(projectID: projectID)
        guard let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(ChatDataProjectConfig.self, from: data)
        else {
            return nil
        }
        return config
    }

    private func saveProjectConfig(_ config: ChatDataProjectConfig, projectID: String) {
        let url = modelConfigURL(projectID: projectID)
        ensureDirectory(at: url.deletingLastPathComponent())
        guard let data = try? JSONEncoder().encode(config) else {
            return
        }
        try? data.write(to: url, options: .atomic)
    }

    private func loadThreadSelections(projectID: String) -> [String: ThreadModelSelection] {
        let url = threadSelectionsURL(projectID: projectID)
        guard let data = try? Data(contentsOf: url) else {
            return [:]
        }
        guard
            let rawObject = try? JSONSerialization.jsonObject(with: data),
            let rawSelections = rawObject as? [String: Any]
        else {
            return [:]
        }

        // Decode each thread override independently so one bad entry does not drop the whole file.
        let decoder = makeDecoder()
        var selections: [String: ThreadModelSelection] = [:]
        for (threadID, rawSelection) in rawSelections {
            guard JSONSerialization.isValidJSONObject(rawSelection),
                  let selectionData = try? JSONSerialization.data(withJSONObject: rawSelection),
                  let selection = try? decoder.decode(ThreadModelSelection.self, from: selectionData)
            else {
                continue
            }
            selections[threadID] = selection
        }
        return selections
    }

    private func saveThreadSelections(_ selections: [String: ThreadModelSelection], projectID: String) {
        let url = threadSelectionsURL(projectID: projectID)
        ensureDirectory(at: url.deletingLastPathComponent())
        guard let data = try? JSONEncoder().encode(selections) else {
            return
        }
        try? data.write(to: url, options: .atomic)
    }
}

/// Internal config model for ChatDataStore (replaces the old ProjectConfig).
private struct ChatDataProjectConfig: Codable {
    var selectedProviderID: String?
    var selectedModelRecordID: String?
}
