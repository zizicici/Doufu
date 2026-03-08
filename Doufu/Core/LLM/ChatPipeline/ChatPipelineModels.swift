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
    typealias Effort = ProjectChatService.ReasoningEffort

    let effort: Effort
}

struct ResponseInputMessage: Encodable {
    let role: String
    let content: [ResponseInputContent]
    /// Optional ID of the originating ChatTurn — used to correlate history entries
    /// back to their tool summaries. Not encoded into the API request.
    let sourceTurnID: String?

    private enum CodingKeys: String, CodingKey {
        case role, content
    }

    init(role: String, text: String, sourceTurnID: String? = nil) {
        self.role = role
        self.sourceTurnID = sourceTurnID
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

    init(
        inputTokens: Int?,
        outputTokens: Int?,
        totalTokens: Int?,
        inputTokensDetails: ResponsesInputTokensDetails?,
        outputTokensDetails: ResponsesOutputTokensDetails?
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.totalTokens = totalTokens
        self.inputTokensDetails = inputTokensDetails
        self.outputTokensDetails = outputTokensDetails
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
    struct MemoryDelta: Decodable {
        let objective: String?
        let constraints: [String]
        let todoItems: [String]
        let notes: [String]

        private enum CodingKeys: String, CodingKey {
            case objective
            case constraints
            case todoItems = "todo_items"
            case notes
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            objective = try container.decodeIfPresent(String.self, forKey: .objective)
            constraints = try container.decodeIfPresent([String].self, forKey: .constraints) ?? []
            todoItems = try container.decodeIfPresent([String].self, forKey: .todoItems) ?? []
            notes = try container.decodeIfPresent([String].self, forKey: .notes) ?? []
        }
    }

    let objective: String?
    let constraints: [String]?
    let todoItems: [String]?
    let memoryDelta: MemoryDelta?
    let threadContentMarkdown: String?
    let threadShouldRollOver: Bool
    let threadNextVersionSummary: String?
    let threadNextVersionContentMarkdown: String?

    private enum CodingKeys: String, CodingKey {
        case objective
        case constraints
        case todoItems = "todo_items"
        case memoryDelta = "memory_delta"
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
        memoryDelta = try container.decodeIfPresent(MemoryDelta.self, forKey: .memoryDelta)

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

    var resolvedObjective: String? {
        memoryDelta?.objective ?? objective
    }

    var resolvedConstraints: [String] {
        let value = memoryDelta?.constraints ?? constraints ?? []
        return value
    }

    var resolvedTodoItems: [String] {
        let value = memoryDelta?.todoItems ?? todoItems ?? []
        return value
    }

    var resolvedNotes: [String] {
        memoryDelta?.notes ?? []
    }
}

// MARK: - Agent Tool Use Models

struct AgentToolDefinition {
    let name: String
    let description: String
    let parameters: JSONValue
}

struct AgentToolCall {
    let id: String
    let name: String
    let argumentsJSON: String

    func decodedArguments() -> [String: Any]? {
        guard let data = argumentsJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object
    }
}

enum AgentStopReason {
    case endTurn
    case toolUse
    case maxTokens
}

struct AgentLLMResponse {
    let textContent: String
    let toolCalls: [AgentToolCall]
    let usage: ResponsesUsage?
    let stopReason: AgentStopReason
    /// Extended thinking content from models that support it (e.g. Claude with thinking enabled).
    let thinkingContent: String?
}

enum AgentConversationItem {
    case userMessage(String)
    case assistantMessage(text: String, toolCalls: [AgentToolCall])
    case toolResult(callID: String, name: String, content: String, isError: Bool)
}
