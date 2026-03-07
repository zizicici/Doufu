//
//  LLMStreamingClient.swift
//  Doufu
//
//  Created by Codex on 2026/03/05.
//

import Foundation

final class LLMStreamingClient {
    private struct StreamingResponseResult {
        let text: String
        let usage: ResponsesUsage?
    }

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
            case model
            case system
            case messages
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

    private struct GeminiGenerateContentRequest: Encodable {
        struct Content: Encodable {
            struct Part: Encodable {
                let text: String
            }

            let role: String
            let parts: [Part]
        }

        struct SystemInstruction: Encodable {
            let parts: [Content.Part]
        }

        struct GenerationConfig: Encodable {
            struct ThinkingConfig: Encodable {
                let thinkingBudget: Int

                private enum CodingKeys: String, CodingKey {
                    case thinkingBudget = "thinking_budget"
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

    private struct GeminiGenerateContentResponse: Decodable {
        struct Candidate: Decodable {
            struct Content: Decodable {
                struct Part: Decodable {
                    let text: String?
                }

                let parts: [Part]?
            }

            let content: Content?
        }

        struct UsageMetadata: Decodable {
            let promptTokenCount: Int?
            let candidatesTokenCount: Int?
            let thoughtsTokenCount: Int?
            let totalTokenCount: Int?

            private enum CodingKeys: String, CodingKey {
                case promptTokenCount
                case candidatesTokenCount
                case thoughtsTokenCount
                case totalTokenCount
            }
        }

        let candidates: [Candidate]?
        let usageMetadata: UsageMetadata?
    }

    private let configuration: ProjectChatConfiguration
    private let jsonDecoder = JSONDecoder()
    private let jsonEncoder = JSONEncoder()
    private let tokenUsageStore = LLMTokenUsageStore.shared

    init(configuration: ProjectChatConfiguration) {
        self.configuration = configuration
        jsonEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    func requestModelResponseStreaming(
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
        onUsage: ((Int?, Int?) -> Void)? = nil
    ) async throws -> String {
        switch credential.providerKind {
        case .openAICompatible:
            break
        case .anthropic:
            return try await requestAnthropicModelResponse(
                requestLabel: requestLabel,
                model: model,
                developerInstruction: developerInstruction,
                inputItems: inputItems,
                credential: credential,
                projectUsageIdentifier: projectUsageIdentifier,
                initialReasoningEffort: initialReasoningEffort,
                executionOptions: executionOptions,
                responseFormat: responseFormat,
                onStreamedText: onStreamedText,
                onUsage: onUsage
            )
        case .googleGemini:
            return try await requestGeminiModelResponse(
                requestLabel: requestLabel,
                model: model,
                developerInstruction: developerInstruction,
                inputItems: inputItems,
                credential: credential,
                projectUsageIdentifier: projectUsageIdentifier,
                initialReasoningEffort: initialReasoningEffort,
                executionOptions: executionOptions,
                responseFormat: responseFormat,
                onStreamedText: onStreamedText,
                onUsage: onUsage
            )
        }

        var activeRequestBody = ResponsesRequest(
            model: model,
            instructions: developerInstruction,
            input: inputItems,
            stream: true,
            store: isChatGPTCodexBackend(url: credential.baseURL) ? false : nil,
            reasoning: ResponsesReasoning(effort: initialReasoningEffort),
            text: responseFormat.map { ResponsesTextConfiguration(format: $0) }
        )
        var didFallbackReasoning = false
        var didFallbackResponseFormat = false

        while true {
            var request = URLRequest(url: credential.baseURL.appendingPathComponent("responses"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            request.setValue("Bearer \(credential.bearerToken)", forHTTPHeaderField: "Authorization")
            request.setValue("responses=experimental", forHTTPHeaderField: "OpenAI-Beta")
            request.setValue("codex_cli_rs", forHTTPHeaderField: "originator")
            let timeoutSeconds: TimeInterval
            switch activeRequestBody.reasoning?.effort ?? .high {
            case .low:
                timeoutSeconds = configuration.lowReasoningTimeoutSeconds
            case .medium:
                timeoutSeconds = configuration.mediumReasoningTimeoutSeconds
            case .high:
                timeoutSeconds = configuration.highReasoningTimeoutSeconds
            case .xhigh:
                timeoutSeconds = configuration.xhighReasoningTimeoutSeconds
            }
            request.timeoutInterval = timeoutSeconds
            if let accountID = credential.chatGPTAccountID?.trimmingCharacters(in: .whitespacesAndNewlines), !accountID.isEmpty {
                request.setValue(accountID, forHTTPHeaderField: "chatgpt-account-id")
            }
            request.httpBody = try jsonEncoder.encode(activeRequestBody)

            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw ProjectChatService.ServiceError.networkFailed("请求失败：无效响应。")
            }

            guard (200 ... 299).contains(httpResponse.statusCode) else {
                let data = try await consumeStreamBytes(bytes: bytes)

                if shouldFallbackReasoningToHigh(
                    currentEffort: activeRequestBody.reasoning?.effort,
                    responseBodyData: data,
                    alreadyFallback: didFallbackReasoning
                ) {
                    didFallbackReasoning = true
                    activeRequestBody.reasoning = ResponsesReasoning(effort: .high)
                    debugLog("[DoufuCodexChat Debug] reasoning xhigh was rejected by backend; retrying with high. stage=\(requestLabel)")
                    continue
                }

                if shouldFallbackResponseFormat(
                    textConfiguration: activeRequestBody.text,
                    responseBodyData: data,
                    alreadyFallback: didFallbackResponseFormat
                ) {
                    didFallbackResponseFormat = true
                    activeRequestBody.text = nil
                    debugLog("[DoufuCodexChat Debug] text.format json_schema was rejected by backend; retrying without response_format. stage=\(requestLabel)")
                    continue
                }

                logFailedResponseDebug(
                    request: request,
                    httpResponse: httpResponse,
                    responseBodyData: data,
                    requestLabel: requestLabel
                )
                let message = parseErrorMessage(from: data) ?? HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
                throw ProjectChatService.ServiceError.networkFailed("请求失败：\(message)")
            }

            do {
                let responseResult = try await consumeStreamingResponse(
                    bytes: bytes,
                    request: request,
                    httpResponse: httpResponse,
                    onStreamedText: onStreamedText,
                    timeoutSeconds: timeoutSeconds,
                    requestLabel: requestLabel
                )
                tokenUsageStore.recordUsage(
                    providerID: credential.providerID,
                    providerLabel: credential.providerLabel,
                    model: model,
                    inputTokens: responseResult.usage?.inputTokens,
                    outputTokens: responseResult.usage?.outputTokens,
                    projectIdentifier: projectUsageIdentifier
                )
                onUsage?(responseResult.usage?.inputTokens, responseResult.usage?.outputTokens)
                return responseResult.text
            } catch let serviceError as ProjectChatService.ServiceError {
                guard case let .networkFailed(errorMessage) = serviceError else {
                    throw serviceError
                }

                if shouldFallbackReasoningToHigh(
                    currentEffort: activeRequestBody.reasoning?.effort,
                    errorMessage: errorMessage,
                    alreadyFallback: didFallbackReasoning
                ) {
                    didFallbackReasoning = true
                    activeRequestBody.reasoning = ResponsesReasoning(effort: .high)
                    debugLog("[DoufuCodexChat Debug] reasoning xhigh was rejected during streaming; retrying with high. stage=\(requestLabel)")
                    continue
                }

                if shouldFallbackResponseFormat(
                    textConfiguration: activeRequestBody.text,
                    errorMessage: errorMessage,
                    alreadyFallback: didFallbackResponseFormat
                ) {
                    didFallbackResponseFormat = true
                    activeRequestBody.text = nil
                    debugLog("[DoufuCodexChat Debug] text.format json_schema was rejected during streaming; retrying without response_format. stage=\(requestLabel)")
                    continue
                }

                throw serviceError
            }
        }
    }

    private func requestAnthropicModelResponse(
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
        let timeoutSeconds = timeoutSeconds(for: initialReasoningEffort)
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
            applyProviderAuthorizationHeaders(to: &request, credential: credential)

            let messages = normalizedConversationMessages(
                from: inputItems,
                assistantRole: "assistant",
                userRole: "user"
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
                maxTokens: 8192,
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
            guard (200 ... 299).contains(httpResponse.statusCode) else {
                if includeThinking, shouldFallbackThinkingConfiguration(responseBodyData: data) {
                    includeThinking = false
                    debugLog("[DoufuCodexChat Debug] anthropic thinking config was rejected; retrying without thinking. stage=\(requestLabel)")
                    continue
                }
                if includeOutputConfig, shouldFallbackAnthropicOutputConfiguration(responseBodyData: data) {
                    includeOutputConfig = false
                    debugLog("[DoufuCodexChat Debug] anthropic output_config.format was rejected; retrying without structured output config. stage=\(requestLabel)")
                    continue
                }
                logFailedResponseDebug(
                    request: request,
                    httpResponse: httpResponse,
                    responseBodyData: data,
                    requestLabel: requestLabel
                )
                let message = parseErrorMessage(from: data) ?? HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
                throw ProjectChatService.ServiceError.networkFailed("请求失败：\(message)")
            }

            guard let decoded = try? jsonDecoder.decode(AnthropicMessageResponse.self, from: data) else {
                logFailedResponseDebug(
                    request: request,
                    httpResponse: httpResponse,
                    responseBodyData: data,
                    requestLabel: "\(requestLabel)_anthropic_decode_failed"
                )
                throw ProjectChatService.ServiceError.invalidResponse
            }
            let finalResponseText = extractAnthropicText(from: decoded, rawResponseData: data)
            guard !finalResponseText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                logFailedResponseDebug(
                    request: request,
                    httpResponse: httpResponse,
                    responseBodyData: data,
                    requestLabel: "\(requestLabel)_anthropic_empty_text"
                )
                throw ProjectChatService.ServiceError.invalidResponse
            }

            if let onStreamedText {
                await onStreamedText(finalResponseText)
            }

            tokenUsageStore.recordUsage(
                providerID: credential.providerID,
                providerLabel: credential.providerLabel,
                model: model,
                inputTokens: decoded.usage?.inputTokens,
                outputTokens: decoded.usage?.outputTokens,
                projectIdentifier: projectUsageIdentifier
            )
            onUsage?(decoded.usage?.inputTokens, decoded.usage?.outputTokens)
            logSuccessfulResponseDebug(
                request: request,
                httpResponse: httpResponse,
                finalResponseText: finalResponseText,
                usage: nil,
                rawSSEEventPayloads: [],
                requestLabel: requestLabel
            )
            return finalResponseText
        }
    }

    private func requestGeminiModelResponse(
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
        let timeoutSeconds = timeoutSeconds(for: initialReasoningEffort)
        let apiKey: String? = credential.authMode == .apiKey ? credential.bearerToken : nil
        guard let url = buildGeminiGenerateContentURL(baseURL: credential.baseURL, model: model, apiKey: apiKey) else {
            throw ProjectChatService.ServiceError.networkFailed("请求失败：Gemini URL 无效。")
        }

        var includeThinkingConfig = true
        let requestedThinkingBudget = executionOptions.geminiThinkingEnabled
            ? geminiThinkingBudget(for: initialReasoningEffort)
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

            let messages = normalizedConversationMessages(
                from: inputItems,
                assistantRole: "model",
                userRole: "user"
            ).map { item in
                GeminiGenerateContentRequest.Content(
                    role: item.role,
                    parts: [.init(text: item.text)]
                )
            }
            let normalizedInstruction = developerInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
            let requestBody = GeminiGenerateContentRequest(
                systemInstruction: normalizedInstruction.isEmpty
                    ? nil
                    : .init(parts: [.init(text: normalizedInstruction)]),
                contents: messages,
                generationConfig: .init(
                    responseMimeType: responseFormat == nil ? nil : "application/json",
                    responseJsonSchema: geminiResponseJSONSchema(from: responseFormat),
                    thinkingConfig: includeThinkingConfig
                        ? .init(thinkingBudget: requestedThinkingBudget)
                        : nil
                )
            )
            request.httpBody = try jsonEncoder.encode(requestBody)

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw ProjectChatService.ServiceError.networkFailed("请求失败：无效响应。")
            }
            guard (200 ... 299).contains(httpResponse.statusCode) else {
                if includeThinkingConfig, shouldFallbackThinkingConfiguration(responseBodyData: data) {
                    includeThinkingConfig = false
                    debugLog("[DoufuCodexChat Debug] gemini thinking config was rejected; retrying without thinking config. stage=\(requestLabel)")
                    continue
                }
                logFailedResponseDebug(
                    request: request,
                    httpResponse: httpResponse,
                    responseBodyData: data,
                    requestLabel: requestLabel
                )
                let message = parseErrorMessage(from: data) ?? HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
                throw ProjectChatService.ServiceError.networkFailed("请求失败：\(message)")
            }

            guard let decoded = try? jsonDecoder.decode(GeminiGenerateContentResponse.self, from: data) else {
                logFailedResponseDebug(
                    request: request,
                    httpResponse: httpResponse,
                    responseBodyData: data,
                    requestLabel: "\(requestLabel)_gemini_decode_failed"
                )
                throw ProjectChatService.ServiceError.invalidResponse
            }
            let finalResponseText = extractGeminiText(from: decoded)
            guard !finalResponseText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                logFailedResponseDebug(
                    request: request,
                    httpResponse: httpResponse,
                    responseBodyData: data,
                    requestLabel: "\(requestLabel)_gemini_empty_text"
                )
                throw ProjectChatService.ServiceError.invalidResponse
            }

            if let onStreamedText {
                await onStreamedText(finalResponseText)
            }

            tokenUsageStore.recordUsage(
                providerID: credential.providerID,
                providerLabel: credential.providerLabel,
                model: model,
                inputTokens: decoded.usageMetadata?.promptTokenCount,
                outputTokens: geminiOutputTokenCount(from: decoded.usageMetadata),
                projectIdentifier: projectUsageIdentifier
            )
            onUsage?(decoded.usageMetadata?.promptTokenCount, geminiOutputTokenCount(from: decoded.usageMetadata))
            logSuccessfulResponseDebug(
                request: request,
                httpResponse: httpResponse,
                finalResponseText: finalResponseText,
                usage: nil,
                rawSSEEventPayloads: [],
                requestLabel: requestLabel
            )
            return finalResponseText
        }
    }

    private func applyProviderAuthorizationHeaders(
        to request: inout URLRequest,
        credential: ProjectChatService.ProviderCredential
    ) {
        if credential.providerKind == .anthropic, usesOfficialAnthropicAuthentication(credential.baseURL) {
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

    private func timeoutSeconds(for effort: ResponsesReasoning.Effort) -> TimeInterval {
        switch effort {
        case .low:
            return configuration.lowReasoningTimeoutSeconds
        case .medium:
            return configuration.mediumReasoningTimeoutSeconds
        case .high:
            return configuration.highReasoningTimeoutSeconds
        case .xhigh:
            return configuration.xhighReasoningTimeoutSeconds
        }
    }

    private func anthropicThinkingBudgetTokens(for effort: ResponsesReasoning.Effort) -> Int {
        switch effort {
        case .low:
            return 1_024
        case .medium:
            return 2_048
        case .high:
            return 3_072
        case .xhigh:
            return 4_096
        }
    }

    private func geminiThinkingBudget(for effort: ResponsesReasoning.Effort) -> Int {
        switch effort {
        case .low:
            return 256
        case .medium:
            return 512
        case .high:
            return 1_024
        case .xhigh:
            return 2_048
        }
    }

    private func shouldFallbackThinkingConfiguration(responseBodyData: Data) -> Bool {
        let message = parseErrorMessage(from: responseBodyData)?.lowercased() ?? ""
        guard !message.isEmpty else {
            return false
        }
        if message.contains("thinking") || message.contains("budget") {
            return true
        }
        return false
    }

    private func shouldFallbackAnthropicOutputConfiguration(responseBodyData: Data) -> Bool {
        let message = parseErrorMessage(from: responseBodyData)?.lowercased() ?? ""
        guard !message.isEmpty else {
            return false
        }

        let hints = [
            "output_config",
            "output format",
            "output_format",
            "json_schema",
            "unsupported",
            "unknown field",
            "additional property"
        ]
        return hints.contains { message.contains($0) }
    }

    private func normalizedConversationMessages(
        from inputItems: [ResponseInputMessage],
        assistantRole: String,
        userRole: String
    ) -> [(role: String, text: String)] {
        inputItems.compactMap { input in
            let normalizedRole = input.role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let role: String
            switch normalizedRole {
            case "assistant":
                role = assistantRole
            case "user":
                role = userRole
            default:
                return nil
            }

            let text = input.content
                .map(\.text)
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                return nil
            }
            return (role: role, text: text)
        }
    }

    private func extractAnthropicText(from response: AnthropicMessageResponse, rawResponseData: Data) -> String {
        let textFromContentBlocks = (response.content ?? [])
            .compactMap { content -> String? in
                guard (content.type?.lowercased() ?? "text") == "text" else {
                    return nil
                }
                let text = content.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !text.isEmpty else {
                    return nil
                }
                return text
            }
            .joined(separator: "\n")
        if !textFromContentBlocks.isEmpty {
            return textFromContentBlocks
        }

        // Structured outputs may be returned as `output_json` blocks instead of plain text blocks.
        guard
            let object = try? JSONSerialization.jsonObject(with: rawResponseData) as? [String: Any],
            let contentBlocks = object["content"] as? [Any]
        else {
            return ""
        }
        let extracted = contentBlocks.compactMap { block -> String? in
            guard let dictionary = block as? [String: Any] else {
                return nil
            }
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

    private func extractGeminiText(from response: GeminiGenerateContentResponse) -> String {
        (response.candidates ?? [])
            .compactMap { candidate -> String? in
                let text = (candidate.content?.parts ?? [])
                    .compactMap { part -> String? in
                        let value = part.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        guard !value.isEmpty else {
                            return nil
                        }
                        return value
                    }
                    .joined(separator: "\n")
                return text.isEmpty ? nil : text
            }
            .joined(separator: "\n")
    }

    private func buildGeminiGenerateContentURL(
        baseURL: URL,
        model: String,
        apiKey: String?
    ) -> URL? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }

        let normalizedBasePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let modelPath = "models/\(model):generateContent"
        if normalizedBasePath.isEmpty {
            components.path = "/" + modelPath
        } else {
            components.path = "/" + normalizedBasePath + "/" + modelPath
        }

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

    private func anthropicOutputConfig(from format: ResponsesTextFormat) -> AnthropicMessageRequest.OutputConfig? {
        let normalizedType = format.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalizedType == "json_schema" else {
            return nil
        }
        return AnthropicMessageRequest.OutputConfig(
            format: .init(
                type: normalizedType,
                schema: format.schema
            )
        )
    }

    private func geminiResponseJSONSchema(from format: ResponsesTextFormat?) -> JSONValue? {
        guard let format else {
            return nil
        }

        let normalizedType = format.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalizedType == "json_schema" else {
            return nil
        }
        return format.schema
    }

    private func geminiOutputTokenCount(from usage: GeminiGenerateContentResponse.UsageMetadata?) -> Int? {
        guard let usage else {
            return nil
        }

        let candidates = usage.candidatesTokenCount ?? 0
        let thoughts = usage.thoughtsTokenCount ?? 0
        if usage.candidatesTokenCount == nil, usage.thoughtsTokenCount == nil {
            return nil
        }
        return candidates + thoughts
    }

    private func usesOfficialAnthropicAuthentication(_ baseURL: URL) -> Bool {
        guard let host = baseURL.host?.lowercased() else {
            return false
        }
        return host == "api.anthropic.com" || host.hasSuffix(".anthropic.com")
    }

    private func serializedJSONObjectString(from object: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(object) else {
            return nil
        }
        guard let data = try? JSONSerialization.data(withJSONObject: object) else {
            return nil
        }
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
    }

    private func consumeStreamingResponse(
        bytes: URLSession.AsyncBytes,
        request: URLRequest,
        httpResponse: HTTPURLResponse,
        onStreamedText: (@MainActor (String) -> Void)?,
        timeoutSeconds: TimeInterval,
        requestLabel: String
    ) async throws -> StreamingResponseResult {
        return try await withTimeout(seconds: timeoutSeconds + configuration.streamCompletionGraceSeconds) { [self] in
            var streamedText = ""
            var completedResponseText: String?
            var usage: ResponsesUsage?
            var pendingDataLines: [String] = []
            var rawSSEEventPayloads: [String] = []

            for try await rawLine in bytes.lines {
                let line = rawLine.trimmingCharacters(in: .newlines)
                if line.isEmpty {
                    self.recordSSEEventPayload(dataLines: pendingDataLines, into: &rawSSEEventPayloads)
                    try await self.processSSEEvent(
                        from: pendingDataLines,
                        streamedText: &streamedText,
                        completedResponseText: &completedResponseText,
                        usage: &usage,
                        onStreamedText: onStreamedText
                    )
                    pendingDataLines.removeAll(keepingCapacity: true)
                    continue
                }

                guard line.hasPrefix("data:") else {
                    continue
                }

                var dataLine = String(line.dropFirst(5))
                if dataLine.hasPrefix(" ") {
                    dataLine.removeFirst()
                }
                pendingDataLines.append(dataLine)
            }

            self.recordSSEEventPayload(dataLines: pendingDataLines, into: &rawSSEEventPayloads)
            try await self.processSSEEvent(
                from: pendingDataLines,
                streamedText: &streamedText,
                completedResponseText: &completedResponseText,
                usage: &usage,
                onStreamedText: onStreamedText
            )

            let normalizedStreamedText = streamedText.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedCompletedResponseText = completedResponseText?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            let finalResponseText: String?
            if !normalizedStreamedText.isEmpty {
                finalResponseText = normalizedStreamedText
            } else if !normalizedCompletedResponseText.isEmpty {
                finalResponseText = normalizedCompletedResponseText
            } else {
                finalResponseText = nil
            }

            if let finalResponseText {
                self.logSuccessfulResponseDebug(
                    request: request,
                    httpResponse: httpResponse,
                    finalResponseText: finalResponseText,
                    usage: usage,
                    rawSSEEventPayloads: rawSSEEventPayloads,
                    requestLabel: requestLabel
                )
                return StreamingResponseResult(text: finalResponseText, usage: usage)
            }

            self.logInvalidResponseDebug(
                request: request,
                httpResponse: httpResponse,
                streamedText: streamedText,
                completedResponseText: completedResponseText,
                rawSSEEventPayloads: rawSSEEventPayloads,
                requestLabel: requestLabel
            )
            throw ProjectChatService.ServiceError.invalidResponse
        }
    }

    private func processSSEEvent(
        from dataLines: [String],
        streamedText: inout String,
        completedResponseText: inout String?,
        usage: inout ResponsesUsage?,
        onStreamedText: (@MainActor (String) -> Void)?
    ) async throws {
        guard !dataLines.isEmpty else {
            return
        }

        let eventPayload = dataLines.joined(separator: "\n")
        if eventPayload == "[DONE]" {
            return
        }

        if let (eventObject, eventType) = decodeSSEEvent(from: eventPayload) {
            try await handleSSEEventObject(
                eventObject,
                eventType: eventType,
                streamedText: &streamedText,
                completedResponseText: &completedResponseText,
                usage: &usage,
                onStreamedText: onStreamedText
            )
            return
        }

        var handledAny = false
        for line in dataLines {
            let candidate = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !candidate.isEmpty, candidate != "[DONE]" else {
                continue
            }
            guard let (eventObject, eventType) = decodeSSEEvent(from: candidate) else {
                continue
            }
            handledAny = true
            try await handleSSEEventObject(
                eventObject,
                eventType: eventType,
                streamedText: &streamedText,
                completedResponseText: &completedResponseText,
                usage: &usage,
                onStreamedText: onStreamedText
            )
        }

        if handledAny {
            return
        }
    }

    private func withTimeout<T>(
        seconds: TimeInterval,
        operation: @escaping () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                let nanoseconds = UInt64(max(1, seconds) * 1_000_000_000)
                try await Task.sleep(nanoseconds: nanoseconds)
                throw ProjectChatService.ServiceError.networkFailed("请求超时，请重试。")
            }

            guard let first = try await group.next() else {
                group.cancelAll()
                throw ProjectChatService.ServiceError.networkFailed("请求失败，请重试。")
            }
            group.cancelAll()
            return first
        }
    }

    private func decodeSSEEvent(from payload: String) -> ([String: Any], String)? {
        guard
            let data = payload.data(using: .utf8),
            let eventObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let eventType = eventObject["type"] as? String
        else {
            return nil
        }
        return (eventObject, eventType)
    }

    private func handleSSEEventObject(
        _ eventObject: [String: Any],
        eventType: String,
        streamedText: inout String,
        completedResponseText: inout String?,
        usage: inout ResponsesUsage?,
        onStreamedText: (@MainActor (String) -> Void)?
    ) async throws {
        switch eventType {
        case "response.output_text.delta":
            guard let delta = eventObject["delta"] as? String, !delta.isEmpty else {
                return
            }
            streamedText.append(delta)
            if let onStreamedText {
                await onStreamedText(streamedText)
            }

        case "response.output_text.done":
            guard
                streamedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                let text = extractPlainText(from: eventObject["text"]),
                !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                return
            }
            completedResponseText = text
            if let onStreamedText {
                await onStreamedText(text)
            }

        case "response.output_item.done", "response.output_item.added":
            guard
                streamedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                let itemObject = eventObject["item"] as? [String: Any],
                let text = extractText(fromOutputItemObject: itemObject),
                !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                return
            }
            completedResponseText = text
            if let onStreamedText {
                await onStreamedText(text)
            }

        case "response.completed":
            guard let responseObject = eventObject["response"] as? [String: Any] else {
                return
            }

            if let extractedUsage = extractUsage(fromResponseObject: responseObject) {
                usage = extractedUsage
            }

            if let text = extractText(fromResponseObject: responseObject),
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                completedResponseText = text
                if streamedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let onStreamedText {
                    await onStreamedText(text)
                }
            }

            if let responseData = try? JSONSerialization.data(withJSONObject: responseObject),
               let decodedResponse = try? jsonDecoder.decode(ResponsesResponse.self, from: responseData) {
                if usage == nil, let decodedUsage = decodedResponse.usage {
                    usage = decodedUsage
                }
                if let text = extractOutputText(from: decodedResponse),
                   !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    if completedResponseText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
                        completedResponseText = text
                    }
                    if streamedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       let onStreamedText,
                       let finalText = completedResponseText {
                        await onStreamedText(finalText)
                    }
                }
            }

        case "error":
            let message = parseStreamingErrorMessage(from: eventObject) ?? "流式响应失败。"
            throw ProjectChatService.ServiceError.networkFailed("请求失败：\(message)")

        case "response.failed":
            let message = parseNestedErrorMessage(from: eventObject["response"]) ?? "响应失败。"
            throw ProjectChatService.ServiceError.networkFailed("请求失败：\(message)")

        case "response.incomplete":
            let message = parseIncompleteReason(from: eventObject["response"]) ?? "响应不完整。"
            throw ProjectChatService.ServiceError.networkFailed("请求失败：\(message)")

        default:
            return
        }
    }

    private func consumeStreamBytes(bytes: URLSession.AsyncBytes) async throws -> Data {
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
        }
        return data
    }

    private func shouldFallbackReasoningToHigh(
        currentEffort: ResponsesReasoning.Effort?,
        responseBodyData: Data,
        alreadyFallback: Bool
    ) -> Bool {
        let message = parseErrorMessage(from: responseBodyData) ?? ""
        return shouldFallbackReasoningToHigh(
            currentEffort: currentEffort,
            errorMessage: message,
            alreadyFallback: alreadyFallback
        )
    }

    private func shouldFallbackReasoningToHigh(
        currentEffort: ResponsesReasoning.Effort?,
        errorMessage: String,
        alreadyFallback: Bool
    ) -> Bool {
        guard !alreadyFallback else {
            return false
        }
        guard currentEffort == .xhigh else {
            return false
        }

        let message = errorMessage.lowercased()
        if message.contains("reasoning") && message.contains("effort") {
            return true
        }
        if message.contains("xhigh") && (message.contains("invalid") || message.contains("unsupported")) {
            return true
        }
        return false
    }

    private func shouldFallbackResponseFormat(
        textConfiguration: ResponsesTextConfiguration?,
        responseBodyData: Data,
        alreadyFallback: Bool
    ) -> Bool {
        let message = parseErrorMessage(from: responseBodyData) ?? ""
        return shouldFallbackResponseFormat(
            textConfiguration: textConfiguration,
            errorMessage: message,
            alreadyFallback: alreadyFallback
        )
    }

    private func shouldFallbackResponseFormat(
        textConfiguration: ResponsesTextConfiguration?,
        errorMessage: String,
        alreadyFallback: Bool
    ) -> Bool {
        guard !alreadyFallback else {
            return false
        }
        guard textConfiguration != nil else {
            return false
        }

        let message = errorMessage.lowercased()
        if message.contains("text.format") {
            return true
        }
        if message.contains("json_schema") {
            return true
        }
        if message.contains("unsupported") && message.contains("format") {
            return true
        }
        if message.contains("schema") && message.contains("invalid") {
            return true
        }
        return false
    }

    private func extractOutputText(from response: ResponsesResponse) -> String? {
        let segments = (response.output ?? []).compactMap { outputItem -> String? in
            guard outputItem.type == "message" else {
                return nil
            }
            let texts = (outputItem.content ?? []).compactMap { contentItem -> String? in
                if contentItem.type == "output_text" || contentItem.type == "text" {
                    return contentItem.text
                }
                return nil
            }
            let merged = texts.joined(separator: "\n")
            return merged.isEmpty ? nil : merged
        }
        return segments.joined(separator: "\n")
    }

    private func extractText(fromResponseObject responseObject: [String: Any]) -> String? {
        if let outputText = extractPlainText(from: responseObject["output_text"]),
           !outputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return outputText
        }

        guard let outputItems = responseObject["output"] as? [[String: Any]] else {
            return nil
        }

        let texts = outputItems.compactMap { extractText(fromOutputItemObject: $0) }
        let merged = texts.joined(separator: "\n")
        return merged.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : merged
    }

    private func extractUsage(fromResponseObject responseObject: [String: Any]) -> ResponsesUsage? {
        guard
            let usageObject = responseObject["usage"] as? [String: Any],
            let usageData = try? JSONSerialization.data(withJSONObject: usageObject),
            let usage = try? jsonDecoder.decode(ResponsesUsage.self, from: usageData)
        else {
            return nil
        }
        return usage
    }

    private func extractText(fromOutputItemObject outputItem: [String: Any]) -> String? {
        if let directText = extractPlainText(from: outputItem["text"]),
           !directText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return directText
        }

        guard let contentItems = outputItem["content"] as? [Any] else {
            return nil
        }

        let texts = contentItems.compactMap { contentObject -> String? in
            guard let dictionary = contentObject as? [String: Any] else {
                return nil
            }

            let contentType = (dictionary["type"] as? String)?.lowercased() ?? ""
            guard contentType == "output_text" || contentType == "text" || contentType == "input_text" else {
                return nil
            }
            return extractPlainText(from: dictionary["text"])
        }

        let merged = texts.joined(separator: "\n")
        return merged.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : merged
    }

    private func extractPlainText(from value: Any?) -> String? {
        if let text = value as? String {
            return text
        }
        if let textObject = value as? [String: Any],
           let valueText = textObject["value"] as? String {
            return valueText
        }
        return nil
    }

    private func parseErrorMessage(from data: Data) -> String? {
        guard !data.isEmpty else {
            return nil
        }

        if
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let error = json["error"] as? [String: Any],
            let message = error["message"] as? String,
            !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return message
        }

        if
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let message = json["message"] as? String,
            !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return message
        }

        if
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let detail = json["detail"] as? String,
            !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return detail
        }

        if let rawText = String(data: data, encoding: .utf8) {
            let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }

        return nil
    }

    private func parseStreamingErrorMessage(from eventObject: [String: Any]) -> String? {
        if
            let errorObject = eventObject["error"] as? [String: Any],
            let message = errorObject["message"] as? String,
            !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return message
        }
        if
            let message = eventObject["message"] as? String,
            !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return message
        }
        return nil
    }

    private func parseNestedErrorMessage(from responseObject: Any?) -> String? {
        guard let response = responseObject as? [String: Any] else {
            return nil
        }
        if
            let error = response["error"] as? [String: Any],
            let message = error["message"] as? String,
            !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return message
        }
        return nil
    }

    private func parseIncompleteReason(from responseObject: Any?) -> String? {
        guard let response = responseObject as? [String: Any] else {
            return nil
        }
        if
            let details = response["incomplete_details"] as? [String: Any],
            let reason = details["reason"] as? String,
            !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return reason
        }
        return nil
    }

    private func recordSSEEventPayload(dataLines: [String], into payloads: inout [String]) {
        guard !dataLines.isEmpty else {
            return
        }
        let payload = dataLines.joined(separator: "\n")
        if payload == "[DONE]" {
            return
        }
        payloads.append(payload)
    }

    private func debugLog(_ message: @autoclosure () -> String) {
#if DEBUG
        print(message())
#endif
    }

    private func truncatedDebugText(_ value: String) -> String {
        return value
//        guard value.count > configuration.maxDebugTextCharacters else {
//            return value
//        }
//        return String(value.prefix(configuration.maxDebugTextCharacters)) + "...(truncated)"
    }

    private func logSuccessfulResponseDebug(
        request: URLRequest,
        httpResponse: HTTPURLResponse,
        finalResponseText: String,
        usage: ResponsesUsage?,
        rawSSEEventPayloads: [String],
        requestLabel: String
    ) {
#if DEBUG
        print("========== [DoufuCodexChat Debug] HTTP 请求成功 ==========")
        print("Request Label: \(requestLabel)")
        print("URL: \(request.url?.absoluteString ?? "nil")")
        print("Status: \(httpResponse.statusCode)")
        print("Response Headers: \(httpResponse.allHeaderFields)")
        print("Request Body: <redacted>")
        print("Final Response Text: \(truncatedDebugText(finalResponseText))")
        if let usage {
            print("Usage: input=\(usage.inputTokens ?? 0), output=\(usage.outputTokens ?? 0), total=\(usage.totalTokens ?? 0)")
        } else {
            print("Usage: <none>")
        }
        print("SSE Event Count: \(rawSSEEventPayloads.count)")
        if rawSSEEventPayloads.isEmpty {
            print("SSE Events: <none>")
        } else {
            for (index, payload) in rawSSEEventPayloads.enumerated() {
                print("----- SSE[\(index)] -----")
                print(truncatedDebugText(payload))
            }
        }
        print("========== [DoufuCodexChat Debug] 结束 ==========")
#endif
    }

    private func logFailedResponseDebug(
        request: URLRequest,
        httpResponse: HTTPURLResponse,
        responseBodyData: Data,
        requestLabel: String
    ) {
#if DEBUG
        print("========== [DoufuCodexChat Debug] HTTP 请求失败 ==========")
        print("Request Label: \(requestLabel)")
        print("URL: \(request.url?.absoluteString ?? "nil")")
        print("Status: \(httpResponse.statusCode)")
        print("Response Headers: \(httpResponse.allHeaderFields)")
        print("Request Body: <redacted>")
        if let responseText = String(data: responseBodyData, encoding: .utf8) {
            print("Response Body: \(truncatedDebugText(responseText))")
        } else {
            print("Response Body (base64): \(responseBodyData.base64EncodedString())")
        }
        print("========== [DoufuCodexChat Debug] 结束 ==========")
#endif
    }

    private func logInvalidResponseDebug(
        request: URLRequest,
        httpResponse: HTTPURLResponse,
        streamedText: String,
        completedResponseText: String?,
        rawSSEEventPayloads: [String],
        requestLabel: String
    ) {
#if DEBUG
        print("========== [DoufuCodexChat Debug] invalidResponse ==========")
        print("Request Label: \(requestLabel)")
        print("URL: \(request.url?.absoluteString ?? "nil")")
        print("Status: \(httpResponse.statusCode)")
        print("Response Headers: \(httpResponse.allHeaderFields)")
        print("Request Body: <redacted>")

        let normalizedStreamed = streamedText.trimmingCharacters(in: .whitespacesAndNewlines)
        print("streamedText(empty? \(normalizedStreamed.isEmpty)): \(truncatedDebugText(streamedText))")
        print("completedResponseText: \(truncatedDebugText(completedResponseText ?? "<nil>"))")

        print("SSE Event Count: \(rawSSEEventPayloads.count)")
        if rawSSEEventPayloads.isEmpty {
            print("SSE Events: <none>")
        } else {
            for (index, payload) in rawSSEEventPayloads.enumerated() {
                print("----- SSE[\(index)] -----")
                print(truncatedDebugText(payload))
            }
        }
        print("========== [DoufuCodexChat Debug] 结束 ==========")
#endif
    }

    private func isChatGPTCodexBackend(url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        let path = url.path.lowercased()
        return host == "chatgpt.com" && path.contains("/backend-api/codex")
    }
}
