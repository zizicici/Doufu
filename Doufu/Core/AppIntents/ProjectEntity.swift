//
//  ProjectEntity.swift
//  Doufu
//

import AppIntents
import GRDB

struct ProjectEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: LocalizedStringResource("shortcuts.entity.project.type_display_name", defaultValue: "Project"))
    }

    static var defaultQuery = ProjectEntityQuery()

    var id: String
    var name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

struct ProjectEntityQuery: EntityStringQuery {
    private var dbPool: DatabasePool { DatabaseManager.shared.dbPool }

    func entities(for identifiers: [String]) async throws -> [ProjectEntity] {
        return try await dbPool.read { db in
            try DBProject
                .filter(identifiers.contains(DBProject.Columns.id))
                .fetchAll(db)
        }
        .compactMap { dbProject in
            guard projectDirectoryExists(for: dbProject.id) else { return nil }
            return ProjectEntity(
                id: dbProject.id,
                name: dbProject.title.isEmpty ? dbProject.id : dbProject.title
            )
        }
    }

    func suggestedEntities() async throws -> [ProjectEntity] {

        return try await dbPool.read { db in
            try DBProject
                .order(DBProject.Columns.sortOrder.asc, DBProject.Columns.updatedAt.desc)
                .fetchAll(db)
        }
        .compactMap { dbProject in
            guard projectDirectoryExists(for: dbProject.id) else { return nil }
            return ProjectEntity(
                id: dbProject.id,
                name: dbProject.title.isEmpty ? dbProject.id : dbProject.title
            )
        }
    }

    func entities(matching string: String) async throws -> [ProjectEntity] {

        let pattern = "%\(string)%"
        return try await dbPool.read { db in
            try DBProject
                .filter(DBProject.Columns.title.like(pattern))
                .order(DBProject.Columns.sortOrder.asc, DBProject.Columns.updatedAt.desc)
                .fetchAll(db)
        }
        .compactMap { dbProject in
            guard projectDirectoryExists(for: dbProject.id) else { return nil }
            return ProjectEntity(
                id: dbProject.id,
                name: dbProject.title.isEmpty ? dbProject.id : dbProject.title
            )
        }
    }

    private func projectDirectoryExists(for projectID: String) -> Bool {
        guard let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return false
        }
        let projectURL = documentsURL
            .appendingPathComponent("Projects", isDirectory: true)
            .appendingPathComponent(projectID, isDirectory: true)
        return FileManager.default.fileExists(atPath: projectURL.path)
    }
}
