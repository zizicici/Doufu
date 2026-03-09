//
//  LLMTokenUsageStore.swift
//  Doufu
//
//  Created by Codex on 2026/03/06.
//

import Foundation

struct LLMTokenUsageRecord: Codable, Equatable, Hashable {
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

struct LLMTokenUsageDailyRecord: Codable, Equatable, Hashable {
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

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let recordsKey = "llm.token_usage.records.v1"
    private let dailyRecordsKey = "llm.token_usage.daily_records.v1"
    private let queue = DispatchQueue(label: "com.doufu.token-usage-store", qos: .utility)

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadRecords(projectIdentifier: String? = nil) -> [LLMTokenUsageRecord] {
        let rawRecords = queue.sync { loadRawRecords() }
        let normalizedProjectIdentifier = normalizeProjectIdentifier(projectIdentifier)
        let filteredRecords: [LLMTokenUsageRecord]
        if let normalizedProjectIdentifier {
            filteredRecords = rawRecords.filter {
                normalizeProjectIdentifier($0.projectIdentifier) == normalizedProjectIdentifier
            }
        } else {
            filteredRecords = rawRecords
        }

        let groupedProjectIdentifier: String? = normalizedProjectIdentifier
        let groupedRecords = aggregateRecords(
            filteredRecords,
            groupedProjectIdentifier: groupedProjectIdentifier
        )
        return groupedRecords.sorted { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt {
                return lhs.updatedAt > rhs.updatedAt
            }
            if lhs.providerLabel != rhs.providerLabel {
                return lhs.providerLabel.localizedCaseInsensitiveCompare(rhs.providerLabel) == .orderedAscending
            }
            return lhs.model.localizedCaseInsensitiveCompare(rhs.model) == .orderedAscending
        }
    }

    func loadTotals(projectIdentifier: String? = nil) -> LLMTokenUsageTotals {
        let records = loadRecords(projectIdentifier: projectIdentifier)
        let input = records.reduce(Int64(0)) { $0 + $1.inputTokens }
        let output = records.reduce(Int64(0)) { $0 + $1.outputTokens }
        return LLMTokenUsageTotals(inputTokens: input, outputTokens: output)
    }

    func loadDailyRecords(projectIdentifier: String? = nil) -> [LLMTokenUsageDailyRecord] {
        let rawRecords = queue.sync { loadRawDailyRecords() }
        let normalizedProjectIdentifier = normalizeProjectIdentifier(projectIdentifier)
        let filteredRecords: [LLMTokenUsageDailyRecord]
        if let normalizedProjectIdentifier {
            filteredRecords = rawRecords.filter {
                normalizeProjectIdentifier($0.projectIdentifier) == normalizedProjectIdentifier
            }
        } else {
            filteredRecords = rawRecords
        }

        let groupedProjectIdentifier: String? = normalizedProjectIdentifier
        let groupedRecords = aggregateDailyRecords(
            filteredRecords,
            groupedProjectIdentifier: groupedProjectIdentifier
        )
        return groupedRecords.sorted { lhs, rhs in
            if lhs.dayKey != rhs.dayKey {
                return lhs.dayKey > rhs.dayKey
            }
            if lhs.updatedAt != rhs.updatedAt {
                return lhs.updatedAt > rhs.updatedAt
            }
            if lhs.providerLabel != rhs.providerLabel {
                return lhs.providerLabel.localizedCaseInsensitiveCompare(rhs.providerLabel) == .orderedAscending
            }
            return lhs.model.localizedCaseInsensitiveCompare(rhs.model) == .orderedAscending
        }
    }

    func recordUsage(
        providerID: String,
        providerLabel: String,
        model: String,
        inputTokens: Int?,
        outputTokens: Int?,
        projectIdentifier: String? = nil
    ) {
        let normalizedProviderID = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedProviderLabel = providerLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedProjectIdentifier = normalizeProjectIdentifier(projectIdentifier)

        guard !normalizedProviderID.isEmpty, !normalizedModel.isEmpty else {
            return
        }

        let normalizedInput = max(0, inputTokens ?? 0)
        let normalizedOutput = max(0, outputTokens ?? 0)
        guard normalizedInput > 0 || normalizedOutput > 0 else {
            return
        }

        queue.sync {
            var records = loadRawRecords()
            let now = Date()
            let lookupKey = usageLookupKey(
                providerID: normalizedProviderID,
                model: normalizedModel,
                projectIdentifier: normalizedProjectIdentifier
            )
            if let index = records.firstIndex(where: {
                usageLookupKey(
                    providerID: $0.providerID,
                    model: $0.model,
                    projectIdentifier: normalizeProjectIdentifier($0.projectIdentifier)
                ) == lookupKey
            }) {
                let existing = records[index]
                records[index] = LLMTokenUsageRecord(
                    projectIdentifier: normalizedProjectIdentifier,
                    providerID: existing.providerID,
                    providerLabel: normalizedProviderLabel.isEmpty ? existing.providerLabel : normalizedProviderLabel,
                    model: existing.model,
                    inputTokens: existing.inputTokens + Int64(normalizedInput),
                    outputTokens: existing.outputTokens + Int64(normalizedOutput),
                    updatedAt: now
                )
            } else {
                records.append(
                    LLMTokenUsageRecord(
                        projectIdentifier: normalizedProjectIdentifier,
                        providerID: normalizedProviderID,
                        providerLabel: normalizedProviderLabel.isEmpty ? normalizedProviderID : normalizedProviderLabel,
                        model: normalizedModel,
                        inputTokens: Int64(normalizedInput),
                        outputTokens: Int64(normalizedOutput),
                        updatedAt: now
                    )
                )
            }

            saveRecords(records)
            upsertDailyUsageRecord(
                providerID: normalizedProviderID,
                providerLabel: normalizedProviderLabel.isEmpty ? normalizedProviderID : normalizedProviderLabel,
                model: normalizedModel,
                inputTokens: Int64(normalizedInput),
                outputTokens: Int64(normalizedOutput),
                projectIdentifier: normalizedProjectIdentifier,
                timestamp: now
            )
        }
    }

    private func loadRawRecords() -> [LLMTokenUsageRecord] {
        guard let data = defaults.data(forKey: recordsKey) else {
            return []
        }
        do {
            return try decoder.decode([LLMTokenUsageRecord].self, from: data)
        } catch {
            #if DEBUG
            print("[LLMTokenUsageStore] Failed to decode records: \(error)")
            #endif
            return []
        }
    }

    private func aggregateRecords(
        _ records: [LLMTokenUsageRecord],
        groupedProjectIdentifier: String?
    ) -> [LLMTokenUsageRecord] {
        var grouped: [String: LLMTokenUsageRecord] = [:]
        for record in records {
            let key = usageLookupKey(
                providerID: record.providerID,
                model: record.model,
                projectIdentifier: groupedProjectIdentifier
            )
            if let existing = grouped[key] {
                let preferredUpdatedAt = max(existing.updatedAt, record.updatedAt)
                let preferredProviderLabel: String
                if record.updatedAt >= existing.updatedAt {
                    preferredProviderLabel = record.providerLabel
                } else {
                    preferredProviderLabel = existing.providerLabel
                }
                grouped[key] = LLMTokenUsageRecord(
                    projectIdentifier: groupedProjectIdentifier,
                    providerID: existing.providerID,
                    providerLabel: preferredProviderLabel,
                    model: existing.model,
                    inputTokens: existing.inputTokens + record.inputTokens,
                    outputTokens: existing.outputTokens + record.outputTokens,
                    updatedAt: preferredUpdatedAt
                )
            } else {
                grouped[key] = LLMTokenUsageRecord(
                    projectIdentifier: groupedProjectIdentifier,
                    providerID: record.providerID,
                    providerLabel: record.providerLabel,
                    model: record.model,
                    inputTokens: record.inputTokens,
                    outputTokens: record.outputTokens,
                    updatedAt: record.updatedAt
                )
            }
        }
        return Array(grouped.values)
    }

    private func loadRawDailyRecords() -> [LLMTokenUsageDailyRecord] {
        guard let data = defaults.data(forKey: dailyRecordsKey) else {
            return []
        }
        do {
            return try decoder.decode([LLMTokenUsageDailyRecord].self, from: data)
        } catch {
            #if DEBUG
            print("[LLMTokenUsageStore] Failed to decode daily records: \(error)")
            #endif
            return []
        }
    }

    private func upsertDailyUsageRecord(
        providerID: String,
        providerLabel: String,
        model: String,
        inputTokens: Int64,
        outputTokens: Int64,
        projectIdentifier: String?,
        timestamp: Date
    ) {
        var records = loadRawDailyRecords()
        let dayKey = dayKeyString(for: timestamp)
        let lookupKey = dailyUsageLookupKey(
            dayKey: dayKey,
            providerID: providerID,
            model: model,
            projectIdentifier: projectIdentifier
        )

        if let index = records.firstIndex(where: {
            dailyUsageLookupKey(
                dayKey: $0.dayKey,
                providerID: $0.providerID,
                model: $0.model,
                projectIdentifier: normalizeProjectIdentifier($0.projectIdentifier)
            ) == lookupKey
        }) {
            let existing = records[index]
            records[index] = LLMTokenUsageDailyRecord(
                projectIdentifier: projectIdentifier,
                dayKey: existing.dayKey,
                providerID: existing.providerID,
                providerLabel: providerLabel.isEmpty ? existing.providerLabel : providerLabel,
                model: existing.model,
                inputTokens: existing.inputTokens + inputTokens,
                outputTokens: existing.outputTokens + outputTokens,
                updatedAt: timestamp
            )
        } else {
            records.append(
                LLMTokenUsageDailyRecord(
                    projectIdentifier: projectIdentifier,
                    dayKey: dayKey,
                    providerID: providerID,
                    providerLabel: providerLabel,
                    model: model,
                    inputTokens: inputTokens,
                    outputTokens: outputTokens,
                    updatedAt: timestamp
                )
            )
        }

        saveDailyRecords(records)
    }

    private func aggregateDailyRecords(
        _ records: [LLMTokenUsageDailyRecord],
        groupedProjectIdentifier: String?
    ) -> [LLMTokenUsageDailyRecord] {
        var grouped: [String: LLMTokenUsageDailyRecord] = [:]
        for record in records {
            let key = dailyUsageLookupKey(
                dayKey: record.dayKey,
                providerID: record.providerID,
                model: record.model,
                projectIdentifier: groupedProjectIdentifier
            )
            if let existing = grouped[key] {
                let preferredUpdatedAt = max(existing.updatedAt, record.updatedAt)
                let preferredProviderLabel: String
                if record.updatedAt >= existing.updatedAt {
                    preferredProviderLabel = record.providerLabel
                } else {
                    preferredProviderLabel = existing.providerLabel
                }
                grouped[key] = LLMTokenUsageDailyRecord(
                    projectIdentifier: groupedProjectIdentifier,
                    dayKey: existing.dayKey,
                    providerID: existing.providerID,
                    providerLabel: preferredProviderLabel,
                    model: existing.model,
                    inputTokens: existing.inputTokens + record.inputTokens,
                    outputTokens: existing.outputTokens + record.outputTokens,
                    updatedAt: preferredUpdatedAt
                )
            } else {
                grouped[key] = LLMTokenUsageDailyRecord(
                    projectIdentifier: groupedProjectIdentifier,
                    dayKey: record.dayKey,
                    providerID: record.providerID,
                    providerLabel: record.providerLabel,
                    model: record.model,
                    inputTokens: record.inputTokens,
                    outputTokens: record.outputTokens,
                    updatedAt: record.updatedAt
                )
            }
        }
        return Array(grouped.values)
    }

    private func usageLookupKey(
        providerID: String,
        model: String,
        projectIdentifier: String?
    ) -> String {
        let normalizedProject = normalizeProjectIdentifier(projectIdentifier) ?? "*"
        return normalizedProject + "|" + providerID.lowercased() + "|" + model.lowercased()
    }

    private func dailyUsageLookupKey(
        dayKey: String,
        providerID: String,
        model: String,
        projectIdentifier: String?
    ) -> String {
        let normalizedProject = normalizeProjectIdentifier(projectIdentifier) ?? "*"
        return dayKey + "|" + normalizedProject + "|" + providerID.lowercased() + "|" + model.lowercased()
    }

    private func dayKeyString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func normalizeProjectIdentifier(_ value: String?) -> String? {
        let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return normalized.isEmpty ? nil : normalized
    }

    private func saveRecords(_ records: [LLMTokenUsageRecord]) {
        guard let data = try? encoder.encode(records) else {
            return
        }
        defaults.set(data, forKey: recordsKey)
    }

    private func saveDailyRecords(_ records: [LLMTokenUsageDailyRecord]) {
        guard let data = try? encoder.encode(records) else {
            return
        }
        defaults.set(data, forKey: dailyRecordsKey)
    }
}
