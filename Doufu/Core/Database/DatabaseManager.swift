//
//  DatabaseManager.swift
//  Doufu
//

import Foundation
import GRDB

final class DatabaseManager {
    static let shared = DatabaseManager()

    private(set) var dbPool: DatabasePool!

    private init() {}

    func setup() throws {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dbURL = documentsURL.appendingPathComponent("doufu.sqlite")
        dbPool = try DatabasePool(path: dbURL.path)

        var migrator = DatabaseMigrator()
        registerMigrations(&migrator)
        try migrator.migrate(dbPool)
    }

    private func registerMigrations(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v1_initial_schema") { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")

            // project (placeholder for FK targets)
            try db.create(table: "project") { t in
                t.primaryKey("id", .text).notNull()
                t.column("created_at", .integer).notNull()
            }

            // llm_provider
            try db.create(table: "llm_provider") { t in
                t.primaryKey("id", .text).notNull()
                t.column("kind", .integer).notNull()
                t.column("auth_mode", .integer).notNull()
                t.column("label", .text).notNull()
                t.column("base_url", .text).notNull()
                t.column("auto_append_v1", .boolean).notNull().defaults(to: false)
                t.column("chatgpt_account_id", .text)
                t.column("model_id", .text)
                t.column("extra", .text)
                t.column("created_at", .integer).notNull()
                t.column("updated_at", .integer).notNull()
            }

            // llm_provider_model
            try db.create(table: "llm_provider_model") { t in
                t.primaryKey("id", .text).notNull()
                t.column("provider_id", .text).notNull()
                    .references("llm_provider", onDelete: .cascade)
                t.column("model_id", .text).notNull()
                t.column("display_name", .text).notNull()
                t.column("source", .integer).notNull()
                t.column("capabilities", .text)
                t.column("sort_order", .integer).notNull().defaults(to: 0)
            }

            // token_usage
            try db.create(table: "token_usage") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("provider_id", .text).notNull()
                t.column("model_request_id", .text).notNull()
                t.column("project_id", .text)
                t.column("input_tokens", .integer).notNull()
                t.column("output_tokens", .integer).notNull()
                t.column("created_at", .integer).notNull()
            }

            try db.create(index: "idx_token_usage_provider_model",
                          on: "token_usage",
                          columns: ["provider_id", "model_request_id"])

            try db.create(index: "idx_token_usage_project",
                          on: "token_usage",
                          columns: ["project_id"])

            // app_model_selection (singleton row, id always = "default")
            try db.create(table: "app_model_selection") { t in
                t.primaryKey("id", .text).notNull()
                t.column("provider_id", .text).notNull()
                t.column("model_record_id", .text).notNull()
                t.column("reasoning_effort", .text)
                t.column("thinking_enabled", .boolean)
                t.column("extra", .text)
                t.column("updated_at", .integer).notNull()
            }

            // project_model_selection
            try db.create(table: "project_model_selection") { t in
                t.primaryKey("project_id", .text).notNull()
                t.column("provider_id", .text).notNull()
                t.column("model_record_id", .text).notNull()
                t.column("reasoning_effort", .text)
                t.column("thinking_enabled", .boolean)
                t.column("updated_at", .integer).notNull()
            }

            // thread_model_selection
            try db.create(table: "thread_model_selection") { t in
                t.column("project_id", .text).notNull()
                t.column("thread_id", .text).notNull()
                t.column("provider_id", .text).notNull()
                t.column("model_record_id", .text).notNull()
                t.column("reasoning_effort", .text)
                t.column("thinking_enabled", .boolean)
                t.column("updated_at", .integer).notNull()
                t.primaryKey(["project_id", "thread_id"])
            }
        }

        DatabaseLegacyMigration.register(&migrator)

        migrator.registerMigration("v2_chat_tables") { db in
            // thread
            try db.create(table: "thread") { t in
                t.primaryKey("id", .text).notNull()
                t.column("project_id", .text).notNull()
                    .references("project")
                t.column("title", .text).notNull()
                t.column("is_current", .boolean).notNull().defaults(to: false)
                t.column("sort_order", .integer).notNull().defaults(to: 0)
                t.column("current_version", .integer).notNull().defaults(to: 0)
                t.column("created_at", .integer).notNull()
                t.column("updated_at", .integer).notNull()
            }
            try db.create(index: "idx_thread_project",
                          on: "thread",
                          columns: ["project_id"])

            // assistant
            try db.create(table: "assistant") { t in
                t.primaryKey("id", .text).notNull()
                t.column("thread_id", .text).notNull()
                    .references("thread", onDelete: .cascade)
                t.column("label", .text).notNull()
                t.column("sort_order", .integer).notNull().defaults(to: 0)
                t.column("created_at", .integer).notNull()
            }
            try db.create(index: "idx_assistant_thread",
                          on: "assistant",
                          columns: ["thread_id"])

            // message
            try db.create(table: "message") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("thread_id", .text).notNull()
                    .references("thread", onDelete: .cascade)
                t.column("assistant_id", .text)
                    .references("assistant", onDelete: .cascade)
                t.column("message_type", .integer).notNull().defaults(to: 1)
                t.column("content", .text).notNull()
                t.column("sort_order", .integer).notNull()
                t.column("token_usage_id", .integer)
                    .references("token_usage")
                t.column("summary", .text)
                t.column("started_at", .integer)
                t.column("finished_at", .integer)
            }
            try db.create(index: "idx_message_thread",
                          on: "message",
                          columns: ["thread_id"])

            // session_memory
            try db.create(table: "session_memory") { t in
                t.primaryKey("thread_id", .text).notNull()
                    .references("thread", onDelete: .cascade)
                t.column("objective", .text).notNull().defaults(to: "")
                t.column("constraints", .text)
                t.column("changed_files", .text)
                t.column("todo_items", .text)
            }
        }

        migrator.registerMigration("v3_project_and_permission") { db in
            // Extend project table
            try db.alter(table: "project") { t in
                t.add(column: "title", .text).notNull().defaults(to: "")
                t.add(column: "description", .text).notNull().defaults(to: "")
                t.add(column: "sort_order", .integer).notNull().defaults(to: 0)
                t.add(column: "updated_at", .integer).notNull().defaults(to: 0)
            }

            // Permission table
            try db.create(table: "permission") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("project_id", .text).notNull().unique()
                    .references("project", onDelete: .cascade)
                t.column("agent_tool_permission", .integer).notNull().defaults(to: 0)
            }
        }

        DatabaseLegacyMigration.registerV3(&migrator)
    }
}
