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
        inputTokens = try container.decodeIfPresent(Int64.self, forKey: .inputTokens)
        outputTokens = try container.decodeIfPresent(Int64.self, forKey: .outputTokens)
        toolSummary = try container.decodeIfPresent(String.self, forKey: .toolSummary)
    }
}

enum ProjectChatThreadStoreError: LocalizedError {
    case threadNotFound
    case invalidThreadData
    case indexReadFailed(underlying: Error)
    case indexCorrupted(backupPath: String, underlying: Error)

    var errorDescription: String? {
        switch self {
        case .threadNotFound:
            return String(localized: "thread_store.error.thread_not_found")
        case .invalidThreadData:
            return String(localized: "thread_store.error.invalid_thread_data")
        case .indexReadFailed(let underlying):
            return "Failed to read thread index: \(underlying.localizedDescription)"
        case .indexCorrupted(let backupPath, _):
            return "Thread index was corrupted. A backup was saved to \(backupPath). Starting fresh."
        }
    }
}

struct ModelSelection: Codable, Equatable {
    let providerID: String
    let modelRecordID: String
}

struct ThreadModelSelection: Codable, Equatable {
    var selectedProviderID: String
    var selectedModelIDByProviderID: [String: String]
    var selectedReasoningEffortsByModelID: [String: String]
    var selectedAnthropicThinkingEnabledByModelID: [String: Bool]
    var selectedGeminiThinkingEnabledByModelID: [String: Bool]
}
