//
//  ProjectCapabilityStore.swift
//  Doufu
//

import Foundation
import GRDB

// MARK: - Capability Types

enum CapabilityType: CaseIterable, Sendable {
    case camera
    case microphone
    case location
    case clipboardRead
    case clipboardWrite

    var dbKey: String {
        switch self {
        case .camera: return "camera"
        case .microphone: return "microphone"
        case .location: return "location"
        case .clipboardRead: return "clipboard_read"
        case .clipboardWrite: return "clipboard_write"
        }
    }

    var displayName: String {
        switch self {
        case .camera: return String(localized: "capability.name.camera")
        case .microphone: return String(localized: "capability.name.microphone")
        case .location: return String(localized: "capability.name.location")
        case .clipboardRead: return String(localized: "capability.name.clipboard_read")
        case .clipboardWrite: return String(localized: "capability.name.clipboard_write")
        }
    }

    /// Whether this capability requires a system-level permission (camera/mic/location).
    var hasSystemPermission: Bool {
        switch self {
        case .camera, .microphone, .location: return true
        case .clipboardRead, .clipboardWrite: return false
        }
    }

    static func from(dbKey: String) -> CapabilityType? {
        allCases.first { $0.dbKey == dbKey }
    }
}

enum CapabilityState: Int, Sendable {
    case notRequested = 0
    case allowed = 1
    case denied = 2

    var displayName: String {
        switch self {
        case .notRequested: return String(localized: "capability.state.not_requested")
        case .allowed: return String(localized: "capability.state.allowed")
        case .denied: return String(localized: "capability.state.denied")
        }
    }
}

// MARK: - Store

final class ProjectCapabilityStore: Sendable {
    static let shared = ProjectCapabilityStore()

    private var dbPool: DatabasePool { DatabaseManager.shared.dbPool }

    private init() {}

    func loadCapability(projectID: String, type: CapabilityType) -> CapabilityState {
        do {
            let record = try dbPool.read { db in
                try DBProjectCapability
                    .filter(DBProjectCapability.Columns.projectID == projectID)
                    .filter(DBProjectCapability.Columns.capability == type.dbKey)
                    .fetchOne(db)
            }
            guard let record else { return .notRequested }
            return CapabilityState(rawValue: record.state) ?? .notRequested
        } catch {
            return .notRequested
        }
    }

    func saveCapability(projectID: String, type: CapabilityType, state: CapabilityState) {
        do {
            try dbPool.write { db in
                // Upsert via INSERT OR REPLACE — unique(project_id, capability)
                let now = DatabaseTimestamp.toNanos(Date())
                try db.execute(
                    sql: """
                    INSERT INTO project_capability (project_id, capability, state, updated_at)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(project_id, capability)
                    DO UPDATE SET state = excluded.state, updated_at = excluded.updated_at
                    """,
                    arguments: [projectID, type.dbKey, state.rawValue, now]
                )
            }
        } catch {
            // Best-effort write
        }
    }

    /// Returns all projects that have requested this capability (state != notRequested).
    func loadProjectsWithCapability(type: CapabilityType) -> [(projectID: String, projectName: String, state: CapabilityState)] {
        do {
            let rows = try dbPool.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT pc.project_id, p.title, pc.state
                    FROM project_capability pc
                    JOIN project p ON p.id = pc.project_id
                    WHERE pc.capability = ? AND pc.state != 0
                    ORDER BY pc.updated_at DESC
                """, arguments: [type.dbKey])
            }
            return rows.compactMap { row in
                guard let projectID = row["project_id"] as? String,
                      let title = row["title"] as? String,
                      let stateInt = row["state"] as? Int,
                      let state = CapabilityState(rawValue: stateInt) else { return nil }
                return (projectID: projectID, projectName: title, state: state)
            }
        } catch {
            return []
        }
    }

    /// Returns capabilities that have been requested for a specific project (state != notRequested).
    func loadRequestedCapabilities(projectID: String) -> [(type: CapabilityType, state: CapabilityState)] {
        do {
            let records = try dbPool.read { db in
                try DBProjectCapability
                    .filter(DBProjectCapability.Columns.projectID == projectID)
                    .filter(DBProjectCapability.Columns.state != 0)
                    .fetchAll(db)
            }
            return records.compactMap { record in
                guard let type = CapabilityType.from(dbKey: record.capability),
                      let state = CapabilityState(rawValue: record.state) else { return nil }
                return (type: type, state: state)
            }
        } catch {
            return []
        }
    }

    func resetCapabilities(projectID: String) {
        do {
            _ = try dbPool.write { db in
                try DBProjectCapability
                    .filter(DBProjectCapability.Columns.projectID == projectID)
                    .deleteAll(db)
            }
        } catch {
            // Best-effort delete
        }
    }
}
