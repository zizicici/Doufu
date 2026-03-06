//
//  ChatPipelineModels.swift
//  Doufu
//
//  Created by Codex on 2026/03/05.
//

import Foundation

struct ResponsesRequest: Encodable {
    let model: String
    let instructions: String?
    let input: [ResponseInputMessage]
    let stream: Bool?
    let store: Bool?
    var reasoning: ResponsesReasoning?
    var text: ResponsesTextConfiguration?
}

struct ResponsesTextConfiguration: Encodable {
    let format: ResponsesTextFormat
}

struct ResponsesTextFormat: Encodable {
    let type: String
    let name: String
    let schema: JSONValue
    let strict: Bool
}

enum JSONValue: Encodable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case bool(Bool)
    case integer(Int)
    case number(Double)
    case null

    func encode(to encoder: Encoder) throws {
        switch self {
        case let .object(value):
            var container = encoder.container(keyedBy: DynamicCodingKey.self)
            for (key, nestedValue) in value {
                try container.encode(nestedValue, forKey: DynamicCodingKey(key))
            }
        case let .array(value):
            var container = encoder.unkeyedContainer()
            for nestedValue in value {
                try container.encode(nestedValue)
            }
        case let .string(value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case let .bool(value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case let .integer(value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case let .number(value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .null:
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        }
    }
}

struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init(_ stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(stringValue: String) {
        self.init(stringValue)
    }

    init?(intValue: Int) {
        return nil
    }
}

struct ResponsesReasoning: Encodable {
    enum Effort: String, Encodable {
        case low
        case medium
        case high
        case xhigh
    }

    let effort: Effort
}

struct ResponseInputMessage: Encodable {
    let role: String
    let content: [ResponseInputContent]

    init(role: String, text: String) {
        self.role = role
        let normalizedRole = role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let contentType = normalizedRole == "assistant" ? "output_text" : "input_text"
        content = [ResponseInputContent(type: contentType, text: text)]
    }
}

struct ResponseInputContent: Encodable {
    let type: String
    let text: String
}

struct ResponsesResponse: Decodable {
    let output: [ResponsesOutputItem]?
    let usage: ResponsesUsage?
}

struct ResponsesUsage: Decodable {
    let inputTokens: Int?
    let outputTokens: Int?
    let totalTokens: Int?
    let inputTokensDetails: ResponsesInputTokensDetails?
    let outputTokensDetails: ResponsesOutputTokensDetails?

    private enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case totalTokens = "total_tokens"
        case inputTokensDetails = "input_tokens_details"
        case outputTokensDetails = "output_tokens_details"
    }
}

struct ResponsesInputTokensDetails: Decodable {
    let cachedTokens: Int?

    private enum CodingKeys: String, CodingKey {
        case cachedTokens = "cached_tokens"
    }
}

struct ResponsesOutputTokensDetails: Decodable {
    let reasoningTokens: Int?

    private enum CodingKeys: String, CodingKey {
        case reasoningTokens = "reasoning_tokens"
    }
}

struct ResponsesOutputItem: Decodable {
    let type: String
    let content: [ResponsesOutputContent]?
}

struct ResponsesOutputContent: Decodable {
    let type: String
    let text: String?
}

struct ProjectFileSnapshot: Codable {
    let path: String
    let content: String
}

struct ProjectFileCandidate {
    let path: String
    let content: String
    let byteCount: Int
    let lineCount: Int
    let preview: String
}

struct ProjectFileCatalogEntry: Codable {
    let path: String
    let byteCount: Int
    let lineCount: Int
    let preview: String
}

struct FileSelectionPayload: Decodable {
    let selectedPaths: [String]

    private enum CodingKeys: String, CodingKey {
        case selectedPaths = "selected_paths"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        selectedPaths = try container.decodeIfPresent([String].self, forKey: .selectedPaths) ?? []
    }
}

struct TaskPlan {
    let summary: String
    let tasks: [TaskPlanItem]
}

struct TaskPlanItem: Codable {
    let title: String
    let goal: String
}

struct TaskPlanPayload: Decodable {
    let summary: String
    let tasks: [TaskPlanItem]

    private enum CodingKeys: String, CodingKey {
        case summary
        case tasks
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        tasks = try container.decodeIfPresent([TaskPlanItem].self, forKey: .tasks) ?? []
    }
}

enum ExecutionRouteMode: String {
    case directAnswer = "direct_answer"
    case singlePass = "single_pass"
    case multiTask = "multi_task"
}

struct ExecutionRoutePayload: Decodable {
    let mode: ExecutionRouteMode
    let reason: String?
    let assistantMessage: String?
    let memoryUpdate: PatchMemoryUpdate?

    private enum CodingKeys: String, CodingKey {
        case mode
        case reason
        case assistantMessage = "assistant_message"
        case memoryUpdate = "memory_update"
    }

    init(
        mode: ExecutionRouteMode,
        reason: String?,
        assistantMessage: String?,
        memoryUpdate: PatchMemoryUpdate?
    ) {
        self.mode = mode
        self.reason = reason
        self.assistantMessage = assistantMessage
        self.memoryUpdate = memoryUpdate
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawMode = (try container.decodeIfPresent(String.self, forKey: .mode) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        mode = ExecutionRouteMode(rawValue: rawMode) ?? .multiTask
        reason = try container.decodeIfPresent(String.self, forKey: .reason)
        assistantMessage = try container.decodeIfPresent(String.self, forKey: .assistantMessage)
        memoryUpdate = try container.decodeIfPresent(PatchMemoryUpdate.self, forKey: .memoryUpdate)
    }
}

struct MemoryPromptPayload: Encodable {
    let objective: String
    let constraints: [String]
    let changedFiles: [String]
    let todoItems: [String]

    private enum CodingKeys: String, CodingKey {
        case objective
        case constraints
        case changedFiles = "changed_files"
        case todoItems = "todo_items"
    }
}

struct PatchMemoryUpdate: Decodable {
    let objective: String?
    let constraints: [String]?
    let todoItems: [String]?
    let threadContentMarkdown: String?
    let threadShouldRollOver: Bool
    let threadNextVersionSummary: String?
    let threadNextVersionContentMarkdown: String?

    private enum CodingKeys: String, CodingKey {
        case objective
        case constraints
        case todoItems = "todo_items"
        case threadContentMarkdown = "thread_content_markdown"
        case threadShouldRollOver = "thread_should_rollover"
        case threadNextVersionSummary = "thread_next_version_summary"
        case threadNextVersionContentMarkdown = "thread_next_version_content_markdown"
        case threadMemory = "thread_memory"
    }

    private enum ThreadMemoryCodingKeys: String, CodingKey {
        case contentMarkdown = "content_markdown"
        case shouldRollOver = "should_rollover"
        case nextVersionSummary = "next_version_summary"
        case nextVersionContentMarkdown = "next_version_content_markdown"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        objective = try container.decodeIfPresent(String.self, forKey: .objective)
        constraints = try container.decodeIfPresent([String].self, forKey: .constraints)
        todoItems = try container.decodeIfPresent([String].self, forKey: .todoItems)

        if let flattened = try container.decodeIfPresent(String.self, forKey: .threadContentMarkdown) {
            threadContentMarkdown = flattened
        } else if container.contains(.threadMemory) {
            let threadContainer = try container.nestedContainer(keyedBy: ThreadMemoryCodingKeys.self, forKey: .threadMemory)
            threadContentMarkdown = try threadContainer.decodeIfPresent(String.self, forKey: .contentMarkdown)
        } else {
            threadContentMarkdown = nil
        }

        if let flattenedShouldRollOver = try container.decodeIfPresent(Bool.self, forKey: .threadShouldRollOver) {
            threadShouldRollOver = flattenedShouldRollOver
        } else if container.contains(.threadMemory) {
            let threadContainer = try container.nestedContainer(keyedBy: ThreadMemoryCodingKeys.self, forKey: .threadMemory)
            threadShouldRollOver = try threadContainer.decodeIfPresent(Bool.self, forKey: .shouldRollOver) ?? false
        } else {
            threadShouldRollOver = false
        }

        if let flattenedSummary = try container.decodeIfPresent(String.self, forKey: .threadNextVersionSummary) {
            threadNextVersionSummary = flattenedSummary
        } else if container.contains(.threadMemory) {
            let threadContainer = try container.nestedContainer(keyedBy: ThreadMemoryCodingKeys.self, forKey: .threadMemory)
            threadNextVersionSummary = try threadContainer.decodeIfPresent(String.self, forKey: .nextVersionSummary)
        } else {
            threadNextVersionSummary = nil
        }

        if let flattenedContent = try container.decodeIfPresent(String.self, forKey: .threadNextVersionContentMarkdown) {
            threadNextVersionContentMarkdown = flattenedContent
        } else if container.contains(.threadMemory) {
            let threadContainer = try container.nestedContainer(keyedBy: ThreadMemoryCodingKeys.self, forKey: .threadMemory)
            threadNextVersionContentMarkdown = try threadContainer.decodeIfPresent(String.self, forKey: .nextVersionContentMarkdown)
        } else {
            threadNextVersionContentMarkdown = nil
        }
    }
}

struct PatchThreadMemoryUpdate: Decodable {
    let contentMarkdown: String?
    let shouldRollOver: Bool
    let nextVersionSummary: String?
    let nextVersionContentMarkdown: String?

    private enum CodingKeys: String, CodingKey {
        case contentMarkdown = "content_markdown"
        case shouldRollOver = "should_rollover"
        case nextVersionSummary = "next_version_summary"
        case nextVersionContentMarkdown = "next_version_content_markdown"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        contentMarkdown = try container.decodeIfPresent(String.self, forKey: .contentMarkdown)
        shouldRollOver = try container.decodeIfPresent(Bool.self, forKey: .shouldRollOver) ?? false
        nextVersionSummary = try container.decodeIfPresent(String.self, forKey: .nextVersionSummary)
        nextVersionContentMarkdown = try container.decodeIfPresent(String.self, forKey: .nextVersionContentMarkdown)
    }
}

struct PatchPayload: Decodable {
    let assistantMessage: String
    let changes: [PatchChange]
    let searchReplaceChanges: [SearchReplaceFileChange]
    let memoryUpdate: PatchMemoryUpdate?
    let threadMemoryUpdate: PatchThreadMemoryUpdate?

    private enum CodingKeys: String, CodingKey {
        case assistantMessage = "assistant_message"
        case changes
        case searchReplaceChanges = "search_replace_changes"
        case memoryUpdate = "memory_update"
        case threadMemoryUpdate = "thread_memory_update"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        assistantMessage = try container.decodeIfPresent(String.self, forKey: .assistantMessage) ?? ""
        changes = try container.decodeIfPresent([PatchChange].self, forKey: .changes) ?? []
        searchReplaceChanges = try container.decodeIfPresent([SearchReplaceFileChange].self, forKey: .searchReplaceChanges) ?? []
        memoryUpdate = try container.decodeIfPresent(PatchMemoryUpdate.self, forKey: .memoryUpdate)
        threadMemoryUpdate = try container.decodeIfPresent(PatchThreadMemoryUpdate.self, forKey: .threadMemoryUpdate)
    }
}

struct DirectAnswerPayload: Decodable {
    let assistantMessage: String
    let memoryUpdate: PatchMemoryUpdate?

    private enum CodingKeys: String, CodingKey {
        case assistantMessage = "assistant_message"
        case memoryUpdate = "memory_update"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        assistantMessage = try container.decodeIfPresent(String.self, forKey: .assistantMessage) ?? ""
        memoryUpdate = try container.decodeIfPresent(PatchMemoryUpdate.self, forKey: .memoryUpdate)
    }
}

struct PatchChange: Decodable {
    let path: String
    let content: String
}

struct SearchReplaceFileChange: Decodable {
    let path: String
    let operations: [SearchReplaceOperation]

    private enum CodingKeys: String, CodingKey {
        case path
        case operations
        case edits
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decodeIfPresent(String.self, forKey: .path) ?? ""
        operations = try container.decodeIfPresent([SearchReplaceOperation].self, forKey: .operations)
            ?? container.decodeIfPresent([SearchReplaceOperation].self, forKey: .edits)
            ?? []
    }
}

struct SearchReplaceOperation: Decodable {
    let search: String
    let replace: String
    let replaceAll: Bool
    let ignoreCase: Bool

    private enum CodingKeys: String, CodingKey {
        case search
        case replace
        case replaceAll = "replace_all"
        case ignoreCase = "ignore_case"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        search = try container.decodeIfPresent(String.self, forKey: .search) ?? ""
        replace = try container.decodeIfPresent(String.self, forKey: .replace) ?? ""
        replaceAll = try container.decodeIfPresent(Bool.self, forKey: .replaceAll) ?? false
        ignoreCase = try container.decodeIfPresent(Bool.self, forKey: .ignoreCase) ?? false
    }
}
