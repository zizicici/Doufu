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

/// Structured entry for a single tool call and its execution result.
/// Serialized as JSON into the `toolSummary` / DB `summary` column.
struct ToolActivityEntry: Codable, Sendable {
    let toolName: String
    let description: String
    let output: String
    let isError: Bool
    let path: String?
    let lineCount: Int?
    let sizeBytes: Int64?
    let editCount: Int?
    let diffPreview: String?
    let query: String?
    let matchCount: Int?
    let matchedFiles: [String]?
    let url: String?
    let statusCode: Int?
    let errorCount: Int?
    let passed: Bool?
    let isNew: Bool?
    let source: String?
    let destination: String?

    init(
        toolName: String,
        description: String,
        output: String,
        isError: Bool,
        path: String? = nil,
        lineCount: Int? = nil,
        sizeBytes: Int64? = nil,
        editCount: Int? = nil,
        diffPreview: String? = nil,
        query: String? = nil,
        matchCount: Int? = nil,
        matchedFiles: [String]? = nil,
        url: String? = nil,
        statusCode: Int? = nil,
        errorCount: Int? = nil,
        passed: Bool? = nil,
        isNew: Bool? = nil,
        source: String? = nil,
        destination: String? = nil
    ) {
        self.toolName = toolName
        self.description = description
        self.output = output
        self.isError = isError
        self.path = path
        self.lineCount = lineCount
        self.sizeBytes = sizeBytes
        self.editCount = editCount
        self.diffPreview = diffPreview
        self.query = query
        self.matchCount = matchCount
        self.matchedFiles = matchedFiles
        self.url = url
        self.statusCode = statusCode
        self.errorCount = errorCount
        self.passed = passed
        self.isNew = isNew
        self.source = source
        self.destination = destination
    }

    /// Parse a `toolSummary` string. Tries JSON first; returns nil for plain text.
    static func parse(from toolSummary: String) -> [ToolActivityEntry]? {
        guard let data = toolSummary.data(using: .utf8) else { return nil }
        if let entries = try? JSONDecoder().decode([ToolActivityEntry].self, from: data), !entries.isEmpty {
            return entries
        }
        return nil
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

enum ChatProviderError: LocalizedError {
    case noAvailableProvider
    case noThreadAvailable

    var errorDescription: String? {
        switch self {
        case .noAvailableProvider:
            return String(localized: "chat.error.no_provider")
        case .noThreadAvailable:
            return String(localized: "chat.error.no_thread")
        }
    }
}

/// Mutable draft used by model-configuration UI and selection managers.
/// Mirrors the fields of ``ModelSelection`` but is not persisted directly.
struct ModelSelectionDraft: Equatable {
    var selectedProviderID: String
    var selectedModelRecordID: String
    var selectedReasoningEffort: ProjectChatService.ReasoningEffort?
    var selectedThinkingEnabled: Bool?

    static let empty = ModelSelectionDraft(
        selectedProviderID: "",
        selectedModelRecordID: "",
        selectedReasoningEffort: nil,
        selectedThinkingEnabled: nil
    )
}

struct ModelSelection: Codable, Equatable {
    var providerID: String
    var modelRecordID: String
    var reasoningEffort: ProjectChatService.ReasoningEffort?
    var thinkingEnabled: Bool?

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
}
