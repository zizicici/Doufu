//
//  ChatDataStore.swift
//  Doufu
//

import Foundation
import GRDB

/// Centralized store for all chat data, backed by SQLite via GRDB.
/// `DatabasePool` is thread-safe, so no actor isolation needed.
final class ChatDataStore {

    enum Error: LocalizedError {
        case missingProject(projectID: String)

        var errorDescription: String? {
            switch self {
            case .missingProject(let projectID):
                return "Project not found: \(projectID)"
            }
        }
    }

    static let shared = ChatDataStore()

    private var dbPool: DatabasePool { DatabaseManager.shared.dbPool }

    private init() {}

    // MARK: - Thread Index

    func loadOrCreateIndex(projectID: String) throws -> ProjectChatThreadIndex {
        let threads = try dbPool.read { db in
            try DBChatThread
                .filter(DBChatThread.Columns.projectID == projectID)
                .order(DBChatThread.Columns.sortOrder)
                .fetchAll(db)
        }

        guard !threads.isEmpty else {
            return try createFreshIndex(projectID: projectID)
        }

        let threadRecords = threads.map { $0.toThreadRecord() }
        let currentThreadID = threads.first(where: { $0.isCurrent })?.id ?? threads[0].id
        return ProjectChatThreadIndex(currentThreadID: currentThreadID, threads: threadRecords)
    }

    private func createFreshIndex(projectID: String) throws -> ProjectChatThreadIndex {
        let now = Date()
        let threadID = makeThreadID()
        let thread = ProjectChatThreadRecord(
            id: threadID,
            title: String(localized: "thread.default_title"),
            createdAt: now,
            updatedAt: now,
            currentVersion: 0
        )

        try dbPool.write { db in
            guard try projectExists(projectID: projectID, in: db) else {
                throw Error.missingProject(projectID: projectID)
            }

            let dbThread = DBChatThread.from(thread, projectID: projectID, isCurrent: true, sortOrder: 0)
            try dbThread.insert(db)

            // Create default assistant
            let assistant = DBAssistant(
                id: UUID().uuidString.lowercased(),
                threadID: threadID,
                label: "Assistant",
                sortOrder: 0,
                createdAt: DatabaseTimestamp.toNanos(now)
            )
            try assistant.insert(db)
        }

        return ProjectChatThreadIndex(currentThreadID: thread.id, threads: [thread])
    }

    // MARK: - Thread Management

    @discardableResult
    func createThread(projectID: String, title: String?, makeCurrent: Bool) throws -> ProjectChatThreadRecord {
        let now = Date()
        let threadID = makeThreadID()

        let threadCount = try dbPool.read { db in
            try DBChatThread
                .filter(DBChatThread.Columns.projectID == projectID)
                .fetchCount(db)
        }

        let nextCount = threadCount + 1
        let resolvedTitle = normalizedThreadTitle(
            title,
            fallback: String(format: String(localized: "thread.default_title_format"), nextCount)
        )

        let thread = ProjectChatThreadRecord(
            id: threadID,
            title: resolvedTitle,
            createdAt: now,
            updatedAt: now,
            currentVersion: 0
        )

        try dbPool.write { db in
            if makeCurrent {
                // Clear is_current for all threads in this project
                try db.execute(
                    sql: "UPDATE thread SET is_current = 0 WHERE project_id = ?",
                    arguments: [projectID]
                )
            }

            let dbThread = DBChatThread.from(thread, projectID: projectID, isCurrent: makeCurrent, sortOrder: nextCount - 1)
            try dbThread.insert(db)

            // Create default assistant
            let assistant = DBAssistant(
                id: UUID().uuidString.lowercased(),
                threadID: threadID,
                label: "Assistant",
                sortOrder: 0,
                createdAt: DatabaseTimestamp.toNanos(now)
            )
            try assistant.insert(db)
        }

        return thread
    }

    @discardableResult
    func switchCurrentThread(projectID: String, threadID: String) throws -> ProjectChatThreadRecord {
        try dbPool.write { db in
            guard let dbThread = try DBChatThread.fetchOne(db, key: threadID),
                  dbThread.projectID == projectID else {
                throw ProjectChatThreadStoreError.threadNotFound
            }

            // Clear all, then set the target
            try db.execute(
                sql: "UPDATE thread SET is_current = 0 WHERE project_id = ?",
                arguments: [projectID]
            )
            try db.execute(
                sql: "UPDATE thread SET is_current = 1 WHERE id = ?",
                arguments: [threadID]
            )

            return dbThread.toThreadRecord()
        }
    }

    func deleteThread(projectID: String, threadID: String) throws {
        try dbPool.write { db in
            guard let dbThread = try DBChatThread.fetchOne(db, key: threadID),
                  dbThread.projectID == projectID else {
                throw ProjectChatThreadStoreError.threadNotFound
            }

            // Clean up thread model selection from DB
            LLMProviderSettingsStore.shared.removeThreadModelSelection(projectID: projectID, threadID: threadID)

            // CASCADE deletes assistant, message, session_memory
            try DBChatThread.deleteOne(db, key: threadID)

            // If deleted thread was current, pick another
            if dbThread.isCurrent {
                let remaining = try DBChatThread
                    .filter(DBChatThread.Columns.projectID == projectID)
                    .order(DBChatThread.Columns.sortOrder)
                    .fetchAll(db)

                if let first = remaining.first {
                    try db.execute(
                        sql: "UPDATE thread SET is_current = 1 WHERE id = ?",
                        arguments: [first.id]
                    )
                }
            }

            // If no threads remain, create a fresh one
            let count = try DBChatThread
                .filter(DBChatThread.Columns.projectID == projectID)
                .fetchCount(db)

            if count == 0 {
                let now = Date()
                let newID = makeThreadID()
                let newThread = DBChatThread(
                    id: newID,
                    projectID: projectID,
                    title: String(localized: "thread.default_title"),
                    isCurrent: true,
                    sortOrder: 0,
                    currentVersion: 0,
                    createdAt: DatabaseTimestamp.toNanos(now),
                    updatedAt: DatabaseTimestamp.toNanos(now)
                )
                try newThread.insert(db)

                let assistant = DBAssistant(
                    id: UUID().uuidString.lowercased(),
                    threadID: newID,
                    label: "Assistant",
                    sortOrder: 0,
                    createdAt: DatabaseTimestamp.toNanos(now)
                )
                try assistant.insert(db)
            }
        }
    }

    func renameThread(projectID: String, threadID: String, newTitle: String) throws {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        try dbPool.write { db in
            guard var dbThread = try DBChatThread.fetchOne(db, key: threadID),
                  dbThread.projectID == projectID else {
                throw ProjectChatThreadStoreError.threadNotFound
            }
            dbThread.title = trimmed
            dbThread.updatedAt = DatabaseTimestamp.toNanos(Date())
            try dbThread.update(db)
        }
    }

    func touchThread(projectID: String, threadID: String) throws {
        try dbPool.write { db in
            guard var dbThread = try DBChatThread.fetchOne(db, key: threadID),
                  dbThread.projectID == projectID else {
                throw ProjectChatThreadStoreError.threadNotFound
            }
            dbThread.updatedAt = DatabaseTimestamp.toNanos(Date())
            try dbThread.update(db)
        }
    }

    func reorderThreads(projectID: String, orderedIDs: [String]) throws {
        try dbPool.write { db in
            for (index, id) in orderedIDs.enumerated() {
                try db.execute(
                    sql: "UPDATE thread SET sort_order = ? WHERE id = ? AND project_id = ?",
                    arguments: [index, id, projectID]
                )
            }
        }
    }

    // MARK: - Messages

    func loadMessages(projectID: String, threadID: String) -> [ProjectChatPersistedMessage] {
        (try? dbPool.read { db in
            let rows = try DBChatMessage
                .filter(DBChatMessage.Columns.threadID == threadID)
                .order(DBChatMessage.Columns.sortOrder)
                .fetchAll(db)
            return rows.map { $0.toPersistedMessage() }
        }) ?? []
    }

    func saveMessages(projectID: String, threadID: String, messages: [ProjectChatPersistedMessage]) {
        // Look up assistant_id for this thread
        let assistantID: String? = try? dbPool.read { db in
            try DBAssistant
                .filter(DBAssistant.Columns.threadID == threadID)
                .order(DBAssistant.Columns.sortOrder)
                .fetchOne(db)?.id
        }

        try? dbPool.write { db in
            // Delete existing messages
            try DBChatMessage
                .filter(DBChatMessage.Columns.threadID == threadID)
                .deleteAll(db)

            // Batch insert
            for (index, msg) in messages.enumerated() {
                let dbMsg = DBChatMessage.from(msg, threadID: threadID, assistantID: assistantID, sortOrder: index)
                try dbMsg.insert(db)
            }
        }
    }

    // MARK: - Session Memory

    func loadSessionMemory(projectID: String, threadID: String) -> SessionMemory? {
        try? dbPool.read { db in
            try DBSessionMemory.fetchOne(db, key: threadID)?.toSessionMemory()
        }
    }

    func saveSessionMemory(projectID: String, threadID: String, memory: SessionMemory?) {
        try? dbPool.write { db in
            guard let memory else {
                try DBSessionMemory.deleteOne(db, key: threadID)
                return
            }
            let dbMemory = DBSessionMemory.from(memory, threadID: threadID)
            try dbMemory.save(db)
        }
    }

    // MARK: - Project Lifecycle

    func deleteProjectData(projectID: String) {
        try? dbPool.write { db in
            // CASCADE deletes assistant, message, session_memory
            try DBChatThread
                .filter(DBChatThread.Columns.projectID == projectID)
                .deleteAll(db)
        }
    }

    // MARK: - Private Helpers

    private func makeThreadID() -> String {
        UUID().uuidString.lowercased()
    }

    private func normalizedThreadTitle(_ rawTitle: String?, fallback: String) -> String {
        let normalized = rawTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return normalized.isEmpty ? fallback : normalized
    }

    private func projectExists(projectID: String, in db: Database) throws -> Bool {
        try DBProject.fetchOne(db, key: projectID) != nil
    }
}
