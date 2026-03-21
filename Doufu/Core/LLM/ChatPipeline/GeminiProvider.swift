//
//  GeminiProvider.swift
//  Doufu
//
//  Created by Codex on 2026/03/08.
//

import Foundation

final class GeminiProvider: LLMProviderAdapter {
    private let configuration: ProjectChatConfiguration
    private let jsonDecoder = JSONDecoder()
    private let jsonEncoder: JSONEncoder = {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
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
        let apiKey: String? = credential.authMode == .apiKey ? credential.bearerToken : nil
        guard let url = buildStreamURL(baseURL: credential.baseURL, model: model, apiKey: apiKey) else {
            throw ProjectChatService.ServiceError.networkFailed(String(localized: "llm.error.invalid_gemini_url"))
        }

        var includeThinkingConfig = executionOptions.geminiThinkingEnabled

        while true {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = timeoutSeconds
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            if credential.authMode == .oauth {
                request.setValue("Bearer \(credential.bearerToken)", forHTTPHeaderField: "Authorization")
            }

            let messages = LLMProviderHelpers.normalizedConversationMessages(
                from: inputItems, assistantRole: "model", userRole: "user"
            ).map { item in
                GeminiGenerateContentRequest.Content(
                    role: item.role,
                    parts: [.init(text: item.text)]
                )
            }
            let normalizedInstruction = developerInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
            let requestBody = GeminiGenerateContentRequest(
                systemInstruction: normalizedInstruction.isEmpty
                    ? nil : .init(parts: [.init(text: normalizedInstruction)]),
                contents: messages,
                generationConfig: .init(
                    responseMimeType: responseFormat == nil ? nil : "application/json",
                    responseJsonSchema: geminiResponseJSONSchema(from: responseFormat),
                    thinkingConfig: includeThinkingConfig
                        ? geminiThinkingConfig(model: model, effort: initialReasoningEffort) : nil
                )
            )
            request.httpBody = try jsonEncoder.encode(requestBody)

            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw ProjectChatService.ServiceError.networkFailed(String(localized: "llm.error.invalid_response"))
            }
            guard (200...299).contains(httpResponse.statusCode) else {
                let data = try await LLMProviderHelpers.consumeStreamBytes(bytes: bytes)
                if includeThinkingConfig, LLMProviderHelpers.shouldFallbackThinkingConfiguration(responseBodyData: data) {
                    includeThinkingConfig = false
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

            let result = try await consumeStreamingResponse(
                bytes: bytes, timeoutSeconds: timeoutSeconds,
                onStreamedText: onStreamedText
            )

            guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ProjectChatService.ServiceError.invalidResponse
            }

            onUsage?(result.inputTokens, result.outputTokens)
            return result.text
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
        let apiKey: String? = credential.authMode == .apiKey ? credential.bearerToken : nil

        guard let url = buildStreamURL(baseURL: credential.baseURL, model: model, apiKey: apiKey) else {
            throw ProjectChatService.ServiceError.networkFailed("Invalid Gemini URL")
        }

        let contents = buildToolUseContents(from: conversationItems)
        let funcDeclarations = tools.map { tool in
            GeminiFunctionDeclaration(
                name: tool.name,
                description: tool.description,
                parameters: convertSchemaToGeminiFormat(tool.parameters)
            )
        }

        var includeThinking = executionOptions.geminiThinkingEnabled

        while true {
            let requestBody = GeminiToolUseRequest(
                contents: contents,
                tools: [GeminiToolUseRequest.ToolDeclarations(functionDeclarations: funcDeclarations)],
                systemInstruction: GeminiToolUseRequest.SystemInstruction(parts: [GeminiTextPart(text: systemInstruction)]),
                generationConfig: includeThinking
                    ? GeminiToolUseRequest.GenerationConfig(
                        thinkingConfig: geminiToolUseThinkingConfig(model: model, effort: effort)
                    )
                    : nil
            )

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = timeoutSeconds
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            if credential.authMode == .oauth {
                request.setValue("Bearer \(credential.bearerToken)", forHTTPHeaderField: "Authorization")
            }
            request.httpBody = try jsonEncoder.encode(requestBody)

            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw ProjectChatService.ServiceError.networkFailed("Invalid response")
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
                throw ProjectChatService.ServiceError.networkFailed(message)
            }

            return try await consumeToolUseStream(
                bytes: bytes, timeoutSeconds: timeoutSeconds,
                onStreamedText: onStreamedText, onUsage: onUsage
            )
        }
    }

    // MARK: - SSE Stream Consumer (non-tool-use)

    private struct StreamingResult {
        let text: String
        let inputTokens: Int?
        let outputTokens: Int?
    }

    private func consumeStreamingResponse(
        bytes: URLSession.AsyncBytes,
        timeoutSeconds: TimeInterval,
        onStreamedText: (@MainActor (String) -> Void)?
    ) async throws -> StreamingResult {
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
                      let chunk = try? JSONSerialization.jsonObject(with: eventData) as? [String: Any]
                else { continue }

                // Extract text from candidates[0].content.parts
                if let candidates = chunk["candidates"] as? [[String: Any]],
                   let firstCandidate = candidates.first,
                   let content = firstCandidate["content"] as? [String: Any],
                   let parts = content["parts"] as? [[String: Any]] {
                    for part in parts {
                        if let text = part["text"] as? String, !text.isEmpty {
                            streamedText.append(text)
                            if let onStreamedText { onStreamedText(streamedText) }
                        }
                    }
                }

                // Extract usage metadata from the chunk (typically in the last chunk)
                if let usage = chunk["usageMetadata"] as? [String: Any] {
                    if let prompt = usage["promptTokenCount"] as? Int { inputTokens = prompt }
                    let candidates = usage["candidatesTokenCount"] as? Int ?? 0
                    let thoughts = usage["thoughtsTokenCount"] as? Int ?? 0
                    if usage["candidatesTokenCount"] != nil || usage["thoughtsTokenCount"] != nil {
                        outputTokens = candidates + thoughts
                    }
                }
            }

            return StreamingResult(text: streamedText, inputTokens: inputTokens, outputTokens: outputTokens)
        }
    }

    // MARK: - SSE Stream Consumer (tool use)

    private func consumeToolUseStream(
        bytes: URLSession.AsyncBytes,
        timeoutSeconds: TimeInterval,
        onStreamedText: (@MainActor (String) -> Void)?,
        onUsage: ((Int?, Int?) -> Void)?
    ) async throws -> AgentLLMResponse {
        try await LLMProviderHelpers.withStreamTimeout(seconds: timeoutSeconds + configuration.streamCompletionGraceSeconds) {
            var streamedText = ""
            var toolCalls: [AgentToolCall] = []
            var inputTokens: Int?
            var outputTokens: Int?
            var finishReason: String?

            for try await rawLine in bytes.lines {
                let line = rawLine.trimmingCharacters(in: .newlines)
                guard line.hasPrefix("data:") else { continue }
                var dataLine = String(line.dropFirst(5))
                if dataLine.hasPrefix(" ") { dataLine.removeFirst() }
                let trimmed = dataLine.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }

                guard let eventData = trimmed.data(using: .utf8),
                      let chunk = try? JSONSerialization.jsonObject(with: eventData) as? [String: Any]
                else { continue }

                if let candidates = chunk["candidates"] as? [[String: Any]],
                   let firstCandidate = candidates.first {
                    // Capture finish reason
                    if let reason = firstCandidate["finishReason"] as? String {
                        finishReason = reason
                    }

                    if let content = firstCandidate["content"] as? [String: Any],
                       let parts = content["parts"] as? [[String: Any]] {
                        for part in parts {
                            if let text = part["text"] as? String, !text.isEmpty {
                                streamedText.append(text)
                                if let onStreamedText { onStreamedText(streamedText) }
                            }
                            if let funcCall = part["functionCall"] as? [String: Any] {
                                let name = funcCall["name"] as? String ?? ""
                                // Use Gemini-provided ID when available (Gemini 3+),
                                // fall back to UUID for older models.
                                let callID = funcCall["id"] as? String ?? UUID().uuidString
                                var argumentsJSON = "{}"
                                if let args = funcCall["args"],
                                   JSONSerialization.isValidJSONObject(args),
                                   let jsonData = try? JSONSerialization.data(withJSONObject: args) {
                                    argumentsJSON = String(data: jsonData, encoding: .utf8) ?? "{}"
                                }
                                toolCalls.append(AgentToolCall(id: callID, name: name, argumentsJSON: argumentsJSON))
                            }
                        }
                    }
                }

                if let usage = chunk["usageMetadata"] as? [String: Any] {
                    if let prompt = usage["promptTokenCount"] as? Int { inputTokens = prompt }
                    let candidates = usage["candidatesTokenCount"] as? Int ?? 0
                    let thoughts = usage["thoughtsTokenCount"] as? Int ?? 0
                    if usage["candidatesTokenCount"] != nil || usage["thoughtsTokenCount"] != nil {
                        outputTokens = candidates + thoughts
                    }
                }
            }

            onUsage?(inputTokens, outputTokens)

            let usage = ResponsesUsage(
                inputTokens: inputTokens, outputTokens: outputTokens,
                totalTokens: (inputTokens ?? 0) + (outputTokens ?? 0),
                inputTokensDetails: nil, outputTokensDetails: nil
            )

            let stopReason: AgentStopReason
            if !toolCalls.isEmpty {
                stopReason = .toolUse
            } else if finishReason == "MAX_TOKENS" {
                stopReason = .maxTokens
            } else {
                stopReason = .endTurn
            }

            return AgentLLMResponse(
                textContent: streamedText, toolCalls: toolCalls,
                usage: usage, stopReason: stopReason, thinkingContent: nil
            )
        }
    }

    // MARK: - Build Contents

    private func buildToolUseContents(from items: [AgentConversationItem]) -> [GeminiToolUseRequest.Content] {
        var contents: [GeminiToolUseRequest.Content] = []
        for item in items {
            switch item {
            case let .userMessage(text):
                contents.append(GeminiToolUseRequest.Content(
                    role: "user", parts: [.text(text)]
                ))
            case let .assistantMessage(msg):
                var parts: [GeminiPart] = []
                if !msg.text.isEmpty { parts.append(.text(msg.text)) }
                for tc in msg.toolCalls {
                    let argsValue = LLMProviderHelpers.parseJSONToJSONValue(tc.argumentsJSON)
                    parts.append(.functionCall(id: tc.id, name: tc.name, args: argsValue))
                }
                if !parts.isEmpty {
                    contents.append(GeminiToolUseRequest.Content(role: "model", parts: parts))
                }
            case let .toolResult(callID, name, content, _):
                contents.append(GeminiToolUseRequest.Content(
                    role: "user",
                    parts: [.functionResponse(id: callID, name: name, response: .object(["result": .string(content)]))]
                ))
            }
        }
        return contents
    }

    // MARK: - Helpers

    /// Builds a streaming URL: `models/{model}:streamGenerateContent?alt=sse`
    private func buildStreamURL(baseURL: URL, model: String, apiKey: String?) -> URL? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return nil }
        let normalizedBasePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let modelPath = "models/\(model):streamGenerateContent"
        components.path = normalizedBasePath.isEmpty
            ? "/" + modelPath
            : "/" + normalizedBasePath + "/" + modelPath
        var queryItems = components.queryItems ?? []
        queryItems.removeAll { $0.name == "alt" }
        queryItems.append(URLQueryItem(name: "alt", value: "sse"))
        if let apiKey {
            let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedKey.isEmpty {
                queryItems.removeAll { $0.name == "key" }
                queryItems.append(URLQueryItem(name: "key", value: trimmedKey))
            }
        }
        components.queryItems = queryItems
        return components.url
    }

    // MARK: - Thinking Config

    /// Returns a thinking config appropriate for the model.
    /// Gemini 2.5 uses `thinkingBudget` (integer tokens).
    /// Gemini 3+ uses `thinkingLevel` (LOW/MEDIUM/HIGH).
    /// The two parameters CANNOT be sent together — we detect the model
    /// generation and send only the appropriate one.
    private func geminiThinkingConfig(model: String, effort: ProjectChatService.ReasoningEffort) -> GeminiGenerateContentRequest.GenerationConfig.ThinkingConfig {
        if usesThinkingLevel(model: model) {
            return .init(thinkingBudget: nil, thinkingLevel: geminiThinkingLevel(for: effort))
        }
        return .init(thinkingBudget: configuration.geminiThinkingBudget(effort: effort), thinkingLevel: nil)
    }

    private func geminiToolUseThinkingConfig(model: String, effort: ProjectChatService.ReasoningEffort) -> GeminiToolUseRequest.GenerationConfig.ThinkingConfig {
        if usesThinkingLevel(model: model) {
            return .init(thinkingBudget: nil, thinkingLevel: geminiThinkingLevel(for: effort))
        }
        return .init(thinkingBudget: configuration.geminiThinkingBudget(effort: effort), thinkingLevel: nil)
    }

    /// Gemini 3+ models use `thinkingLevel`; Gemini 2.5 uses `thinkingBudget`.
    private func usesThinkingLevel(model: String) -> Bool {
        // Gemini 3.x models: "gemini-3", "gemini-3.1-pro", etc.
        return model.lowercased().hasPrefix("gemini-3")
    }

    private func geminiThinkingLevel(for effort: ProjectChatService.ReasoningEffort) -> String {
        switch effort {
        case .low:    return "LOW"
        case .medium: return "MEDIUM"
        case .high:   return "HIGH"
        case .xhigh:  return "HIGH"
        }
    }

    private func geminiResponseJSONSchema(from format: ResponsesTextFormat?) -> JSONValue? {
        guard let format else { return nil }
        let normalizedType = format.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalizedType == "json_schema" else { return nil }
        return format.schema
    }

    private func convertSchemaToGeminiFormat(_ schema: JSONValue) -> JSONValue {
        switch schema {
        case let .object(dict):
            var result: [String: JSONValue] = [:]
            for (key, value) in dict {
                if key == "type", case let .string(typeStr) = value {
                    result["type"] = .string(typeStr.uppercased())
                } else if key == "additionalProperties" {
                    continue
                } else {
                    result[key] = convertSchemaToGeminiFormat(value)
                }
            }
            return .object(result)
        case let .array(arr):
            return .array(arr.map { convertSchemaToGeminiFormat($0) })
        default:
            return schema
        }
    }

    // MARK: - Private types for non-tool-use requests

    private struct GeminiGenerateContentRequest: Encodable {
        struct Content: Encodable {
            struct Part: Encodable { let text: String }
            let role: String
            let parts: [Part]
        }
        struct SystemInstruction: Encodable {
            let parts: [Content.Part]
        }
        struct GenerationConfig: Encodable {
            struct ThinkingConfig: Encodable {
                let thinkingBudget: Int?
                let thinkingLevel: String?
                func encode(to encoder: Encoder) throws {
                    var container = encoder.container(keyedBy: CodingKeys.self)
                    try container.encodeIfPresent(thinkingBudget, forKey: .thinkingBudget)
                    try container.encodeIfPresent(thinkingLevel, forKey: .thinkingLevel)
                }
                private enum CodingKeys: String, CodingKey {
                    case thinkingBudget = "thinking_budget"
                    case thinkingLevel = "thinking_level"
                }
            }
            let responseMimeType: String?
            let responseJsonSchema: JSONValue?
            let thinkingConfig: ThinkingConfig?
            private enum CodingKeys: String, CodingKey {
                case responseMimeType = "response_mime_type"
                case responseJsonSchema = "response_json_schema"
                case thinkingConfig = "thinking_config"
            }
        }
        let systemInstruction: SystemInstruction?
        let contents: [Content]
        let generationConfig: GenerationConfig?
        private enum CodingKeys: String, CodingKey {
            case systemInstruction = "system_instruction"
            case contents
            case generationConfig = "generation_config"
        }
    }
}
