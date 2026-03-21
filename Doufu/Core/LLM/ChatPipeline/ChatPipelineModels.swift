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
    var maxOutputTokens: Int?
    var reasoning: ResponsesReasoning?
    var text: ResponsesTextConfiguration?

    private enum CodingKeys: String, CodingKey {
        case model, instructions, input, stream, store, reasoning, text
        case maxOutputTokens = "max_output_tokens"
    }
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
    let objective: String?
    let constraints: [String]?
    let todoItems: [String]?

    init(objective: String? = nil, constraints: [String]? = nil, todoItems: [String]? = nil) {
        self.objective = objective
        self.constraints = constraints
        self.todoItems = todoItems
    }

    private enum CodingKeys: String, CodingKey {
        case objective
        case constraints
        case todoItems = "todo_items"
    }

    var resolvedObjective: String? {
        objective
    }

    var resolvedConstraints: [String] {
        constraints ?? []
    }

    var resolvedTodoItems: [String] {
        todoItems ?? []
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

/// An Anthropic thinking block that must be passed back unchanged in multi-turn tool use.
/// Claude 4+ produces `.thinking`; Claude 3.7 Sonnet may also produce `.redacted`.
enum AnthropicThinkingBlock {
    /// Normal thinking with text and cryptographic signature.
    case thinking(text: String, signature: String)
    /// Redacted thinking (safety-flagged) — encrypted opaque data, must be passed back as-is.
    case redacted(data: String)
}

/// Opaque provider-specific state that must be replayed across tool-use rounds.
/// Each provider populates the variant it needs; other providers leave it nil.
enum ProviderReplayState {
    /// Anthropic: complete thinking blocks (text + signature) required for multi-turn tool use.
    case anthropicThinking([AnthropicThinkingBlock])
    /// OpenAI: reasoning output items that should be included in subsequent input arrays.
    case openAIReasoning([JSONValue])
}

struct AgentLLMResponse {
    let textContent: String
    let toolCalls: [AgentToolCall]
    let usage: ResponsesUsage?
    let stopReason: AgentStopReason
    /// Extended thinking/reasoning content for UI display (e.g. Claude thinking, MiMo reasoning).
    let thinkingContent: String?
    /// Provider-specific state to replay across tool-use rounds.
    let replayState: ProviderReplayState?
}

struct AssistantMessage {
    let text: String
    let toolCalls: [AgentToolCall]
    /// Provider-specific thinking/reasoning content (e.g. MiMo reasoning_content).
    /// Stored so it can be sent back in subsequent multi-turn requests.
    var thinkingContent: String?
    /// Provider-specific state to replay across tool-use rounds.
    var replayState: ProviderReplayState?
}

enum AgentConversationItem {
    case userMessage(String)
    case assistantMessage(AssistantMessage)
    case toolResult(callID: String, name: String, content: String, isError: Bool)
}
