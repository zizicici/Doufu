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
        case messageLoadFailed(threadID: String, underlying: any Swift.Error)
        case messageSaveFailed(threadID: String, underlying: any Swift.Error)
        case sessionMemoryLoadFailed(threadID: String, underlying: any Swift.Error)
        case sessionMemorySaveFailed(threadID: String, underlying: any Swift.Error)

        var errorDescription: String? {
            switch self {
            case .missingProject(let projectID):
                return "Project not found: \(projectID)"
            case .messageLoadFailed(let threadID, let underlying):
                return "Failed to load chat history for thread \(threadID): \(underlying.localizedDescription)"
            case .messageSaveFailed(let threadID, let underlying):
                return "Failed to save chat history for thread \(threadID): \(underlying.localizedDescription)"
            case .sessionMemoryLoadFailed(let threadID, let underlying):
                return "Failed to load session memory for thread \(threadID): \(underlying.localizedDescription)"
            case .sessionMemorySaveFailed(let threadID, let underlying):
                return "Failed to save session memory for thread \(threadID): \(underlying.localizedDescription)"
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
        let threadID = makeThreadID()
        let title = String(localized: "thread.default_title")

        try dbPool.write { db in
            guard try projectExists(projectID: projectID, in: db) else {
                throw Error.missingProject(projectID: projectID)
            }
            try insertThreadWithAssistant(
                db: db, threadID: threadID, projectID: projectID,
                title: title, isCurrent: true, sortOrder: 0
            )
        }

        let now = Date()
        let thread = ProjectChatThreadRecord(
            id: threadID, title: title,
            createdAt: now, updatedAt: now, currentVersion: 0
        )
        return ProjectChatThreadIndex(currentThreadID: thread.id, threads: [thread])
    }

    // MARK: - Thread Management

    @discardableResult
    func createThread(projectID: String, title: String?, makeCurrent: Bool) throws -> ProjectChatThreadRecord {
        let now = Date()
        let threadID = makeThreadID()

        let thread = try dbPool.write { db -> ProjectChatThreadRecord in
            let threadCount = try DBChatThread
                .filter(DBChatThread.Columns.projectID == projectID)
                .fetchCount(db)

            let nextCount = threadCount + 1
            let resolvedTitle = normalizedThreadTitle(
                title,
                fallback: String(format: String(localized: "thread.default_title_format"), nextCount)
            )

            if makeCurrent {
                try db.execute(
                    sql: "UPDATE thread SET is_current = 0 WHERE project_id = ?",
                    arguments: [projectID]
                )
            }

            try insertThreadWithAssistant(
                db: db, threadID: threadID, projectID: projectID,
                title: resolvedTitle, isCurrent: makeCurrent, sortOrder: nextCount - 1
            )

            return ProjectChatThreadRecord(
                id: threadID, title: resolvedTitle,
                createdAt: now, updatedAt: now, currentVersion: 0
            )
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
                try insertThreadWithAssistant(
                    db: db, threadID: makeThreadID(), projectID: projectID,
                    title: String(localized: "thread.default_title"),
                    isCurrent: true, sortOrder: 0
                )
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

    func loadMessages(projectID: String, threadID: String) throws -> [ProjectChatPersistedMessage] {
        do {
            return try dbPool.read { db in
                let rows = try DBChatMessage
                    .filter(DBChatMessage.Columns.threadID == threadID)
                    .order(DBChatMessage.Columns.sortOrder)
                    .fetchAll(db)
                let tokenUsageIDs = Array(Set(rows.compactMap(\.tokenUsageID)))
                let tokenUsageByID: [Int64: DBTokenUsage]

                if tokenUsageIDs.isEmpty {
                    tokenUsageByID = [:]
                } else {
                    let tokenUsageRows = try DBTokenUsage
                        .filter(tokenUsageIDs.contains(Column("id")))
                        .fetchAll(db)
                    tokenUsageByID = Dictionary(
                        uniqueKeysWithValues: tokenUsageRows.compactMap { row in
                            guard let id = row.id else { return nil }
                            return (id, row)
                        }
                    )
                }

                return rows.map { row in
                    row.toPersistedMessage(tokenUsage: row.tokenUsageID.flatMap { tokenUsageByID[$0] })
                }
            }
        } catch {
            throw Error.messageLoadFailed(threadID: threadID, underlying: error)
        }
    }

    func saveMessages(projectID: String, threadID: String, messages: [ProjectChatPersistedMessage]) throws {
        do {
            try dbPool.write { db in
                let assistantID = try DBAssistant
                    .filter(DBAssistant.Columns.threadID == threadID)
                    .order(DBAssistant.Columns.sortOrder)
                    .fetchOne(db)?.id

                try DBChatMessage
                    .filter(DBChatMessage.Columns.threadID == threadID)
                    .deleteAll(db)

                for (index, msg) in messages.enumerated() {
                    let dbMsg = DBChatMessage.from(msg, threadID: threadID, assistantID: assistantID, sortOrder: index)
                    try dbMsg.insert(db)
                }
            }
        } catch {
            throw Error.messageSaveFailed(threadID: threadID, underlying: error)
        }
    }

    /// Incremental variant of `saveMessages` that avoids a full DELETE + INSERT.
    ///
    /// - `unchangedPrefixCount`: number of messages from the start whose DB
    ///   rows are already up-to-date and can be skipped entirely.
    ///
    /// Messages from `unchangedPrefixCount` to `existingRowCount` are UPDATEd
    /// in-place; messages beyond `existingRowCount` are INSERTed. Any surplus
    /// DB rows (if the list shrank) are DELETEd.
    func saveMessagesIncrementally(
        projectID: String,
        threadID: String,
        messages: [ProjectChatPersistedMessage],
        unchangedPrefixCount: Int
    ) throws {
        do {
            try dbPool.write { db in
                let assistantID = try DBAssistant
                    .filter(DBAssistant.Columns.threadID == threadID)
                    .order(DBAssistant.Columns.sortOrder)
                    .fetchOne(db)?.id

                // Fetch existing row IDs ordered by sort_order so we can
                // UPDATE in-place instead of DELETE + re-INSERT.
                let existingRowIDs: [Int64] = try Int64.fetchAll(db, sql: """
                    SELECT id FROM message
                    WHERE thread_id = ?
                    ORDER BY sort_order
                    """, arguments: [threadID])

                let existingCount = existingRowIDs.count
                let newCount = messages.count

                // 1. DELETE surplus rows if the list shrank.
                if existingCount > newCount {
                    let idsToDelete = Array(existingRowIDs[newCount...])
                    try DBChatMessage
                        .filter(idsToDelete.contains(Column("id")))
                        .deleteAll(db)
                }

                // 2. UPDATE rows in [unchangedPrefixCount, min(existingCount, newCount)).
                let updateEnd = min(existingCount, newCount)
                let clampedPrefix = max(0, min(unchangedPrefixCount, updateEnd))
                for i in clampedPrefix..<updateEnd {
                    let rowID = existingRowIDs[i]
                    let msg = messages[i]
                    let dbMsg = DBChatMessage.from(msg, threadID: threadID, assistantID: assistantID, sortOrder: i)
                    try db.execute(sql: """
                        UPDATE message SET
                            assistant_id = ?,
                            message_type = ?,
                            content = ?,
                            sort_order = ?,
                            created_at = ?,
                            token_usage_id = ?,
                            summary = ?,
                            started_at = ?,
                            finished_at = ?
                        WHERE id = ?
                        """, arguments: [
                            dbMsg.assistantID,
                            dbMsg.messageType,
                            dbMsg.content,
                            dbMsg.sortOrder,
                            dbMsg.createdAt,
                            dbMsg.tokenUsageID,
                            dbMsg.summary,
                            dbMsg.startedAt,
                            dbMsg.finishedAt,
                            rowID
                        ])
                }

                // 3. INSERT new rows beyond the existing count.
                for i in existingCount..<newCount {
                    let dbMsg = DBChatMessage.from(messages[i], threadID: threadID, assistantID: assistantID, sortOrder: i)
                    try dbMsg.insert(db)
                }
            }
        } catch {
            throw Error.messageSaveFailed(threadID: threadID, underlying: error)
        }
    }

    // MARK: - Session Memory

    func loadSessionMemory(projectID: String, threadID: String) throws -> SessionMemory? {
        do {
            return try dbPool.read { db in
                try DBSessionMemory.fetchOne(db, key: threadID)?.toSessionMemory()
            }
        } catch {
            throw Error.sessionMemoryLoadFailed(threadID: threadID, underlying: error)
        }
    }

    func saveSessionMemory(projectID: String, threadID: String, memory: SessionMemory?) throws {
        do {
            try dbPool.write { db in
                guard let memory else {
                    try DBSessionMemory.deleteOne(db, key: threadID)
                    return
                }
                let dbMemory = DBSessionMemory.from(memory, threadID: threadID)
                try dbMemory.save(db)
            }
        } catch {
            throw Error.sessionMemorySaveFailed(threadID: threadID, underlying: error)
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

    /// Insert a new thread row and its default assistant in a single
    /// write transaction.  Consolidates logic previously duplicated
    /// across `createFreshIndex`, `createThread`, and `deleteThread`.
    private func insertThreadWithAssistant(
        db: Database,
        threadID: String,
        projectID: String,
        title: String,
        isCurrent: Bool,
        sortOrder: Int
    ) throws {
        let now = Date()
        let dbThread = DBChatThread(
            id: threadID,
            projectID: projectID,
            title: title,
            isCurrent: isCurrent,
            sortOrder: sortOrder,
            currentVersion: 0,
            createdAt: DatabaseTimestamp.toNanos(now),
            updatedAt: DatabaseTimestamp.toNanos(now)
        )
        try dbThread.insert(db)

        let assistant = DBAssistant(
            id: UUID().uuidString.lowercased(),
            threadID: threadID,
            label: "Assistant",
            sortOrder: 0,
            createdAt: DatabaseTimestamp.toNanos(now)
        )
        try assistant.insert(db)
    }

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
