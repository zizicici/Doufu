//
//  ChatCompletionsBaseProvider.swift
//  Doufu
//
//  Shared infrastructure for Chat Completions API providers.
//  Subclasses: OpenRouterProvider, MiMoProvider, OpenAIChatCompletionsProvider.
//

import Foundation

struct ChatCompletionsStreamingOptions: Sendable {
    var checkContentFilter: Bool = false
}

struct ChatCompletionsToolUseStreamOptions: Sendable {
    var parseReasoningContent: Bool = false
    var checkContentFilter: Bool = false
}

class ChatCompletionsBaseProvider {
    let configuration: ProjectChatConfiguration
    let jsonEncoder: JSONEncoder = {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return enc
    }()

    init(configuration: ProjectChatConfiguration) {
        self.configuration = configuration
    }

    // MARK: - URL Request Builder

    func buildURLRequest(
        credential: ProjectChatService.ProviderCredential,
        path: String,
        timeoutSeconds: TimeInterval
    ) -> URLRequest {
        var request = URLRequest(url: credential.baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.timeoutInterval = timeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(credential.bearerToken)", forHTTPHeaderField: "Authorization")
        return request
    }

    // MARK: - Non-Tool Message Builder

    func buildNonToolMessages(
        developerInstruction: String,
        inputItems: [ResponseInputMessage]
    ) -> [OpenRouterMessage] {
        var messages: [OpenRouterMessage] = []
        if !developerInstruction.isEmpty {
            messages.append(.system(content: developerInstruction))
        }
        let conversationMessages = LLMProviderHelpers.normalizedConversationMessages(
            from: inputItems, assistantRole: "assistant", userRole: "user"
        )
        for msg in conversationMessages {
            if msg.role == "assistant" {
                messages.append(.assistant(content: msg.text, toolCalls: nil))
            } else {
                messages.append(.user(content: msg.text))
            }
        }
        return messages
    }

    // MARK: - Tool Use Message Builder

    func buildToolUseMessages(
        systemInstruction: String,
        from items: [AgentConversationItem]
    ) -> [OpenRouterMessage] {
        var messages: [OpenRouterMessage] = []
        if !systemInstruction.isEmpty {
            messages.append(.system(content: systemInstruction))
        }
        for item in items {
            switch item {
            case let .userMessage(text):
                messages.append(.user(content: text))
            case let .assistantMessage(msg):
                let calls = msg.toolCalls.map { tc in
                    OpenRouterToolCall(id: tc.id, name: tc.name, arguments: tc.argumentsJSON)
                }
                messages.append(.assistant(content: msg.text, toolCalls: calls.isEmpty ? nil : calls))
            case let .toolResult(callID, _, content, _):
                messages.append(.tool(toolCallID: callID, content: content))
            }
        }
        return messages
    }

    // MARK: - Tool Definition Builder

    func buildToolDefinitions(from tools: [AgentToolDefinition]) -> [OpenRouterToolDefinition] {
        tools.map { tool in
            OpenRouterToolDefinition(name: tool.name, description: tool.description, parameters: tool.parameters)
        }
    }

    // MARK: - HTTP Error Handler

    func throwHTTPError(
        request: URLRequest,
        httpResponse: HTTPURLResponse,
        bytes: URLSession.AsyncBytes,
        requestLabel: String
    ) async throws -> Never {
        let data = try await LLMProviderHelpers.consumeStreamBytes(bytes: bytes)
        LLMProviderHelpers.logFailedResponse(
            request: request, httpResponse: httpResponse,
            responseBodyData: data, requestLabel: requestLabel
        )
        let message = LLMProviderHelpers.parseErrorMessage(from: data)
            ?? HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
        throw ProjectChatService.ServiceError.networkFailed(
            String(format: String(localized: "llm.error.request_failed_format"), message)
        )
    }

    // MARK: - Streaming Response Consumer (non-tool-use)

    func consumeStreamingResponse(
        bytes: URLSession.AsyncBytes,
        timeoutSeconds: TimeInterval,
        options: ChatCompletionsStreamingOptions = .init(),
        onStreamedText: (@MainActor (String) -> Void)?,
        onUsage: ((Int?, Int?) -> Void)?
    ) async throws -> String {
        try await LLMProviderHelpers.withStreamTimeout(seconds: timeoutSeconds + configuration.streamCompletionGraceSeconds) {
            var streamedText = ""
            var inputTokens: Int?
            var outputTokens: Int?

            for try await rawLine in bytes.lines {
                let line = rawLine.trimmingCharacters(in: .newlines)
                guard line.hasPrefix("data:") else { continue }
                var dataLine = String(line.dropFirst(5))
                if dataLine.hasPrefix(" ") { dataLine.removeFirst() }
                if dataLine == "[DONE]" { break }

                guard let data = dataLine.data(using: .utf8),
                      let chunk = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }

                if let error = chunk["error"] as? [String: Any],
                   let message = error["message"] as? String {
                    throw ProjectChatService.ServiceError.networkFailed(
                        String(format: String(localized: "llm.error.request_failed_format"), message)
                    )
                }

                if let choices = chunk["choices"] as? [[String: Any]],
                   let choice = choices.first {
                    if options.checkContentFilter,
                       let reason = choice["finish_reason"] as? String, reason == "content_filter" {
                        throw ProjectChatService.ServiceError.networkFailed(
                            String(localized: "llm.error.content_filtered")
                        )
                    }
                    if let delta = choice["delta"] as? [String: Any],
                       let content = delta["content"] as? String, !content.isEmpty {
                        streamedText.append(content)
                        if let onStreamedText { onStreamedText(streamedText) }
                    }
                }

                if let usage = chunk["usage"] as? [String: Any] {
                    inputTokens = usage["prompt_tokens"] as? Int
                    outputTokens = usage["completion_tokens"] as? Int
                }
            }

            onUsage?(inputTokens, outputTokens)

            guard !streamedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ProjectChatService.ServiceError.invalidResponse
            }
            return streamedText
        }
    }

    // MARK: - Tool Use Stream Consumer

    func consumeToolUseStream(
        bytes: URLSession.AsyncBytes,
        timeoutSeconds: TimeInterval,
        options: ChatCompletionsToolUseStreamOptions = .init(),
        onStreamedText: (@MainActor (String) -> Void)?,
        onUsage: ((Int?, Int?) -> Void)?
    ) async throws -> AgentLLMResponse {
        try await LLMProviderHelpers.withStreamTimeout(seconds: timeoutSeconds + configuration.streamCompletionGraceSeconds) {
            var streamedText = ""
            var thinkingContent = ""
            var pendingToolCalls: [Int: (id: String, name: String, arguments: String)] = [:]
            var finishedToolCalls: [AgentToolCall] = []
            var finishReason: String?
            var inputTokens: Int?
            var outputTokens: Int?

            for try await rawLine in bytes.lines {
                let line = rawLine.trimmingCharacters(in: .newlines)
                guard line.hasPrefix("data:") else { continue }
                var dataLine = String(line.dropFirst(5))
                if dataLine.hasPrefix(" ") { dataLine.removeFirst() }
                if dataLine == "[DONE]" { break }

                guard let data = dataLine.data(using: .utf8),
                      let chunk = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }

                if let error = chunk["error"] as? [String: Any],
                   let message = error["message"] as? String {
                    throw ProjectChatService.ServiceError.networkFailed(
                        String(format: String(localized: "llm.error.request_failed_format"), message)
                    )
                }

                guard let choices = chunk["choices"] as? [[String: Any]],
                      let choice = choices.first
                else {
                    if let usage = chunk["usage"] as? [String: Any] {
                        inputTokens = usage["prompt_tokens"] as? Int
                        outputTokens = usage["completion_tokens"] as? Int
                    }
                    continue
                }

                if let reason = choice["finish_reason"] as? String {
                    finishReason = reason
                }

                guard let delta = choice["delta"] as? [String: Any] else { continue }

                if options.parseReasoningContent,
                   let reasoning = delta["reasoning_content"] as? String, !reasoning.isEmpty {
                    thinkingContent.append(reasoning)
                }

                if let content = delta["content"] as? String, !content.isEmpty {
                    streamedText.append(content)
                    if let onStreamedText { onStreamedText(streamedText) }
                }

                if let toolCallDeltas = delta["tool_calls"] as? [[String: Any]] {
                    for tcDelta in toolCallDeltas {
                        let index = tcDelta["index"] as? Int ?? 0
                        if let function = tcDelta["function"] as? [String: Any] {
                            if let name = function["name"] as? String {
                                let id = tcDelta["id"] as? String ?? UUID().uuidString
                                pendingToolCalls[index] = (id: id, name: name, arguments: "")
                            }
                            if let args = function["arguments"] as? String {
                                if var pending = pendingToolCalls[index] {
                                    pending.arguments += args
                                    pendingToolCalls[index] = pending
                                }
                            }
                        }
                    }
                }

                if let usage = chunk["usage"] as? [String: Any] {
                    inputTokens = usage["prompt_tokens"] as? Int
                    outputTokens = usage["completion_tokens"] as? Int
                }
            }

            for (_, pending) in pendingToolCalls.sorted(by: { $0.key < $1.key }) {
                finishedToolCalls.append(AgentToolCall(
                    id: pending.id, name: pending.name, argumentsJSON: pending.arguments
                ))
            }

            onUsage?(inputTokens, outputTokens)

            let stopReason: AgentStopReason
            switch finishReason {
            case "tool_calls":
                stopReason = .toolUse
            case "length":
                stopReason = .maxTokens
            case "content_filter" where options.checkContentFilter:
                stopReason = .endTurn
            default:
                stopReason = finishedToolCalls.isEmpty ? .endTurn : .toolUse
            }

            let responseUsage: ResponsesUsage? = (inputTokens != nil || outputTokens != nil)
                ? ResponsesUsage(
                    inputTokens: inputTokens,
                    outputTokens: outputTokens,
                    totalTokens: (inputTokens ?? 0) + (outputTokens ?? 0),
                    inputTokensDetails: nil,
                    outputTokensDetails: nil
                )
                : nil

            return AgentLLMResponse(
                textContent: streamedText,
                toolCalls: finishedToolCalls,
                usage: responseUsage,
                stopReason: stopReason,
                thinkingContent: thinkingContent.isEmpty ? nil : thinkingContent,
                replayState: nil
            )
        }
    }
}
