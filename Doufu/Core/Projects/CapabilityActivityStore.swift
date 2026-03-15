//
//  CapabilityActivityStore.swift
//  Doufu
//

import Foundation
import GRDB

// MARK: - Types

enum CapabilityActivityEventType: Int, Sendable {
    case requested = 0
    case changed = 1
    case serviceUsed = 2
}

struct CapabilityActivityEntry: Sendable {
    let id: Int64
    let projectID: String
    let projectName: String
    let capability: CapabilityType
    let eventType: CapabilityActivityEventType
    let detail: String?
    let createdAt: Date
}

// MARK: - Store

final class CapabilityActivityStore: Sendable {
    static let shared = CapabilityActivityStore()

    private var dbPool: DatabasePool { DatabaseManager.shared.dbPool }

    private init() {}

    func recordEvent(
        projectID: String,
        capability: CapabilityType,
        event: CapabilityActivityEventType,
        detail: String?
    ) {
        do {
            try dbPool.write { db in
                let now = DatabaseTimestamp.toNanos(Date())
                try db.execute(
                    sql: """
                    INSERT INTO capability_activity (project_id, capability, event_type, detail, created_at)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                    arguments: [projectID, capability.dbKey, event.rawValue, detail, now]
                )
            }
        } catch {
            // Best-effort write
        }
    }

    /// Load activities for a specific project (all capability types).
    func loadActivities(projectID: String) -> [CapabilityActivityEntry] {
        loadActivities(
            where: "ca.project_id = ?",
            arguments: [projectID]
        )
    }

    /// Load activities for a specific capability type (all projects).
    func loadActivities(capability: CapabilityType) -> [CapabilityActivityEntry] {
        loadActivities(
            where: "ca.capability = ?",
            arguments: [capability.dbKey]
        )
    }

    private func loadActivities(
        where clause: String,
        arguments: [any DatabaseValueConvertible]
    ) -> [CapabilityActivityEntry] {
        do {
            let rows = try dbPool.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT ca.id, ca.project_id, p.title, ca.capability,
                           ca.event_type, ca.detail, ca.created_at
                    FROM capability_activity ca
                    JOIN project p ON p.id = ca.project_id
                    WHERE \(clause)
                    ORDER BY ca.created_at DESC
                """, arguments: StatementArguments(arguments))
            }
            return rows.compactMap { row in
                guard
                    let id: Int64 = row["id"],
                    let projectID: String = row["project_id"],
                    let title: String = row["title"],
                    let capKey: String = row["capability"],
                    let eventInt: Int = row["event_type"],
                    let createdNanos: Int64 = row["created_at"],
                    let cap = CapabilityType.from(dbKey: capKey),
                    let event = CapabilityActivityEventType(rawValue: eventInt)
                else { return nil }
                return CapabilityActivityEntry(
                    id: id,
                    projectID: projectID,
                    projectName: title,
                    capability: cap,
                    eventType: event,
                    detail: row["detail"],
                    createdAt: DatabaseTimestamp.fromNanos(createdNanos)
                )
            }
        } catch {
            return []
        }
    }
}
