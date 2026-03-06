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

    init(
        role: String,
        text: String,
        createdAt: Date,
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        isProgress: Bool = false
    ) {
        self.role = role
        self.text = text
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.isProgress = isProgress
    }

    private enum CodingKeys: String, CodingKey {
        case role
        case text
        case createdAt
        case startedAt
        case finishedAt
        case isProgress
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = try container.decode(String.self, forKey: .role)
        text = try container.decode(String.self, forKey: .text)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt)
        finishedAt = try container.decodeIfPresent(Date.self, forKey: .finishedAt)
        isProgress = try container.decodeIfPresent(Bool.self, forKey: .isProgress) ?? false
    }
}

struct AppliedThreadMemoryResult {
    let updatedThread: ProjectChatThreadRecord
    let memoryFilePath: String
    let memoryContent: String
}

enum ProjectChatThreadStoreError: LocalizedError {
    case threadNotFound
    case invalidThreadData

    var errorDescription: String? {
        switch self {
        case .threadNotFound:
            return "线程不存在。"
        case .invalidThreadData:
            return "线程数据损坏，无法读取。"
        }
    }
}

final class ProjectChatThreadStore {
    static let shared = ProjectChatThreadStore()

    private let fileManager: FileManager
    private let indexFileName = ".doufu_threads_index.json"
    private let messagesFilePrefix = ".doufu_thread_messages_"
    private let threadMemoryPrefix = "thread_memory_"
    private let threadMemoryExtension = ".md"

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
            title: "Thread 1",
            createdAt: now,
            updatedAt: now,
            currentVersion: 0
        )
        let index = ProjectChatThreadIndex(currentThreadID: thread.id, threads: [thread])
        try writeThreadMemory(
            projectURL: projectURL,
            threadID: thread.id,
            version: thread.currentVersion,
            content: initialThreadMemoryContent(threadID: thread.id, version: thread.currentVersion, previousSummary: nil)
        )
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
            title: normalizedThreadTitle(title, fallback: "Thread \(nextCount)"),
            createdAt: now,
            updatedAt: now,
            currentVersion: 0
        )
        index.threads.append(thread)
        if makeCurrent {
            index.currentThreadID = thread.id
        }
        try writeThreadMemory(
            projectURL: projectURL,
            threadID: thread.id,
            version: thread.currentVersion,
            content: initialThreadMemoryContent(threadID: thread.id, version: thread.currentVersion, previousSummary: nil)
        )
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

    func currentMemoryFilePath(for thread: ProjectChatThreadRecord) -> String {
        threadMemoryFileName(threadID: thread.id, version: thread.currentVersion)
    }

    func loadThreadMemory(projectURL: URL, thread: ProjectChatThreadRecord) -> String {
        let fileURL = threadMemoryFileURL(projectURL: projectURL, threadID: thread.id, version: thread.currentVersion)
        if let content = try? String(contentsOf: fileURL, encoding: .utf8) {
            return content
        }
        let fallback = initialThreadMemoryContent(threadID: thread.id, version: thread.currentVersion, previousSummary: nil)
        try? fallback.write(to: fileURL, atomically: true, encoding: .utf8)
        return fallback
    }

    @discardableResult
    func applyThreadMemoryUpdate(
        projectURL: URL,
        threadID: String,
        update: CodexProjectChatService.ThreadMemoryUpdate?,
        fallbackUserMessage: String,
        fallbackAssistantMessage: String
    ) throws -> AppliedThreadMemoryResult {
        var index = try loadOrCreateIndex(projectURL: projectURL)
        guard let threadIndex = index.threads.firstIndex(where: { $0.id == threadID }) else {
            throw ProjectChatThreadStoreError.threadNotFound
        }
        var thread = index.threads[threadIndex]
        let currentFileURL = threadMemoryFileURL(
            projectURL: projectURL,
            threadID: thread.id,
            version: thread.currentVersion
        )
        let currentContent = (try? String(contentsOf: currentFileURL, encoding: .utf8))
            ?? initialThreadMemoryContent(threadID: thread.id, version: thread.currentVersion, previousSummary: nil)

        let normalizedCurrent = currentContent.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalizedCurrentContent: String
        if let update, !update.contentMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            finalizedCurrentContent = update.contentMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            finalizedCurrentContent = appendFallbackEntry(
                to: normalizedCurrent,
                userMessage: fallbackUserMessage,
                assistantMessage: fallbackAssistantMessage
            )
        }

        try finalizedCurrentContent.write(to: currentFileURL, atomically: true, encoding: .utf8)

        let shouldRollOver = update?.shouldRollOver ?? false
        if shouldRollOver {
            let nextVersion = thread.currentVersion + 1
            let previousSummary = (update?.nextVersionSummary?
                .trimmingCharacters(in: .whitespacesAndNewlines))
                .flatMap { $0.isEmpty ? nil : $0 }
                ?? summarizeForRollover(markdown: finalizedCurrentContent)
            let nextVersionContent = (update?.nextVersionContentMarkdown?
                .trimmingCharacters(in: .whitespacesAndNewlines))
                .flatMap { $0.isEmpty ? nil : $0 }
                ?? initialThreadMemoryContent(
                    threadID: thread.id,
                    version: nextVersion,
                    previousSummary: previousSummary
                )
            try writeThreadMemory(
                projectURL: projectURL,
                threadID: thread.id,
                version: nextVersion,
                content: nextVersionContent
            )
            thread.currentVersion = nextVersion
            thread.updatedAt = Date()
            index.threads[threadIndex] = thread
            try saveIndex(index, projectURL: projectURL)

            return AppliedThreadMemoryResult(
                updatedThread: thread,
                memoryFilePath: currentMemoryFilePath(for: thread),
                memoryContent: nextVersionContent
            )
        }

        thread.updatedAt = Date()
        index.threads[threadIndex] = thread
        try saveIndex(index, projectURL: projectURL)
        return AppliedThreadMemoryResult(
            updatedThread: thread,
            memoryFilePath: currentMemoryFilePath(for: thread),
            memoryContent: finalizedCurrentContent
        )
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

    private func threadMemoryFileName(threadID: String, version: Int) -> String {
        "\(threadMemoryPrefix)\(threadID)_\(version)\(threadMemoryExtension)"
    }

    private func threadMemoryFileURL(projectURL: URL, threadID: String, version: Int) -> URL {
        projectURL.appendingPathComponent(threadMemoryFileName(threadID: threadID, version: version))
    }

    private func writeThreadMemory(
        projectURL: URL,
        threadID: String,
        version: Int,
        content: String
    ) throws {
        let fileURL = threadMemoryFileURL(projectURL: projectURL, threadID: threadID, version: version)
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
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

    private func appendFallbackEntry(
        to markdown: String,
        userMessage: String,
        assistantMessage: String
    ) -> String {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let userLine = sanitizedSingleLine(userMessage, maxCharacters: 320)
        let assistantLine = sanitizedSingleLine(assistantMessage, maxCharacters: 380)

        var output = markdown
        if output.isEmpty {
            output = """
            # Thread Memory

            ## Rolling Notes
            """
        } else if !output.contains("## Rolling Notes") {
            output += "\n\n## Rolling Notes"
        }
        output += "\n- [\(timestamp)] User: \(userLine)"
        output += "\n- [\(timestamp)] Assistant: \(assistantLine)"
        return output
    }

    private func summarizeForRollover(markdown: String) -> String {
        let normalized = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let summary = normalized.prefix(6).joined(separator: " | ")
        let compact = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !compact.isEmpty else {
            return "上一版本总结：用户与助手完成了一轮对话与改动。"
        }
        return "上一版本总结：\(sanitizedSingleLine(compact, maxCharacters: 420))"
    }

    private func initialThreadMemoryContent(
        threadID: String,
        version: Int,
        previousSummary: String?
    ) -> String {
        let now = ISO8601DateFormatter().string(from: Date())
        let previous = previousSummary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "无"
        return """
        # Thread Memory

        - Thread ID: \(threadID)
        - Version: \(version)
        - Updated At: \(now)

        ## Previous Version Summary
        \(previous)

        ## Current Objective
        - 

        ## Applied Changes
        - 

        ## Open Todos
        - 

        ## Rolling Notes
        - 
        """
    }

    private func sanitizedSingleLine(_ text: String, maxCharacters: Int) -> String {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > maxCharacters else {
            return normalized
        }
        return String(normalized.prefix(maxCharacters)) + "..."
    }
}
