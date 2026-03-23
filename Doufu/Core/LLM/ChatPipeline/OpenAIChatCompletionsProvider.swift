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
            maxTokens: credential.profile.maxOutputTokens,
            reasoningEffort: sendReasoning ? reasoningEffortString(from: effort) : nil,
            thinking: chatCompletionsThinking(for: credential.profile, executionOptions: executionOptions),
            streamOptions: OpenAIChatCompletionsRequest.StreamOptions(includeUsage: true)
        )
        var fallbackState = FallbackState()

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

                if applyFallback(to: &requestBody, errorMessage: errorMessage, state: &fallbackState) {
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
            maxTokens: credential.profile.maxOutputTokens,
            reasoningEffort: sendReasoning ? reasoningEffortString(from: effort) : nil,
            thinking: chatCompletionsThinking(for: credential.profile, executionOptions: executionOptions),
            streamOptions: OpenAIChatCompletionsRequest.StreamOptions(includeUsage: true)
        )
        var fallbackState = FallbackState()

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

                if applyFallback(to: &requestBody, errorMessage: errorMessage, state: &fallbackState) {
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
                options: ChatCompletionsToolUseStreamOptions(parseReasoningContent: true),
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

    // MARK: - Thinking

    private func chatCompletionsThinking(
        for profile: ResolvedModelProfile,
        executionOptions: ProjectChatService.ModelExecutionOptions
    ) -> ChatCompletionsThinking? {
        guard profile.thinkingSupported else { return nil }
        return ChatCompletionsThinking(enabled: executionOptions.chatCompletionsThinkingEnabled)
    }

    // MARK: - Fallback

    private struct FallbackState {
        var didMaxCompletionTokens = false
        var didMaxTokens = false
        var didReasoningEffort = false
        var didThinking = false
        var didStreamOptions = false
    }

    /// Tries each fallback in order. Returns true if a parameter was removed (caller should retry).
    private func applyFallback(
        to requestBody: inout OpenAIChatCompletionsRequest,
        errorMessage: String,
        state: inout FallbackState
    ) -> Bool {
        let msg = errorMessage.lowercased()

        if !state.didMaxCompletionTokens, requestBody.maxCompletionTokens != nil,
           msg.contains("max_completion_tokens") || msg.contains("max_output_tokens") {
            state.didMaxCompletionTokens = true
            requestBody.maxCompletionTokens = nil
            return true
        }

        if !state.didMaxTokens, requestBody.maxTokens != nil,
           msg.contains("max_tokens") {
            state.didMaxTokens = true
            requestBody.maxTokens = nil
            return true
        }

        if !state.didReasoningEffort, requestBody.reasoningEffort != nil,
           msg.contains("reasoning_effort") {
            state.didReasoningEffort = true
            requestBody.reasoningEffort = nil
            return true
        }

        if !state.didThinking, requestBody.thinking != nil,
           msg.contains("thinking") {
            state.didThinking = true
            requestBody.thinking = nil
            return true
        }

        if !state.didStreamOptions, requestBody.streamOptions != nil,
           msg.contains("stream_options") {
            state.didStreamOptions = true
            requestBody.streamOptions = nil
            return true
        }

        return false
    }
}
