//
//  OpenAIChatCompletionsProvider.swift
//  Doufu
//

import Foundation

final class OpenAIChatCompletionsProvider: ChatCompletionsBaseProvider, LLMProviderAdapter {

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
        let messages = buildNonToolMessages(developerInstruction: developerInstruction, inputItems: inputItems)

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

            return try await consumeStreamingResponse(
                bytes: bytes, timeoutSeconds: timeoutSeconds,
                onStreamedText: onStreamedText, onUsage: onUsage
            )
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
        let toolDefinitions = buildToolDefinitions(from: tools)

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
