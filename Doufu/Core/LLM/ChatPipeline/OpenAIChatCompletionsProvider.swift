//
//  OpenAIChatCompletionsProvider.swift
//  Doufu
//

import Foundation

final class OpenAIChatCompletionsProvider: LLMProviderAdapter {
    private let configuration: ProjectChatConfiguration
    private let jsonEncoder: JSONEncoder = {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return enc
    }()

    init(configuration: ProjectChatConfiguration) {
        self.configuration = configuration
    }

    // MARK: - Streaming (non-tool-use)

    func requestStreaming(
        requestLabel: String,
        model: String,
        developerInstruction: String,
        inputItems: [ResponseInputMessage],
        credential: ProjectChatService.ProviderCredential,
        projectUsageIdentifier: String?,
        initialReasoningEffort: ResponsesReasoning.Effort,
        executionOptions: ProjectChatService.ModelExecutionOptions,
        responseFormat: ResponsesTextFormat?,
        onStreamedText: (@MainActor (String) -> Void)?,
        onUsage: ((Int?, Int?) -> Void)?
    ) async throws -> String {
        let effort = executionOptions.reasoningEffort
        let sendReasoning = !credential.profile.reasoningEfforts.isEmpty

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

        var requestBody = OpenAIChatCompletionsRequest(
            model: model,
            messages: messages,
            tools: nil,
            stream: true,
            maxCompletionTokens: credential.profile.maxOutputTokens,
            reasoningEffort: sendReasoning ? reasoningEffortString(from: effort) : nil,
            streamOptions: OpenAIChatCompletionsRequest.StreamOptions(includeUsage: true)
        )
        var didFallbackMaxCompletionTokens = false
        var didFallbackReasoningEffort = false

        while true {
            let timeoutSeconds = LLMProviderHelpers.timeoutSeconds(for: initialReasoningEffort, configuration: configuration)
            var request = buildURLRequest(credential: credential, path: "chat/completions", timeoutSeconds: timeoutSeconds)
            request.httpBody = try jsonEncoder.encode(requestBody)

            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw ProjectChatService.ServiceError.networkFailed(String(localized: "llm.error.invalid_response"))
            }
            guard (200...299).contains(httpResponse.statusCode) else {
                let data = try await LLMProviderHelpers.consumeStreamBytes(bytes: bytes)
                let errorMessage = LLMProviderHelpers.parseErrorMessage(from: data) ?? ""

                if shouldFallbackMaxCompletionTokens(errorMessage: errorMessage, alreadyFallback: didFallbackMaxCompletionTokens, currentValue: requestBody.maxCompletionTokens) {
                    didFallbackMaxCompletionTokens = true
                    requestBody.maxCompletionTokens = nil
                    continue
                }

                if shouldFallbackReasoningEffort(errorMessage: errorMessage, alreadyFallback: didFallbackReasoningEffort, currentValue: requestBody.reasoningEffort) {
                    didFallbackReasoningEffort = true
                    requestBody.reasoningEffort = nil
                    continue
                }

                LLMProviderHelpers.logFailedResponse(
                    request: request, httpResponse: httpResponse,
                    responseBodyData: data, requestLabel: requestLabel
                )
                let message = errorMessage.isEmpty
                    ? HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
                    : errorMessage
                throw ProjectChatService.ServiceError.networkFailed(
                    String(format: String(localized: "llm.error.request_failed_format"), message)
                )
            }

            let result = try await consumeStreamingResponse(
                bytes: bytes, timeoutSeconds: timeoutSeconds,
                onStreamedText: onStreamedText, onUsage: onUsage
            )
            return result
        }
    }

    // MARK: - Tool Use

    func requestWithTools(
        systemInstruction: String,
        conversationItems: [AgentConversationItem],
        tools: [AgentToolDefinition],
        credential: ProjectChatService.ProviderCredential,
        projectUsageIdentifier: String?,
        executionOptions: ProjectChatService.ModelExecutionOptions,
        onStreamedText: (@MainActor (String) -> Void)?,
        onUsage: ((Int?, Int?) -> Void)?
    ) async throws -> AgentLLMResponse {
        let model = credential.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let effort = executionOptions.reasoningEffort
        let timeoutSeconds = LLMProviderHelpers.timeoutSeconds(for: effort, configuration: configuration)
        let sendReasoning = !credential.profile.reasoningEfforts.isEmpty

        let messages = buildToolUseMessages(systemInstruction: systemInstruction, from: conversationItems)
        let toolDefinitions = tools.map { tool in
            OpenRouterToolDefinition(name: tool.name, description: tool.description, parameters: tool.parameters)
        }

        var requestBody = OpenAIChatCompletionsRequest(
            model: model,
            messages: messages,
            tools: toolDefinitions,
            stream: true,
            maxCompletionTokens: credential.profile.maxOutputTokens,
            reasoningEffort: sendReasoning ? reasoningEffortString(from: effort) : nil,
            streamOptions: OpenAIChatCompletionsRequest.StreamOptions(includeUsage: true)
        )
        var didFallbackMaxCompletionTokens = false
        var didFallbackReasoningEffort = false

        while true {
            var request = buildURLRequest(credential: credential, path: "chat/completions", timeoutSeconds: timeoutSeconds)
            request.httpBody = try jsonEncoder.encode(requestBody)

            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw ProjectChatService.ServiceError.networkFailed(String(localized: "llm.error.invalid_response"))
            }
            guard (200...299).contains(httpResponse.statusCode) else {
                let data = try await LLMProviderHelpers.consumeStreamBytes(bytes: bytes)
                let errorMessage = LLMProviderHelpers.parseErrorMessage(from: data) ?? ""

                if shouldFallbackMaxCompletionTokens(errorMessage: errorMessage, alreadyFallback: didFallbackMaxCompletionTokens, currentValue: requestBody.maxCompletionTokens) {
                    didFallbackMaxCompletionTokens = true
                    requestBody.maxCompletionTokens = nil
                    continue
                }

                if shouldFallbackReasoningEffort(errorMessage: errorMessage, alreadyFallback: didFallbackReasoningEffort, currentValue: requestBody.reasoningEffort) {
                    didFallbackReasoningEffort = true
                    requestBody.reasoningEffort = nil
                    continue
                }

                LLMProviderHelpers.logFailedResponse(
                    request: request, httpResponse: httpResponse,
                    responseBodyData: data, requestLabel: "OpenAI CC ToolUse"
                )
                let message = errorMessage.isEmpty
                    ? HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
                    : errorMessage
                throw ProjectChatService.ServiceError.networkFailed(
                    String(format: String(localized: "llm.error.request_failed_format"), message)
                )
            }

            return try await consumeToolUseStream(
                bytes: bytes, timeoutSeconds: timeoutSeconds,
                onStreamedText: onStreamedText, onUsage: onUsage
            )
        }
    }

    // MARK: - Build Messages

    private func buildToolUseMessages(
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

    // MARK: - URL Request Builder

    private func buildURLRequest(
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

    // MARK: - Streaming Response Consumer (non-tool-use)

    private func consumeStreamingResponse(
        bytes: URLSession.AsyncBytes,
        timeoutSeconds: TimeInterval,
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
                   let choice = choices.first,
                   let delta = choice["delta"] as? [String: Any],
                   let content = delta["content"] as? String, !content.isEmpty {
                    streamedText.append(content)
                    if let onStreamedText { onStreamedText(streamedText) }
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

    private func consumeToolUseStream(
        bytes: URLSession.AsyncBytes,
        timeoutSeconds: TimeInterval,
        onStreamedText: (@MainActor (String) -> Void)?,
        onUsage: ((Int?, Int?) -> Void)?
    ) async throws -> AgentLLMResponse {
        try await LLMProviderHelpers.withStreamTimeout(seconds: timeoutSeconds + configuration.streamCompletionGraceSeconds) {
            var streamedText = ""
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
                thinkingContent: nil,
                replayState: nil
            )
        }
    }

    // MARK: - Reasoning Effort

    private func reasoningEffortString(from effort: ProjectChatService.ReasoningEffort) -> String {
        switch effort {
        case .xhigh: return "xhigh"
        case .high: return "high"
        case .medium: return "medium"
        case .low: return "low"
        }
    }

    // MARK: - Fallback Helpers

    private func shouldFallbackMaxCompletionTokens(errorMessage: String, alreadyFallback: Bool, currentValue: Int?) -> Bool {
        guard !alreadyFallback, currentValue != nil else { return false }
        let msg = errorMessage.lowercased()
        return msg.contains("max_completion_tokens") || msg.contains("max_output_tokens")
    }

    private func shouldFallbackReasoningEffort(errorMessage: String, alreadyFallback: Bool, currentValue: String?) -> Bool {
        guard !alreadyFallback, currentValue != nil else { return false }
        let msg = errorMessage.lowercased()
        return msg.contains("reasoning_effort")
    }
}
