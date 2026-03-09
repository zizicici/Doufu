//
//  ProjectChatThreadStore.swift
//  Doufu
//
//  Created by Codex on 2026/03/06.
//

import Foundation

struct ProjectChatThreadRecord: Codable, Equatable, Hashable {
    let id: String
    var title: String
    let createdAt: Date
    var updatedAt: Date
    var currentVersion: Int
}

struct ProjectChatThreadIndex: Codable {
    var currentThreadID: String
    var threads: [ProjectChatThreadRecord]
}

struct ProjectChatPersistedMessage: Codable {
    let role: String
    let text: String
    let createdAt: Date
    let startedAt: Date?
    let finishedAt: Date?
    let isProgress: Bool
    let inputTokens: Int64?
    let outputTokens: Int64?
    let toolSummary: String?

    init(
        role: String,
        text: String,
        createdAt: Date,
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        isProgress: Bool = false,
        inputTokens: Int64? = nil,
        outputTokens: Int64? = nil,
        toolSummary: String? = nil
    ) {
        self.role = role
        self.text = text
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.isProgress = isProgress
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.toolSummary = toolSummary
    }

    private enum CodingKeys: String, CodingKey {
        case role
        case text
        case createdAt
        case startedAt
        case finishedAt
        case isProgress
        case inputTokens
        case outputTokens
        case toolSummary
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = try container.decode(String.self, forKey: .role)
        text = try container.decode(String.self, forKey: .text)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt)
        finishedAt = try container.decodeIfPresent(Date.self, forKey: .finishedAt)
        isProgress = try container.decodeIfPresent(Bool.self, forKey: .isProgress) ?? false
        inputTokens = try container.decodeIfPresent(Int64.self, forKey: .inputTokens)
        outputTokens = try container.decodeIfPresent(Int64.self, forKey: .outputTokens)
        toolSummary = try container.decodeIfPresent(String.self, forKey: .toolSummary)
    }
}

enum ProjectChatThreadStoreError: LocalizedError {
    case threadNotFound
    case invalidThreadData

    var errorDescription: String? {
        switch self {
        case .threadNotFound:
            return String(localized: "thread_store.error.thread_not_found")
        case .invalidThreadData:
            return String(localized: "thread_store.error.invalid_thread_data")
        }
    }
}

final class ProjectChatThreadStore {
    static let shared = ProjectChatThreadStore()

    private let fileManager: FileManager
    private let indexFileName = ".doufu_threads_index.json"
    private let messagesFilePrefix = ".doufu_thread_messages_"

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func loadOrCreateIndex(projectURL: URL) throws -> ProjectChatThreadIndex {
        let indexURL = indexFileURL(projectURL: projectURL)
        if let data = try? Data(contentsOf: indexURL),
           let index = try? makeIndexDecoder().decode(ProjectChatThreadIndex.self, from: data),
           !index.threads.isEmpty {
            return sanitizeIndex(index)
        }

        let now = Date()
        let thread = ProjectChatThreadRecord(
            id: makeThreadID(),
            title: String(localized: "thread.default_title"),
            createdAt: now,
            updatedAt: now,
            currentVersion: 0
        )
        let index = ProjectChatThreadIndex(currentThreadID: thread.id, threads: [thread])
        try saveIndex(index, projectURL: projectURL)
        return index
    }

    func loadCurrentThread(projectURL: URL) throws -> ProjectChatThreadRecord {
        let index = try loadOrCreateIndex(projectURL: projectURL)
        guard let thread = index.threads.first(where: { $0.id == index.currentThreadID }) else {
            throw ProjectChatThreadStoreError.threadNotFound
        }
        return thread
    }

    func loadThreads(projectURL: URL) throws -> [ProjectChatThreadRecord] {
        let index = try loadOrCreateIndex(projectURL: projectURL)
        return index.threads.sorted { lhs, rhs in
            if lhs.updatedAt == rhs.updatedAt {
                return lhs.createdAt > rhs.createdAt
            }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    @discardableResult
    func createThread(projectURL: URL, title: String? = nil, makeCurrent: Bool = true) throws -> ProjectChatThreadRecord {
        var index = try loadOrCreateIndex(projectURL: projectURL)
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
        try saveIndex(index, projectURL: projectURL)
        return thread
    }

    @discardableResult
    func switchCurrentThread(projectURL: URL, threadID: String) throws -> ProjectChatThreadRecord {
        var index = try loadOrCreateIndex(projectURL: projectURL)
        guard let thread = index.threads.first(where: { $0.id == threadID }) else {
            throw ProjectChatThreadStoreError.threadNotFound
        }
        index.currentThreadID = threadID
        try saveIndex(index, projectURL: projectURL)
        return thread
    }

    func renameThread(projectURL: URL, threadID: String, newTitle: String) throws {
        var index = try loadOrCreateIndex(projectURL: projectURL)
        guard let threadIndex = index.threads.firstIndex(where: { $0.id == threadID }) else {
            throw ProjectChatThreadStoreError.threadNotFound
        }
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        index.threads[threadIndex].title = trimmed
        index.threads[threadIndex].updatedAt = Date()
        try saveIndex(index, projectURL: projectURL)
    }

    func deleteThread(projectURL: URL, threadID: String) throws {
        var index = try loadOrCreateIndex(projectURL: projectURL)
        guard let threadIndex = index.threads.firstIndex(where: { $0.id == threadID }) else {
            throw ProjectChatThreadStoreError.threadNotFound
        }
        let thread = index.threads[threadIndex]
        index.threads.remove(at: threadIndex)

        // Clean up message file
        let messagesURL = messagesFileURL(projectURL: projectURL, threadID: threadID)
        try? fileManager.removeItem(at: messagesURL)

        // If deleted thread was current, switch to another
        if index.currentThreadID == threadID {
            index.currentThreadID = index.threads.first?.id ?? ""
        }

        if index.threads.isEmpty {
            // Create a fresh default thread
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

        try saveIndex(index, projectURL: projectURL)
    }

    func reorderThreads(projectURL: URL, orderedIDs: [String]) throws {
        var index = try loadOrCreateIndex(projectURL: projectURL)
        let lookup = Dictionary(uniqueKeysWithValues: index.threads.map { ($0.id, $0) })
        var reordered: [ProjectChatThreadRecord] = []
        for id in orderedIDs {
            if let thread = lookup[id] {
                reordered.append(thread)
            }
        }
        // Append any threads not in orderedIDs (safety)
        for thread in index.threads where !orderedIDs.contains(thread.id) {
            reordered.append(thread)
        }
        index.threads = reordered
        try saveIndex(index, projectURL: projectURL)
    }

    func loadMessages(projectURL: URL, threadID: String) -> [ProjectChatPersistedMessage] {
        let fileURL = messagesFileURL(projectURL: projectURL, threadID: threadID)
        guard let data = try? Data(contentsOf: fileURL) else {
            return []
        }
        return (try? JSONDecoder().decode([ProjectChatPersistedMessage].self, from: data)) ?? []
    }

    func saveMessages(
        projectURL: URL,
        threadID: String,
        messages: [ProjectChatPersistedMessage]
    ) {
        let fileURL = messagesFileURL(projectURL: projectURL, threadID: threadID)
        guard let data = try? JSONEncoder().encode(messages) else {
            return
        }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Update a thread's `updatedAt` timestamp after a chat response.
    func touchThread(projectURL: URL, threadID: String) throws {
        var index = try loadOrCreateIndex(projectURL: projectURL)
        guard let threadIndex = index.threads.firstIndex(where: { $0.id == threadID }) else {
            throw ProjectChatThreadStoreError.threadNotFound
        }
        index.threads[threadIndex].updatedAt = Date()
        try saveIndex(index, projectURL: projectURL)
    }

    private func sanitizeIndex(_ index: ProjectChatThreadIndex) -> ProjectChatThreadIndex {
        let uniqueThreads = Dictionary(grouping: index.threads, by: \.id)
            .compactMap { _, threads in
                threads.max(by: { $0.updatedAt < $1.updatedAt })
            }
            .sorted { $0.createdAt < $1.createdAt }
        guard !uniqueThreads.isEmpty else {
            return ProjectChatThreadIndex(currentThreadID: "", threads: [])
        }
        let currentThreadID = uniqueThreads.contains(where: { $0.id == index.currentThreadID })
            ? index.currentThreadID
            : uniqueThreads[0].id
        return ProjectChatThreadIndex(currentThreadID: currentThreadID, threads: uniqueThreads)
    }

    private func indexFileURL(projectURL: URL) -> URL {
        projectURL.appendingPathComponent(indexFileName)
    }

    private func messagesFileURL(projectURL: URL, threadID: String) -> URL {
        projectURL.appendingPathComponent("\(messagesFilePrefix)\(threadID).json")
    }

    private func saveIndex(_ index: ProjectChatThreadIndex, projectURL: URL) throws {
        let sanitized = sanitizeIndex(index)
        let encoder = makeIndexEncoder()
        let data = try encoder.encode(sanitized)
        try data.write(to: indexFileURL(projectURL: projectURL), options: .atomic)
    }

    private func makeIndexEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private func makeIndexDecoder() -> JSONDecoder {
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
}
