//
//  LLMTokenUsageStore.swift
//  Doufu
//
//  Created by Codex on 2026/03/06.
//

import Foundation
import GRDB

struct LLMTokenUsageRecord: Equatable, Hashable {
    let projectIdentifier: String?
    let providerID: String
    let providerLabel: String
    let model: String
    let inputTokens: Int64
    let outputTokens: Int64
    let updatedAt: Date

    var totalTokens: Int64 {
        inputTokens + outputTokens
    }
}

struct LLMTokenUsageDailyRecord: Equatable, Hashable {
    let projectIdentifier: String?
    let dayKey: String
    let providerID: String
    let providerLabel: String
    let model: String
    let inputTokens: Int64
    let outputTokens: Int64
    let updatedAt: Date

    var totalTokens: Int64 {
        inputTokens + outputTokens
    }
}

struct LLMTokenUsageTotals {
    let inputTokens: Int64
    let outputTokens: Int64

    var totalTokens: Int64 {
        inputTokens + outputTokens
    }
}

final class LLMTokenUsageStore {
    static let shared = LLMTokenUsageStore()

    private var dbPool: DatabasePool {
        DatabaseManager.shared.dbPool
    }

    init() {}

    @discardableResult
    func recordUsage(
        providerID: String,
        model: String,
        inputTokens: Int?,
        outputTokens: Int?,
        projectIdentifier: String? = nil
    ) -> Int64? {
        let normalizedProviderID = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedProjectIdentifier = normalizeProjectIdentifier(projectIdentifier)

        guard !normalizedProviderID.isEmpty, !normalizedModel.isEmpty else {
            return nil
        }

        let normalizedInput = Int64(max(0, inputTokens ?? 0))
        let normalizedOutput = Int64(max(0, outputTokens ?? 0))
        guard normalizedInput > 0 || normalizedOutput > 0 else {
            return nil
        }

        let row = DBTokenUsage(
            id: nil,
            providerID: normalizedProviderID,
            modelRequestID: normalizedModel,
            projectID: normalizedProjectIdentifier,
            inputTokens: normalizedInput,
            outputTokens: normalizedOutput,
            createdAt: DatabaseTimestamp.toNanos(Date())
        )
        return try? dbPool.write { db in
            try row.insert(db)
            return db.lastInsertedRowID
        }
    }

    func loadRecords(projectIdentifier: String? = nil) -> [LLMTokenUsageRecord] {
        let normalizedProject = normalizeProjectIdentifier(projectIdentifier)
        guard let rows = try? dbPool.read({ db -> [LLMTokenUsageRecord] in
            var sql = """
                SELECT
                    tu.provider_id,
                    tu.model_request_id,
                    COALESCE(p.label, tu.provider_id) AS provider_label,
                    SUM(tu.input_tokens) AS input_tokens,
                    SUM(tu.output_tokens) AS output_tokens,
                    MAX(tu.created_at) AS latest_at
                FROM token_usage tu
                LEFT JOIN llm_provider p ON p.id = tu.provider_id
                """
            var arguments: StatementArguments = []

            if let normalizedProject {
                sql += " WHERE tu.project_id = ?"
                arguments += [normalizedProject]
            }

            sql += " GROUP BY tu.provider_id, tu.model_request_id"
            sql += " ORDER BY latest_at DESC"

            let rows = try Row.fetchAll(db, sql: sql, arguments: arguments)
            return rows.map { row in
                LLMTokenUsageRecord(
                    projectIdentifier: normalizedProject,
                    providerID: row["provider_id"],
                    providerLabel: row["provider_label"],
                    model: row["model_request_id"],
                    inputTokens: row["input_tokens"],
                    outputTokens: row["output_tokens"],
                    updatedAt: DatabaseTimestamp.fromNanos(row["latest_at"])
                )
            }
        }) else {
            return []
        }
        return rows
    }

    func loadTotals(projectIdentifier: String? = nil) -> LLMTokenUsageTotals {
        let normalizedProject = normalizeProjectIdentifier(projectIdentifier)
        guard let totals = try? dbPool.read({ db -> LLMTokenUsageTotals in
            var sql = "SELECT COALESCE(SUM(input_tokens), 0) AS input_total, COALESCE(SUM(output_tokens), 0) AS output_total FROM token_usage"
            var arguments: StatementArguments = []

            if let normalizedProject {
                sql += " WHERE project_id = ?"
                arguments += [normalizedProject]
            }

            guard let row = try Row.fetchOne(db, sql: sql, arguments: arguments) else {
                return LLMTokenUsageTotals(inputTokens: 0, outputTokens: 0)
            }
            return LLMTokenUsageTotals(
                inputTokens: row["input_total"],
                outputTokens: row["output_total"]
            )
        }) else {
            return LLMTokenUsageTotals(inputTokens: 0, outputTokens: 0)
        }
        return totals
    }

    func loadDailyRecords(projectIdentifier: String? = nil) -> [LLMTokenUsageDailyRecord] {
        let normalizedProject = normalizeProjectIdentifier(projectIdentifier)
        guard let rows = try? dbPool.read({ db -> [LLMTokenUsageDailyRecord] in
            // Use strftime on the nanosecond timestamp divided by 1e9 to get day buckets.
            // created_at is in nanoseconds, so divide by 1000000000 to get seconds for strftime.
            var sql = """
                SELECT
                    strftime('%Y-%m-%d', tu.created_at / 1000000000, 'unixepoch', 'localtime') AS day_key,
                    tu.provider_id,
                    tu.model_request_id,
                    COALESCE(p.label, tu.provider_id) AS provider_label,
                    SUM(tu.input_tokens) AS input_tokens,
                    SUM(tu.output_tokens) AS output_tokens,
                    MAX(tu.created_at) AS latest_at
                FROM token_usage tu
                LEFT JOIN llm_provider p ON p.id = tu.provider_id
                """
            var arguments: StatementArguments = []

            if let normalizedProject {
                sql += " WHERE tu.project_id = ?"
                arguments += [normalizedProject]
            }

            sql += " GROUP BY day_key, tu.provider_id, tu.model_request_id"
            sql += " ORDER BY day_key DESC, latest_at DESC"

            let rows = try Row.fetchAll(db, sql: sql, arguments: arguments)
            return rows.map { row in
                LLMTokenUsageDailyRecord(
                    projectIdentifier: normalizedProject,
                    dayKey: row["day_key"],
                    providerID: row["provider_id"],
                    providerLabel: row["provider_label"],
                    model: row["model_request_id"],
                    inputTokens: row["input_tokens"],
                    outputTokens: row["output_tokens"],
                    updatedAt: DatabaseTimestamp.fromNanos(row["latest_at"])
                )
            }
        }) else {
            return []
        }
        return rows
    }

    private func normalizeProjectIdentifier(_ value: String?) -> String? {
        let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return normalized.isEmpty ? nil : normalized
    }
}
