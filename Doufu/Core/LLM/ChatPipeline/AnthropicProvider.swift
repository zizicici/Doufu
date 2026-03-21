//
//  AnthropicProvider.swift
//  Doufu
//
//  Created by Codex on 2026/03/08.
//

import Foundation

final class AnthropicProvider: LLMProviderAdapter {
    private let configuration: ProjectChatConfiguration
    private let jsonDecoder = JSONDecoder()
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
        let timeoutSeconds = LLMProviderHelpers.timeoutSeconds(for: initialReasoningEffort, configuration: configuration)
        let url = credential.baseURL.appendingPathComponent("messages")
        var includeThinking = executionOptions.anthropicThinkingEnabled
        var includeOutputConfig = responseFormat != nil
        let structuredOutputConfig = responseFormat.flatMap { anthropicOutputConfig(from: $0) }

        while true {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = timeoutSeconds
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            request.setValue("prompt-caching-2024-07-31", forHTTPHeaderField: "anthropic-beta")
            applyAuthorizationHeaders(to: &request, credential: credential)

            let messages = LLMProviderHelpers.normalizedConversationMessages(
                from: inputItems, assistantRole: "assistant", userRole: "user"
            ).map { item in
                AnthropicMessageRequest.Message(
                    role: item.role,
                    content: [.init(type: "text", text: item.text)]
                )
            }
            let normalizedInstruction = developerInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
            let systemBlocks: [AnthropicSystemBlock]? = normalizedInstruction.isEmpty
                ? nil
                : [.text(normalizedInstruction, cache: true)]
            let modelMaxOutput = credential.profile.maxOutputTokens
            let thinkingBudget = includeThinking
                ? configuration.anthropicThinkingBudget(maxOutputTokens: modelMaxOutput, effort: initialReasoningEffort)
                : 0
            let requestBody = AnthropicMessageRequest(
                model: model,
                system: systemBlocks,
                messages: messages,
                maxTokens: modelMaxOutput,
                stream: true,
                thinking: includeThinking
                    ? .init(type: "enabled", budgetTokens: thinkingBudget)
                    : nil,
                outputConfig: includeOutputConfig ? structuredOutputConfig : nil
            )
            request.httpBody = try jsonEncoder.encode(requestBody)

            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw ProjectChatService.ServiceError.networkFailed(String(localized: "llm.error.invalid_response"))
            }
            guard (200...299).contains(httpResponse.statusCode) else {
                let data = try await LLMProviderHelpers.consumeStreamBytes(bytes: bytes)
                if includeThinking, LLMProviderHelpers.shouldFallbackThinkingConfiguration(responseBodyData: data) {
                    includeThinking = false
                    continue
                }
                if includeOutputConfig, shouldFallbackOutputConfiguration(responseBodyData: data) {
                    includeOutputConfig = false
                    continue
                }
                LLMProviderHelpers.logFailedResponse(
                    request: request, httpResponse: httpResponse,
                    responseBodyData: data, requestLabel: requestLabel
                )
                let message = LLMProviderHelpers.parseErrorMessage(from: data)
                    ?? HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
                throw ProjectChatService.ServiceError.networkFailed(String(format: String(localized: "llm.error.request_failed_format"), message))
            }

            return try await consumeAnthropicStreamingResponse(
                bytes: bytes, model: model, credential: credential,
                projectUsageIdentifier: projectUsageIdentifier,
                timeoutSeconds: timeoutSeconds,
                onStreamedText: onStreamedText, onUsage: onUsage
            )
        }
    }

    // MARK: - Non-Tool-Use SSE Stream Consumer

    private func consumeAnthropicStreamingResponse(
        bytes: URLSession.AsyncBytes,
        model: String,
        credential: ProjectChatService.ProviderCredential,
        projectUsageIdentifier: String?,
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
                let trimmed = dataLine.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }

                guard let eventData = trimmed.data(using: .utf8),
                      let eventObject = try? JSONSerialization.jsonObject(with: eventData) as? [String: Any],
                      let eventType = eventObject["type"] as? String
                else { continue }

                switch eventType {
                case "message_start":
                    if let message = eventObject["message"] as? [String: Any],
                       let usage = message["usage"] as? [String: Any] {
                        inputTokens = usage["input_tokens"] as? Int
                    }

                case "content_block_delta":
                    guard let delta = eventObject["delta"] as? [String: Any],
                          let deltaType = delta["type"] as? String
                    else { continue }
                    if deltaType == "text_delta", let text = delta["text"] as? String, !text.isEmpty {
                        streamedText.append(text)
                        if let onStreamedText { onStreamedText(streamedText) }
                    }

                case "message_delta":
                    if let usage = eventObject["usage"] as? [String: Any] {
                        outputTokens = usage["output_tokens"] as? Int
                    }

                case "error":
                    let message = (eventObject["error"] as? [String: Any])?["message"] as? String
                        ?? String(localized: "llm.error.stream_failed")
                    throw ProjectChatService.ServiceError.networkFailed(
                        String(format: String(localized: "llm.error.request_failed_format"), message)
                    )

                default:
                    continue
                }
            }

            guard !streamedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ProjectChatService.ServiceError.invalidResponse
            }

            onUsage?(inputTokens, outputTokens)

            return streamedText
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
        let url = credential.baseURL.appendingPathComponent("messages")

        let messages = buildToolUseMessages(from: conversationItems)

        // Build tool definitions with cache_control on the last tool
        // so the entire tools array is cached across agent loop iterations.
        let toolDefinitions: [AnthropicToolDefinitionItem] = tools.enumerated().map { index, tool in
            AnthropicToolDefinitionItem(
                name: tool.name,
                description: tool.description,
                inputSchema: tool.parameters,
                cacheControl: index == tools.count - 1 ? .ephemeral : nil
            )
        }

        // System prompt as cached block
        let systemBlocks = [AnthropicSystemBlock.text(systemInstruction, cache: true)]

        let effort = executionOptions.reasoningEffort
        let timeoutSeconds = LLMProviderHelpers.timeoutSeconds(for: effort, configuration: configuration)
        var includeThinking = executionOptions.anthropicThinkingEnabled

        while true {
            let modelMaxOutput = credential.profile.maxOutputTokens
            // With interleaved thinking (tool use), Anthropic allows
            // budget_tokens to exceed max_tokens — the ceiling is the
            // context window.  So we use a separate, larger budget and
            // keep max_tokens at the model's native output limit.
            let thinkingBudget = includeThinking
                ? configuration.anthropicThinkingBudgetForToolUse(effort: effort)
                : 0

            let requestBody = AnthropicToolUseRequest(
                model: model,
                system: systemBlocks,
                messages: messages,
                tools: toolDefinitions,
                maxTokens: modelMaxOutput,
                stream: true,
                thinking: includeThinking
                    ? AnthropicThinkingConfig(type: "enabled", budgetTokens: thinkingBudget)
                    : nil
            )

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = timeoutSeconds
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            let betaFeatures = includeThinking
                ? "prompt-caching-2024-07-31,interleaved-thinking-2025-05-14"
                : "prompt-caching-2024-07-31"
            request.setValue(betaFeatures, forHTTPHeaderField: "anthropic-beta")
            applyAuthorizationHeaders(to: &request, credential: credential)
            request.httpBody = try jsonEncoder.encode(requestBody)

            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw ProjectChatService.ServiceError.networkFailed(String(localized: "llm.error.invalid_response"))
            }

            if !(200...299).contains(httpResponse.statusCode) {
                let data = try await LLMProviderHelpers.consumeStreamBytes(bytes: bytes)
                if includeThinking,
                   LLMProviderHelpers.shouldFallbackThinkingConfiguration(responseBodyData: data) {
                    includeThinking = false
                    continue
                }
                let message = LLMProviderHelpers.parseErrorMessage(from: data)
                    ?? HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
                throw ProjectChatService.ServiceError.networkFailed(
                    String(format: String(localized: "llm.error.request_failed_format"), message)
                )
            }

            return try await consumeAnthropicToolUseStream(
                bytes: bytes, model: model, credential: credential,
                projectUsageIdentifier: projectUsageIdentifier,
                timeoutSeconds: timeoutSeconds,
                onStreamedText: onStreamedText, onUsage: onUsage
            )
        }
    }

    // MARK: - Tool Use SSE Stream Consumer

    private func consumeAnthropicToolUseStream(
        bytes: URLSession.AsyncBytes,
        model: String,
        credential: ProjectChatService.ProviderCredential,
        projectUsageIdentifier: String?,
        timeoutSeconds: TimeInterval,
        onStreamedText: (@MainActor (String) -> Void)?,
        onUsage: ((Int?, Int?) -> Void)?
    ) async throws -> AgentLLMResponse {
        try await LLMProviderHelpers.withStreamTimeout(seconds: timeoutSeconds + configuration.streamCompletionGraceSeconds) {
            var streamedText = ""
            var thinkingText = ""
            var toolCalls: [AgentToolCall] = []
            var inputTokens: Int?
            var outputTokens: Int?
            var stopReason: AgentStopReason = .endTurn

            // Track in-progress content blocks by index
            // For tool_use blocks: (id, name, accumulatedInputJSON)
            var pendingToolBlocks: [Int: (id: String, name: String, inputJSON: String)] = [:]
            // Track in-progress thinking blocks by index (text + signature)
            var pendingThinkingBlocks: [Int: (thinking: String, signature: String)] = [:]
            var completedThinkingBlocks: [AnthropicThinkingBlock] = []

            for try await rawLine in bytes.lines {
                let line = rawLine.trimmingCharacters(in: .newlines)
                // Anthropic SSE uses "event:" lines followed by "data:" lines
                // We only need to parse "data:" lines; the type is in the JSON payload
                guard line.hasPrefix("data:") else { continue }
                var dataLine = String(line.dropFirst(5))
                if dataLine.hasPrefix(" ") { dataLine.removeFirst() }
                let trimmed = dataLine.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }

                guard let eventData = trimmed.data(using: .utf8),
                      let eventObject = try? JSONSerialization.jsonObject(with: eventData) as? [String: Any],
                      let eventType = eventObject["type"] as? String
                else { continue }

                switch eventType {
                case "message_start":
                    // Extract input token count from message.usage
                    if let message = eventObject["message"] as? [String: Any],
                       let usage = message["usage"] as? [String: Any] {
                        inputTokens = usage["input_tokens"] as? Int
                    }

                case "content_block_start":
                    guard let index = eventObject["index"] as? Int,
                          let contentBlock = eventObject["content_block"] as? [String: Any],
                          let blockType = contentBlock["type"] as? String
                    else { continue }
                    if blockType == "tool_use" {
                        let id = contentBlock["id"] as? String ?? UUID().uuidString
                        let name = contentBlock["name"] as? String ?? ""
                        pendingToolBlocks[index] = (id: id, name: name, inputJSON: "")
                    } else if blockType == "thinking" {
                        pendingThinkingBlocks[index] = (thinking: "", signature: "")
                    } else if blockType == "redacted_thinking" {
                        // Redacted thinking is delivered complete in content_block_start.
                        let data = contentBlock["data"] as? String ?? ""
                        completedThinkingBlocks.append(.redacted(data: data))
                    }

                case "content_block_delta":
                    guard let index = eventObject["index"] as? Int,
                          let delta = eventObject["delta"] as? [String: Any],
                          let deltaType = delta["type"] as? String
                    else { continue }

                    if deltaType == "thinking_delta", let text = delta["thinking"] as? String, !text.isEmpty {
                        // Accumulate thinking content (global for UI + per-block for replay)
                        thinkingText.append(text)
                        if var pending = pendingThinkingBlocks[index] {
                            pending.thinking += text
                            pendingThinkingBlocks[index] = pending
                        }
                    } else if deltaType == "signature_delta", let sig = delta["signature"] as? String, !sig.isEmpty {
                        // Accumulate signature for the thinking block
                        if var pending = pendingThinkingBlocks[index] {
                            pending.signature += sig
                            pendingThinkingBlocks[index] = pending
                        }
                    } else if deltaType == "text_delta", let text = delta["text"] as? String, !text.isEmpty {
                        streamedText.append(text)
                        if let onStreamedText { onStreamedText(streamedText) }
                    } else if deltaType == "input_json_delta", let partialJSON = delta["partial_json"] as? String {
                        if var pending = pendingToolBlocks[index] {
                            pending.inputJSON += partialJSON
                            pendingToolBlocks[index] = pending
                        }
                    }

                case "content_block_stop":
                    guard let index = eventObject["index"] as? Int else { continue }
                    if let pending = pendingThinkingBlocks.removeValue(forKey: index) {
                        completedThinkingBlocks.append(.thinking(
                            text: pending.thinking, signature: pending.signature
                        ))
                    }
                    if let pending = pendingToolBlocks.removeValue(forKey: index) {
                        let argumentsJSON = pending.inputJSON.isEmpty ? "{}" : pending.inputJSON
                        toolCalls.append(AgentToolCall(id: pending.id, name: pending.name, argumentsJSON: argumentsJSON))
                    }

                case "message_delta":
                    if let delta = eventObject["delta"] as? [String: Any],
                       let reason = delta["stop_reason"] as? String {
                        switch reason {
                        case "tool_use": stopReason = .toolUse
                        case "max_tokens": stopReason = .maxTokens
                        default: stopReason = toolCalls.isEmpty ? .endTurn : .toolUse
                        }
                    }
                    if let usage = eventObject["usage"] as? [String: Any] {
                        outputTokens = usage["output_tokens"] as? Int
                    }

                case "error":
                    let message = (eventObject["error"] as? [String: Any])?["message"] as? String
                        ?? String(localized: "llm.error.stream_failed")
                    throw ProjectChatService.ServiceError.networkFailed(
                        String(format: String(localized: "llm.error.request_failed_format"), message)
                    )

                case "message_stop":
                    break // Stream finished normally

                default:
                    continue
                }
            }

            // Finalize any remaining pending tool blocks.
            // When the response was truncated by max_tokens, pending blocks have
            // incomplete JSON arguments — discard them so the orchestrator can
            // auto-continue instead of executing malformed tool calls.
            if stopReason != .maxTokens {
                for (_, pending) in pendingToolBlocks.sorted(by: { $0.key < $1.key }) {
                    let argumentsJSON = pending.inputJSON.isEmpty ? "{}" : pending.inputJSON
                    toolCalls.append(AgentToolCall(id: pending.id, name: pending.name, argumentsJSON: argumentsJSON))
                }
            }

            onUsage?(inputTokens, outputTokens)

            let usage = ResponsesUsage(
                inputTokens: inputTokens, outputTokens: outputTokens,
                totalTokens: (inputTokens ?? 0) + (outputTokens ?? 0),
                inputTokensDetails: nil, outputTokensDetails: nil
            )

            let finalThinking = thinkingText.trimmingCharacters(in: .whitespacesAndNewlines)

            return AgentLLMResponse(
                textContent: streamedText, toolCalls: toolCalls,
                usage: usage, stopReason: stopReason,
                thinkingContent: finalThinking.isEmpty ? nil : finalThinking,
                replayState: completedThinkingBlocks.isEmpty ? nil : .anthropicThinking(completedThinkingBlocks)
            )
        }
    }


    // MARK: - Build Messages

    private func buildToolUseMessages(from items: [AgentConversationItem]) -> [AnthropicToolUseMessage] {
        var messages: [AnthropicToolUseMessage] = []

        for item in items {
            switch item {
            case let .userMessage(text):
                appendMessage(&messages, role: "user", blocks: [.text(text)])
            case let .assistantMessage(msg):
                var blocks: [AnthropicContentBlock] = []
                // Thinking blocks must come first and be passed back unchanged.
                if case let .anthropicThinking(thinkingBlocks) = msg.replayState {
                    for block in thinkingBlocks {
                        switch block {
                        case let .thinking(text, signature):
                            blocks.append(.thinking(thinking: text, signature: signature))
                        case let .redacted(data):
                            blocks.append(.redactedThinking(data: data))
                        }
                    }
                }
                if !msg.text.isEmpty { blocks.append(.text(msg.text)) }
                for tc in msg.toolCalls {
                    let inputValue = LLMProviderHelpers.parseJSONToJSONValue(tc.argumentsJSON)
                    blocks.append(.toolUse(id: tc.id, name: tc.name, input: inputValue))
                }
                if !blocks.isEmpty { appendMessage(&messages, role: "assistant", blocks: blocks) }
            case let .toolResult(callID, _, content, isError):
                appendMessage(&messages, role: "user", blocks: [
                    .toolResult(toolUseID: callID, content: content, isError: isError)
                ])
            }
        }

        return messages
    }

    private func appendMessage(_ messages: inout [AnthropicToolUseMessage], role: String, blocks: [AnthropicContentBlock]) {
        if let last = messages.last, last.role == role {
            messages[messages.count - 1] = AnthropicToolUseMessage(
                role: role, content: last.content + blocks
            )
        } else {
            messages.append(AnthropicToolUseMessage(role: role, content: blocks))
        }
    }


    // MARK: - Helpers

    private func applyAuthorizationHeaders(
        to request: inout URLRequest,
        credential: ProjectChatService.ProviderCredential
    ) {
        if usesOfficialAnthropicAuthentication(credential.baseURL) {
            request.setValue(credential.bearerToken, forHTTPHeaderField: "x-api-key")
            return
        }
        switch credential.authMode {
        case .apiKey:
            request.setValue(credential.bearerToken, forHTTPHeaderField: "x-api-key")
        case .oauth:
            request.setValue("Bearer \(credential.bearerToken)", forHTTPHeaderField: "Authorization")
        }
    }

    private func usesOfficialAnthropicAuthentication(_ baseURL: URL) -> Bool {
        guard let host = baseURL.host?.lowercased() else { return false }
        return host == "api.anthropic.com" || host.hasSuffix(".anthropic.com")
    }

    private func anthropicOutputConfig(from format: ResponsesTextFormat) -> AnthropicMessageRequest.OutputConfig? {
        let normalizedType = format.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalizedType == "json_schema" else { return nil }
        return AnthropicMessageRequest.OutputConfig(
            format: .init(type: normalizedType, schema: format.schema)
        )
    }

    private func shouldFallbackOutputConfiguration(responseBodyData: Data) -> Bool {
        let message = LLMProviderHelpers.parseErrorMessage(from: responseBodyData)?.lowercased() ?? ""
        guard !message.isEmpty else { return false }
        let hints = ["output_config", "output format", "output_format", "json_schema", "unsupported", "unknown field", "additional property"]
        return hints.contains { message.contains($0) }
    }

    // MARK: - Private types for non-tool-use requests

    private struct AnthropicMessageRequest: Encodable {
        struct OutputConfig: Encodable {
            struct Format: Encodable {
                let type: String
                let schema: JSONValue
            }
            let format: Format
        }

        struct Thinking: Encodable {
            let type: String
            let budgetTokens: Int
            private enum CodingKeys: String, CodingKey {
                case type
                case budgetTokens = "budget_tokens"
            }
        }

        struct Message: Encodable {
            struct Content: Encodable {
                let type: String
                let text: String
            }
            let role: String
            let content: [Content]
        }

        let model: String
        let system: [AnthropicSystemBlock]?
        let messages: [Message]
        let maxTokens: Int
        let stream: Bool
        let thinking: Thinking?
        let outputConfig: OutputConfig?

        private enum CodingKeys: String, CodingKey {
            case model, system, messages, stream
            case maxTokens = "max_tokens"
            case thinking
            case outputConfig = "output_config"
        }
    }

}
