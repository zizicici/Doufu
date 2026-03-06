//
//  LLMTokenUsageStore.swift
//  Doufu
//
//  Created by Codex on 2026/03/06.
//

import Foundation

struct LLMTokenUsageRecord: Codable, Equatable, Hashable {
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

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadRecords() -> [LLMTokenUsageRecord] {
        guard
            let data = defaults.data(forKey: recordsKey),
            let records = try? decoder.decode([LLMTokenUsageRecord].self, from: data)
        else {
            return []
        }

        return records.sorted { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt {
                return lhs.updatedAt > rhs.updatedAt
            }
            if lhs.providerLabel != rhs.providerLabel {
                return lhs.providerLabel.localizedCaseInsensitiveCompare(rhs.providerLabel) == .orderedAscending
            }
            return lhs.model.localizedCaseInsensitiveCompare(rhs.model) == .orderedAscending
        }
    }

    func loadTotals() -> LLMTokenUsageTotals {
        let records = loadRecords()
        let input = records.reduce(Int64(0)) { $0 + $1.inputTokens }
        let output = records.reduce(Int64(0)) { $0 + $1.outputTokens }
        return LLMTokenUsageTotals(inputTokens: input, outputTokens: output)
    }

    func recordUsage(
        providerID: String,
        providerLabel: String,
        model: String,
        inputTokens: Int?,
        outputTokens: Int?
    ) {
        let normalizedProviderID = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedProviderLabel = providerLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalizedProviderID.isEmpty, !normalizedModel.isEmpty else {
            return
        }

        let normalizedInput = max(0, inputTokens ?? 0)
        let normalizedOutput = max(0, outputTokens ?? 0)
        guard normalizedInput > 0 || normalizedOutput > 0 else {
            return
        }

        var records = loadRecords()
        let now = Date()
        let lookupKey = usageLookupKey(providerID: normalizedProviderID, model: normalizedModel)
        if let index = records.firstIndex(where: {
            usageLookupKey(providerID: $0.providerID, model: $0.model) == lookupKey
        }) {
            let existing = records[index]
            records[index] = LLMTokenUsageRecord(
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
    }

    private func usageLookupKey(providerID: String, model: String) -> String {
        providerID.lowercased() + "|" + model.lowercased()
    }

    private func saveRecords(_ records: [LLMTokenUsageRecord]) {
        guard let data = try? encoder.encode(records) else {
            return
        }
        defaults.set(data, forKey: recordsKey)
    }
}
