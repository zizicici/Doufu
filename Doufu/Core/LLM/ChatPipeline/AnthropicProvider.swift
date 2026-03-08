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
                throw ProjectChatService.ServiceError.networkFailed("请求失败：无效响应。")
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
                throw ProjectChatService.ServiceError.networkFailed("请求失败：\(message)")
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
        let timeoutSeconds = LLMProviderHelpers.timeoutSeconds(for: .high, configuration: configuration)
        let url = credential.baseURL.appendingPathComponent("messages")

        let messages = buildToolUseMessages(from: conversationItems)
        let toolDefinitions = tools.map { tool in
            AnthropicToolDefinitionItem(
                name: tool.name,
                description: tool.description,
                inputSchema: tool.parameters
            )
        }

        var requestBody = AnthropicToolUseRequest(
            model: model,
            system: systemInstruction,
            messages: messages,
            tools: toolDefinitions,
            maxTokens: configuration.maxOutputTokens,
            thinking: executionOptions.anthropicThinkingEnabled
                ? AnthropicThinkingConfig(type: "enabled", budgetTokens: 4096)
                : nil
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        applyAuthorizationHeaders(to: &request, credential: credential)
        request.httpBody = try jsonEncoder.encode(requestBody)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProjectChatService.ServiceError.networkFailed("Invalid response")
        }

        if !(200...299).contains(httpResponse.statusCode) {
            if executionOptions.anthropicThinkingEnabled,
               LLMProviderHelpers.shouldFallbackThinkingConfiguration(responseBodyData: data) {
                requestBody = AnthropicToolUseRequest(
                    model: model, system: systemInstruction,
                    messages: messages, tools: toolDefinitions,
                    maxTokens: configuration.maxOutputTokens, thinking: nil
                )
                request.httpBody = try jsonEncoder.encode(requestBody)
                let (retryData, retryResponse) = try await URLSession.shared.data(for: request)
                guard let retryHTTP = retryResponse as? HTTPURLResponse,
                      (200...299).contains(retryHTTP.statusCode) else {
                    let msg = LLMProviderHelpers.parseErrorMessage(from: retryData) ?? "Request failed"
                    throw ProjectChatService.ServiceError.networkFailed(msg)
                }
                return try await parseToolResponse(
                    data: retryData, model: model, credential: credential,
                    projectUsageIdentifier: projectUsageIdentifier,
                    onStreamedText: onStreamedText, onUsage: onUsage
                )
            }
            let message = LLMProviderHelpers.parseErrorMessage(from: data)
                ?? HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
            throw ProjectChatService.ServiceError.networkFailed(message)
        }

        return try await parseToolResponse(
            data: data, model: model, credential: credential,
            projectUsageIdentifier: projectUsageIdentifier,
            onStreamedText: onStreamedText, onUsage: onUsage
        )
    }

    // MARK: - Parse Tool Response

    private func parseToolResponse(
        data: Data,
        model: String,
        credential: ProjectChatService.ProviderCredential,
        projectUsageIdentifier: String?,
        onStreamedText: (@MainActor (String) -> Void)?,
        onUsage: ((Int?, Int?) -> Void)?
    ) async throws -> AgentLLMResponse {
        guard let decoded = try? jsonDecoder.decode(AnthropicToolUseResponse.self, from: data) else {
            throw ProjectChatService.ServiceError.invalidResponse
        }

        let inputTokens = decoded.usage?.inputTokens
        let outputTokens = decoded.usage?.outputTokens
        tokenUsageStore.recordUsage(
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

        var textContent = ""
        var toolCalls: [AgentToolCall] = []

        for block in decoded.content ?? [] {
            switch block.type {
            case "text":
                textContent += block.text ?? ""
            case "tool_use":
                let id = block.id ?? UUID().uuidString
                let name = block.name ?? ""
                var argumentsJSON = "{}"
                if let input = block.input?.value,
                   JSONSerialization.isValidJSONObject(input),
                   let jsonData = try? JSONSerialization.data(withJSONObject: input) {
                    argumentsJSON = String(data: jsonData, encoding: .utf8) ?? "{}"
                }
                toolCalls.append(AgentToolCall(id: id, name: name, argumentsJSON: argumentsJSON))
            default:
                break
            }
        }

        if let onStreamedText, !textContent.isEmpty {
            await onStreamedText(textContent)
        }

        let stopReason: AgentStopReason
        switch decoded.stopReason ?? "" {
        case "tool_use": stopReason = .toolUse
        case "max_tokens": stopReason = .maxTokens
        default: stopReason = toolCalls.isEmpty ? .endTurn : .toolUse
        }

        return AgentLLMResponse(textContent: textContent, toolCalls: toolCalls, usage: usage, stopReason: stopReason)
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
                    let inputValue = parseJSONToJSONValue(tc.argumentsJSON)
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

    private func parseJSONToJSONValue(_ jsonString: String) -> JSONValue {
        guard let data = jsonString.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .object([:]) }
        return jsonObjectToJSONValue(obj)
    }

    private func jsonObjectToJSONValue(_ obj: [String: Any]) -> JSONValue {
        var result: [String: JSONValue] = [:]
        for (key, value) in obj {
            if let str = value as? String { result[key] = .string(str) }
            else if let num = value as? Int { result[key] = .integer(num) }
            else if let num = value as? Double { result[key] = .number(num) }
            else if let bool = value as? Bool { result[key] = .bool(bool) }
            else if let arr = value as? [Any] { result[key] = jsonArrayToJSONValue(arr) }
            else if let dict = value as? [String: Any] { result[key] = jsonObjectToJSONValue(dict) }
            else { result[key] = .null }
        }
        return .object(result)
    }

    private func jsonArrayToJSONValue(_ arr: [Any]) -> JSONValue {
        .array(arr.map { element in
            if let str = element as? String { return .string(str) }
            else if let num = element as? Int { return .integer(num) }
            else if let num = element as? Double { return .number(num) }
            else if let bool = element as? Bool { return .bool(bool) }
            else if let dict = element as? [String: Any] { return jsonObjectToJSONValue(dict) }
            else if let arr = element as? [Any] { return jsonArrayToJSONValue(arr) }
            else { return .null }
        })
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
