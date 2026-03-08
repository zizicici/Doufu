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
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return enc
    }()

    private let tokenUsageStore = LLMTokenUsageStore.shared

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
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
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
            let requestBody = AnthropicMessageRequest(
                model: model,
                system: normalizedInstruction.isEmpty ? nil : normalizedInstruction,
                messages: messages,
                maxTokens: configuration.maxOutputTokens,
                thinking: includeThinking
                    ? .init(type: "enabled", budgetTokens: anthropicThinkingBudgetTokens(for: initialReasoningEffort))
                    : nil,
                outputConfig: includeOutputConfig ? structuredOutputConfig : nil
            )
            request.httpBody = try jsonEncoder.encode(requestBody)

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw ProjectChatService.ServiceError.networkFailed(String(localized: "llm.error.invalid_response"))
            }
            guard (200...299).contains(httpResponse.statusCode) else {
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

            guard let decoded = try? jsonDecoder.decode(AnthropicMessageResponse.self, from: data) else {
                throw ProjectChatService.ServiceError.invalidResponse
            }
            let finalResponseText = extractAnthropicText(from: decoded, rawResponseData: data)
            guard !finalResponseText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ProjectChatService.ServiceError.invalidResponse
            }

            if let onStreamedText { await onStreamedText(finalResponseText) }

            tokenUsageStore.recordUsage(
                providerID: credential.providerID, providerLabel: credential.providerLabel,
                model: model,
                inputTokens: decoded.usage?.inputTokens, outputTokens: decoded.usage?.outputTokens,
                projectIdentifier: projectUsageIdentifier
            )
            onUsage?(decoded.usage?.inputTokens, decoded.usage?.outputTokens)
            return finalResponseText
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
        let toolDefinitions = tools.map { tool in
            AnthropicToolDefinitionItem(
                name: tool.name,
                description: tool.description,
                inputSchema: tool.parameters
            )
        }

        let effort = executionOptions.reasoningEffort
        let timeoutSeconds = LLMProviderHelpers.timeoutSeconds(for: effort, configuration: configuration)
        var includeThinking = executionOptions.anthropicThinkingEnabled

        while true {
            let requestBody = AnthropicToolUseRequest(
                model: model,
                system: systemInstruction,
                messages: messages,
                tools: toolDefinitions,
                maxTokens: configuration.maxOutputTokens,
                stream: true,
                thinking: includeThinking
                    ? AnthropicThinkingConfig(type: "enabled", budgetTokens: anthropicThinkingBudgetTokens(for: effort))
                    : nil
            )

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = timeoutSeconds
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            applyAuthorizationHeaders(to: &request, credential: credential)
            request.httpBody = try jsonEncoder.encode(requestBody)

            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw ProjectChatService.ServiceError.networkFailed(String(localized: "llm.error.invalid_response"))
            }

            if !(200...299).contains(httpResponse.statusCode) {
                let data = try await consumeStreamBytes(bytes: bytes)
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
        try await withAnthropicTimeout(seconds: timeoutSeconds + configuration.streamCompletionGraceSeconds) { [self] in
            var streamedText = ""
            var toolCalls: [AgentToolCall] = []
            var inputTokens: Int?
            var outputTokens: Int?
            var stopReason: AgentStopReason = .endTurn

            // Track in-progress content blocks by index
            // For tool_use blocks: (id, name, accumulatedInputJSON)
            var pendingToolBlocks: [Int: (id: String, name: String, inputJSON: String)] = [:]

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
                    }

                case "content_block_delta":
                    guard let index = eventObject["index"] as? Int,
                          let delta = eventObject["delta"] as? [String: Any],
                          let deltaType = delta["type"] as? String
                    else { continue }

                    if deltaType == "text_delta", let text = delta["text"] as? String, !text.isEmpty {
                        streamedText.append(text)
                        if let onStreamedText { await onStreamedText(streamedText) }
                    } else if deltaType == "input_json_delta", let partialJSON = delta["partial_json"] as? String {
                        if var pending = pendingToolBlocks[index] {
                            pending.inputJSON += partialJSON
                            pendingToolBlocks[index] = pending
                        }
                    }

                case "content_block_stop":
                    guard let index = eventObject["index"] as? Int else { continue }
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

            // Finalize any remaining pending tool blocks
            for (_, pending) in pendingToolBlocks.sorted(by: { $0.key < $1.key }) {
                let argumentsJSON = pending.inputJSON.isEmpty ? "{}" : pending.inputJSON
                toolCalls.append(AgentToolCall(id: pending.id, name: pending.name, argumentsJSON: argumentsJSON))
            }

            self.tokenUsageStore.recordUsage(
                providerID: credential.providerID, providerLabel: credential.providerLabel,
                model: model,
                inputTokens: inputTokens, outputTokens: outputTokens,
                projectIdentifier: projectUsageIdentifier
            )
            onUsage?(inputTokens, outputTokens)

            let usage = ResponsesUsage(
                inputTokens: inputTokens, outputTokens: outputTokens,
                totalTokens: (inputTokens ?? 0) + (outputTokens ?? 0),
                inputTokensDetails: nil, outputTokensDetails: nil
            )

            return AgentLLMResponse(
                textContent: streamedText, toolCalls: toolCalls,
                usage: usage, stopReason: stopReason
            )
        }
    }

    private func consumeStreamBytes(bytes: URLSession.AsyncBytes) async throws -> Data {
        var data = Data()
        for try await byte in bytes { data.append(byte) }
        return data
    }

    private func withAnthropicTimeout<T>(seconds: TimeInterval, operation: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                let nanoseconds = UInt64(max(1, seconds) * 1_000_000_000)
                try await Task.sleep(nanoseconds: nanoseconds)
                throw ProjectChatService.ServiceError.networkFailed(String(localized: "llm.error.request_timeout"))
            }
            guard let first = try await group.next() else {
                group.cancelAll()
                throw ProjectChatService.ServiceError.networkFailed(String(localized: "llm.error.request_failed"))
            }
            group.cancelAll()
            return first
        }
    }

    // MARK: - Build Messages

    private func buildToolUseMessages(from items: [AgentConversationItem]) -> [AnthropicToolUseMessage] {
        var messages: [AnthropicToolUseMessage] = []

        for item in items {
            switch item {
            case let .userMessage(text):
                appendMessage(&messages, role: "user", blocks: [.text(text)])
            case let .assistantMessage(text, toolCalls):
                var blocks: [AnthropicContentBlock] = []
                if !text.isEmpty { blocks.append(.text(text)) }
                for tc in toolCalls {
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

    private func anthropicThinkingBudgetTokens(for effort: ResponsesReasoning.Effort) -> Int {
        switch effort {
        case .low: return 1_024
        case .medium: return 2_048
        case .high: return 3_072
        case .xhigh: return 4_096
        }
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

    private func extractAnthropicText(from response: AnthropicMessageResponse, rawResponseData: Data) -> String {
        let textFromContentBlocks = (response.content ?? [])
            .compactMap { content -> String? in
                guard (content.type?.lowercased() ?? "text") == "text" else { return nil }
                let text = content.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return text.isEmpty ? nil : text
            }
            .joined(separator: "\n")
        if !textFromContentBlocks.isEmpty { return textFromContentBlocks }

        guard let object = try? JSONSerialization.jsonObject(with: rawResponseData) as? [String: Any],
              let contentBlocks = object["content"] as? [Any]
        else { return "" }

        let extracted = contentBlocks.compactMap { block -> String? in
            guard let dictionary = block as? [String: Any] else { return nil }
            if let text = dictionary["text"] as? String {
                let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return normalized.isEmpty ? nil : normalized
            }
            if let jsonPayload = dictionary["json"] {
                return serializedJSONObjectString(from: jsonPayload)
            }
            if let inputPayload = dictionary["input"] {
                return serializedJSONObjectString(from: inputPayload)
            }
            return nil
        }
        return extracted.joined(separator: "\n")
    }

    private func serializedJSONObjectString(from object: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object)
        else { return nil }
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
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
        let system: String?
        let messages: [Message]
        let maxTokens: Int
        let thinking: Thinking?
        let outputConfig: OutputConfig?

        private enum CodingKeys: String, CodingKey {
            case model, system, messages
            case maxTokens = "max_tokens"
            case thinking
            case outputConfig = "output_config"
        }
    }

    private struct AnthropicMessageResponse: Decodable {
        struct Content: Decodable {
            let type: String?
            let text: String?
        }
        struct Usage: Decodable {
            let inputTokens: Int?
            let outputTokens: Int?
            private enum CodingKeys: String, CodingKey {
                case inputTokens = "input_tokens"
                case outputTokens = "output_tokens"
            }
        }
        let content: [Content]?
        let usage: Usage?
    }
}
