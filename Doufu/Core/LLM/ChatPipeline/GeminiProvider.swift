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
        guard let url = buildGenerateContentURL(baseURL: credential.baseURL, model: model, apiKey: apiKey) else {
            throw ProjectChatService.ServiceError.networkFailed(String(localized: "llm.error.invalid_gemini_url"))
        }

        var includeThinkingConfig = true
        let requestedThinkingBudget = executionOptions.geminiThinkingEnabled
            ? configuration.geminiThinkingBudget(effort: initialReasoningEffort)
            : 0

        while true {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = timeoutSeconds
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
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
                        ? .init(thinkingBudget: requestedThinkingBudget) : nil
                )
            )
            request.httpBody = try jsonEncoder.encode(requestBody)

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw ProjectChatService.ServiceError.networkFailed(String(localized: "llm.error.invalid_response"))
            }
            guard (200...299).contains(httpResponse.statusCode) else {
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

            guard let decoded = try? jsonDecoder.decode(GeminiGenerateContentResponse.self, from: data) else {
                throw ProjectChatService.ServiceError.invalidResponse
            }
            let finalResponseText = extractGeminiText(from: decoded)
            guard !finalResponseText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ProjectChatService.ServiceError.invalidResponse
            }

            if let onStreamedText { await onStreamedText(finalResponseText) }

            onUsage?(decoded.usageMetadata?.promptTokenCount, geminiOutputTokenCount(from: decoded.usageMetadata))
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
        let effort = executionOptions.reasoningEffort
        let timeoutSeconds = LLMProviderHelpers.timeoutSeconds(for: effort, configuration: configuration)
        let apiKey: String? = credential.authMode == .apiKey ? credential.bearerToken : nil

        guard let url = buildGenerateContentURL(baseURL: credential.baseURL, model: model, apiKey: apiKey) else {
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

        var requestBody = GeminiToolUseRequest(
            contents: contents,
            tools: [GeminiToolUseRequest.ToolDeclarations(functionDeclarations: funcDeclarations)],
            systemInstruction: GeminiToolUseRequest.SystemInstruction(parts: [GeminiTextPart(text: systemInstruction)]),
            generationConfig: executionOptions.geminiThinkingEnabled
                ? GeminiToolUseRequest.GenerationConfig(
                    thinkingConfig: .init(thinkingBudget: configuration.geminiThinkingBudget(effort: effort))
                )
                : nil
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if credential.authMode == .oauth {
            request.setValue("Bearer \(credential.bearerToken)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try jsonEncoder.encode(requestBody)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProjectChatService.ServiceError.networkFailed("Invalid response")
        }

        if !(200...299).contains(httpResponse.statusCode) {
            if executionOptions.geminiThinkingEnabled,
               LLMProviderHelpers.shouldFallbackThinkingConfiguration(responseBodyData: data) {
                requestBody = GeminiToolUseRequest(
                    contents: contents,
                    tools: [GeminiToolUseRequest.ToolDeclarations(functionDeclarations: funcDeclarations)],
                    systemInstruction: GeminiToolUseRequest.SystemInstruction(parts: [GeminiTextPart(text: systemInstruction)]),
                    generationConfig: nil
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
        guard let decoded = try? jsonDecoder.decode(GeminiToolUseResponse.self, from: data) else {
            throw ProjectChatService.ServiceError.invalidResponse
        }

        let inputTokens = decoded.usageMetadata?.promptTokenCount
        let candidates = decoded.usageMetadata?.candidatesTokenCount ?? 0
        let thoughts = decoded.usageMetadata?.thoughtsTokenCount ?? 0
        let outputTokens = (decoded.usageMetadata?.candidatesTokenCount != nil || decoded.usageMetadata?.thoughtsTokenCount != nil)
            ? candidates + thoughts : nil

        onUsage?(inputTokens, outputTokens)

        let usage = ResponsesUsage(
            inputTokens: inputTokens, outputTokens: outputTokens,
            totalTokens: (inputTokens ?? 0) + (outputTokens ?? 0),
            inputTokensDetails: nil, outputTokensDetails: nil
        )

        guard let firstCandidate = decoded.candidates?.first,
              let parts = firstCandidate.content?.parts
        else {
            throw ProjectChatService.ServiceError.invalidResponse
        }

        var textContent = ""
        var toolCalls: [AgentToolCall] = []

        for part in parts {
            if let text = part.text { textContent += text }
            if let funcCall = part.functionCall {
                let name = funcCall.name ?? ""
                var argumentsJSON = "{}"
                if let argsObj = funcCall.args?.value,
                   JSONSerialization.isValidJSONObject(argsObj),
                   let jsonData = try? JSONSerialization.data(withJSONObject: argsObj) {
                    argumentsJSON = String(data: jsonData, encoding: .utf8) ?? "{}"
                }
                toolCalls.append(AgentToolCall(id: UUID().uuidString, name: name, argumentsJSON: argumentsJSON))
            }
        }

        if let onStreamedText, !textContent.isEmpty {
            await onStreamedText(textContent)
        }

        let stopReason: AgentStopReason = toolCalls.isEmpty ? .endTurn : .toolUse
        return AgentLLMResponse(textContent: textContent, toolCalls: toolCalls, usage: usage, stopReason: stopReason, thinkingContent: nil)
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
            case let .assistantMessage(text, toolCalls):
                var parts: [GeminiPart] = []
                if !text.isEmpty { parts.append(.text(text)) }
                for tc in toolCalls {
                    let argsValue = LLMProviderHelpers.parseJSONToJSONValue(tc.argumentsJSON)
                    parts.append(.functionCall(name: tc.name, args: argsValue))
                }
                if !parts.isEmpty {
                    contents.append(GeminiToolUseRequest.Content(role: "model", parts: parts))
                }
            case let .toolResult(_, name, content, _):
                contents.append(GeminiToolUseRequest.Content(
                    role: "user",
                    parts: [.functionResponse(name: name, response: .object(["result": .string(content)]))]
                ))
            }
        }
        return contents
    }

    // MARK: - Helpers

    private func buildGenerateContentURL(baseURL: URL, model: String, apiKey: String?) -> URL? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return nil }
        let normalizedBasePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let modelPath = "models/\(model):generateContent"
        components.path = normalizedBasePath.isEmpty
            ? "/" + modelPath
            : "/" + normalizedBasePath + "/" + modelPath
        if let apiKey {
            let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedKey.isEmpty {
                var queryItems = components.queryItems ?? []
                queryItems.removeAll { $0.name == "key" }
                queryItems.append(URLQueryItem(name: "key", value: trimmedKey))
                components.queryItems = queryItems
            }
        }
        return components.url
    }



    private func geminiResponseJSONSchema(from format: ResponsesTextFormat?) -> JSONValue? {
        guard let format else { return nil }
        let normalizedType = format.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalizedType == "json_schema" else { return nil }
        return format.schema
    }

    private func geminiOutputTokenCount(from usage: GeminiGenerateContentResponse.UsageMetadata?) -> Int? {
        guard let usage else { return nil }
        let candidates = usage.candidatesTokenCount ?? 0
        let thoughts = usage.thoughtsTokenCount ?? 0
        if usage.candidatesTokenCount == nil, usage.thoughtsTokenCount == nil { return nil }
        return candidates + thoughts
    }

    private func extractGeminiText(from response: GeminiGenerateContentResponse) -> String {
        (response.candidates ?? [])
            .compactMap { candidate -> String? in
                let text = (candidate.content?.parts ?? [])
                    .compactMap { $0.text?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")
                return text.isEmpty ? nil : text
            }
            .joined(separator: "\n")
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
                let thinkingBudget: Int
                private enum CodingKeys: String, CodingKey { case thinkingBudget = "thinking_budget" }
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

    private struct GeminiGenerateContentResponse: Decodable {
        struct Candidate: Decodable {
            struct Content: Decodable {
                struct Part: Decodable { let text: String? }
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
}
