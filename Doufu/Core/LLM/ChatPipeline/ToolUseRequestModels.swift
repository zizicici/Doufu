//
//  ToolUseRequestModels.swift
//  Doufu
//
//  Created by Codex on 2026/03/08.
//

import Foundation

// MARK: - OpenAI Responses API Tool Use

struct OpenAIToolUseRequest: Encodable {
    let model: String
    let instructions: String
    let input: [OpenAIToolUseInputItem]
    let tools: [OpenAIToolDefinition]
    let stream: Bool
    let store: Bool?
    let reasoning: ResponsesReasoning?
}

enum OpenAIToolUseInputItem: Encodable {
    case message(OpenAIToolUseMessage)
    case functionCall(OpenAIFunctionCallItem)
    case functionCallOutput(OpenAIFunctionCallOutputItem)

    func encode(to encoder: Encoder) throws {
        switch self {
        case let .message(value): try value.encode(to: encoder)
        case let .functionCall(value): try value.encode(to: encoder)
        case let .functionCallOutput(value): try value.encode(to: encoder)
        }
    }
}

struct OpenAIToolUseMessage: Encodable {
    let role: String
    let content: [OpenAIToolUseContent]
}

struct OpenAIToolUseContent: Encodable {
    let type: String
    let text: String
}

struct OpenAIFunctionCallItem: Encodable {
    let type = "function_call"
    let callID: String
    let name: String
    let arguments: String

    private enum CodingKeys: String, CodingKey {
        case type
        case callID = "call_id"
        case name
        case arguments
    }
}

struct OpenAIFunctionCallOutputItem: Encodable {
    let type = "function_call_output"
    let callID: String
    let output: String

    private enum CodingKeys: String, CodingKey {
        case type
        case callID = "call_id"
        case output
    }
}

struct OpenAIToolDefinition: Encodable {
    let type = "function"
    let name: String
    let description: String
    let parameters: JSONValue
    let strict: Bool

    private enum CodingKeys: String, CodingKey {
        case type, name, description, parameters, strict
    }
}

// MARK: - Anthropic Messages API Tool Use

struct AnthropicToolUseRequest: Encodable {
    let model: String
    let system: String?
    let messages: [AnthropicToolUseMessage]
    let tools: [AnthropicToolDefinitionItem]
    let maxTokens: Int
    let stream: Bool
    let thinking: AnthropicThinkingConfig?

    private enum CodingKeys: String, CodingKey {
        case model, system, messages, tools
        case maxTokens = "max_tokens"
        case stream, thinking
    }
}

struct AnthropicThinkingConfig: Encodable {
    let type: String
    let budgetTokens: Int

    private enum CodingKeys: String, CodingKey {
        case type
        case budgetTokens = "budget_tokens"
    }
}

struct AnthropicToolUseMessage: Encodable {
    let role: String
    let content: [AnthropicContentBlock]
}

enum AnthropicContentBlock: Encodable {
    case text(String)
    case toolUse(id: String, name: String, input: JSONValue)
    case toolResult(toolUseID: String, content: String, isError: Bool)

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .text(text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case let .toolUse(id, name, input):
            try container.encode("tool_use", forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(name, forKey: .name)
            try container.encode(input, forKey: .input)
        case let .toolResult(toolUseID, content, isError):
            try container.encode("tool_result", forKey: .type)
            try container.encode(toolUseID, forKey: .toolUseID)
            try container.encode(content, forKey: .content)
            if isError {
                try container.encode(true, forKey: .isError)
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type, text, id, name, input
        case toolUseID = "tool_use_id"
        case content
        case isError = "is_error"
    }
}

struct AnthropicToolDefinitionItem: Encodable {
    let name: String
    let description: String
    let inputSchema: JSONValue

    private enum CodingKeys: String, CodingKey {
        case name, description
        case inputSchema = "input_schema"
    }
}

// MARK: - Anthropic Tool Use Response

struct AnthropicToolUseResponse: Decodable {
    struct ContentBlock: Decodable {
        let type: String
        let text: String?
        let id: String?
        let name: String?
        let input: AnyCodable?
    }

    struct Usage: Decodable {
        let inputTokens: Int?
        let outputTokens: Int?

        private enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
        }
    }

    let content: [ContentBlock]?
    let usage: Usage?
    let stopReason: String?

    private enum CodingKeys: String, CodingKey {
        case content, usage
        case stopReason = "stop_reason"
    }
}

// MARK: - Gemini Tool Use

struct GeminiToolUseRequest: Encodable {
    struct Content: Encodable {
        let role: String
        let parts: [GeminiPart]
    }

    struct SystemInstruction: Encodable {
        let parts: [GeminiTextPart]
    }

    struct ToolDeclarations: Encodable {
        let functionDeclarations: [GeminiFunctionDeclaration]
    }

    struct GenerationConfig: Encodable {
        struct ThinkingConfig: Encodable {
            let thinkingBudget: Int

            private enum CodingKeys: String, CodingKey {
                case thinkingBudget = "thinking_budget"
            }
        }

        let thinkingConfig: ThinkingConfig?
    }

    let contents: [Content]
    let tools: [ToolDeclarations]
    let systemInstruction: SystemInstruction?
    let generationConfig: GenerationConfig?
}

struct GeminiTextPart: Encodable {
    let text: String
}

enum GeminiPart: Encodable {
    case text(String)
    case functionCall(name: String, args: JSONValue)
    case functionResponse(name: String, response: JSONValue)

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .text(text):
            try container.encode(text, forKey: .text)
        case let .functionCall(name, args):
            try container.encode(FunctionCallPayload(name: name, args: args), forKey: .functionCall)
        case let .functionResponse(name, response):
            try container.encode(FunctionResponsePayload(name: name, response: response), forKey: .functionResponse)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case text, functionCall, functionResponse
    }

    private struct FunctionCallPayload: Encodable {
        let name: String
        let args: JSONValue
    }

    private struct FunctionResponsePayload: Encodable {
        let name: String
        let response: JSONValue
    }
}

struct GeminiFunctionDeclaration: Encodable {
    let name: String
    let description: String
    let parameters: JSONValue
}

// MARK: - Gemini Tool Use Response

struct GeminiToolUseResponse: Decodable {
    struct Candidate: Decodable {
        struct Content: Decodable {
            struct Part: Decodable {
                let text: String?
                let functionCall: FunctionCall?
            }

            struct FunctionCall: Decodable {
                let name: String?
                let args: AnyCodable?
            }

            let parts: [Part]?
        }

        let content: Content?
    }

    struct UsageMetadata: Decodable {
        let promptTokenCount: Int?
        let candidatesTokenCount: Int?
        let thoughtsTokenCount: Int?
    }

    let candidates: [Candidate]?
    let usageMetadata: UsageMetadata?
}

// MARK: - AnyCodable for dynamic JSON

struct AnyCodable: Decodable {
    let value: Any

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = NSNull()
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map(\.value)
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues(\.value)
        } else {
            value = NSNull()
        }
    }
}
