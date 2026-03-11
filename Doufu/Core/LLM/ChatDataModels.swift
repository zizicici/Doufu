//
//  ChatDataModels.swift
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
    let tokenUsageID: Int64?
    let inputTokens: Int64?
    let outputTokens: Int64?
    let toolSummary: String?

    init(
        role: String,
        text: String,
        createdAt: Date,
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        isProgress: Bool = false,
        tokenUsageID: Int64? = nil,
        inputTokens: Int64? = nil,
        outputTokens: Int64? = nil,
        toolSummary: String? = nil
    ) {
        self.role = role
        self.text = text
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.isProgress = isProgress
        self.tokenUsageID = tokenUsageID
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.toolSummary = toolSummary
    }

    private enum CodingKeys: String, CodingKey {
        case role
        case text
        case createdAt
        case startedAt
        case finishedAt
        case isProgress
        case tokenUsageID
        case inputTokens
        case outputTokens
        case toolSummary
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = try container.decode(String.self, forKey: .role)
        text = try container.decode(String.self, forKey: .text)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt)
        finishedAt = try container.decodeIfPresent(Date.self, forKey: .finishedAt)
        isProgress = try container.decodeIfPresent(Bool.self, forKey: .isProgress) ?? false
        tokenUsageID = try container.decodeIfPresent(Int64.self, forKey: .tokenUsageID)
        inputTokens = try container.decodeIfPresent(Int64.self, forKey: .inputTokens)
        outputTokens = try container.decodeIfPresent(Int64.self, forKey: .outputTokens)
        toolSummary = try container.decodeIfPresent(String.self, forKey: .toolSummary)
    }
}

enum ProjectChatThreadStoreError: LocalizedError {
    case threadNotFound

    var errorDescription: String? {
        switch self {
        case .threadNotFound:
            return String(localized: "thread_store.error.thread_not_found")
        }
    }
}

struct ModelSelection: Codable, Equatable {
    var providerID: String
    var modelRecordID: String
    var reasoningEffort: ProjectChatService.ReasoningEffort?
    var thinkingEnabled: Bool?

    private enum CodingKeys: String, CodingKey {
        case providerID
        case modelRecordID
        case reasoningEffort
        case thinkingEnabled
    }

    private enum LegacyCodingKeys: String, CodingKey {
        case selectedProviderID
        case selectedModelIDByProviderID
        case selectedReasoningEffortsByModelID
        case selectedAnthropicThinkingEnabledByModelID
        case selectedGeminiThinkingEnabledByModelID
    }

    init(
        providerID: String,
        modelRecordID: String,
        reasoningEffort: ProjectChatService.ReasoningEffort? = nil,
        thinkingEnabled: Bool? = nil
    ) {
        self.providerID = providerID
        self.modelRecordID = modelRecordID
        self.reasoningEffort = reasoningEffort
        self.thinkingEnabled = thinkingEnabled
    }

    init(from decoder: Decoder) throws {
        if let container = try? decoder.container(keyedBy: CodingKeys.self),
           let providerID = try? container.decode(String.self, forKey: .providerID),
           let modelRecordID = try? container.decode(String.self, forKey: .modelRecordID) {
            self.providerID = providerID
            self.modelRecordID = modelRecordID
            self.reasoningEffort = try container.decodeIfPresent(ProjectChatService.ReasoningEffort.self, forKey: .reasoningEffort)
            self.thinkingEnabled = try container.decodeIfPresent(Bool.self, forKey: .thinkingEnabled)
            return
        }

        let container = try? decoder.container(keyedBy: LegacyCodingKeys.self)
        let providerID = (try? container?.decode(String.self, forKey: .selectedProviderID)) ?? ""
        let selectedModelIDByProviderID = (try? container?.decodeIfPresent([String: String].self, forKey: .selectedModelIDByProviderID)) ?? [:]
        let trimmedProviderID = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawModelRecordID = selectedModelIDByProviderID[trimmedProviderID] ?? ""
        let trimmedModelRecordID = rawModelRecordID.trimmingCharacters(in: .whitespacesAndNewlines)

        let modelKey = trimmedModelRecordID.lowercased()
        let selectedReasoningEffortsByModelID = (try? container?.decodeIfPresent([String: String].self, forKey: .selectedReasoningEffortsByModelID)) ?? [:]
        let selectedAnthropicThinkingEnabledByModelID = (try? container?.decodeIfPresent([String: Bool].self, forKey: .selectedAnthropicThinkingEnabledByModelID)) ?? [:]
        let selectedGeminiThinkingEnabledByModelID = (try? container?.decodeIfPresent([String: Bool].self, forKey: .selectedGeminiThinkingEnabledByModelID)) ?? [:]

        self.providerID = trimmedProviderID
        self.modelRecordID = trimmedModelRecordID
        self.reasoningEffort = selectedReasoningEffortsByModelID[modelKey]
            .flatMap(ProjectChatService.ReasoningEffort.init(rawValue:))
        self.thinkingEnabled = selectedAnthropicThinkingEnabledByModelID[modelKey]
            ?? selectedGeminiThinkingEnabledByModelID[modelKey]
    }
}
