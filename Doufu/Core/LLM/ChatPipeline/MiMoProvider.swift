//
//  MiMoProvider.swift
//  Doufu
//
//  Created by Claude on 2026/03/21.
//

import Foundation

final class MiMoProvider: ChatCompletionsBaseProvider, LLMProviderAdapter {

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
        let messages = buildNonToolMessages(developerInstruction: developerInstruction, inputItems: inputItems)

        let requestBody = MiMoChatRequest(
            model: model,
            messages: messages,
            tools: nil,
            stream: true,
            maxCompletionTokens: credential.profile.maxOutputTokens,
            thinking: mimoThinking(for: credential.profile, executionOptions: executionOptions),
            responseFormat: mimoResponseFormat(from: responseFormat)
        )

        let timeoutSeconds = LLMProviderHelpers.timeoutSeconds(for: initialReasoningEffort, configuration: configuration)
        var request = buildURLRequest(credential: credential, path: "chat/completions", timeoutSeconds: timeoutSeconds)
        request.httpBody = try jsonEncoder.encode(requestBody)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProjectChatService.ServiceError.networkFailed(String(localized: "llm.error.invalid_response"))
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            try await throwHTTPError(request: request, httpResponse: httpResponse, bytes: bytes, requestLabel: requestLabel)
        }

        return try await consumeStreamingResponse(
            bytes: bytes, timeoutSeconds: timeoutSeconds,
            options: ChatCompletionsStreamingOptions(checkContentFilter: true),
            onStreamedText: onStreamedText, onUsage: onUsage
        )
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
        let timeoutSeconds = LLMProviderHelpers.timeoutSeconds(for: executionOptions.reasoningEffort, configuration: configuration)

        let messages = buildToolUseMessages(systemInstruction: systemInstruction, from: conversationItems)
        let toolDefinitions = buildToolDefinitions(from: tools)

        let requestBody = MiMoChatRequest(
            model: model,
            messages: messages,
            tools: toolDefinitions,
            stream: true,
            maxCompletionTokens: credential.profile.maxOutputTokens,
            thinking: mimoThinking(for: credential.profile, executionOptions: executionOptions),
            responseFormat: nil
        )

        var request = buildURLRequest(credential: credential, path: "chat/completions", timeoutSeconds: timeoutSeconds)
        request.httpBody = try jsonEncoder.encode(requestBody)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProjectChatService.ServiceError.networkFailed(String(localized: "llm.error.invalid_response"))
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            try await throwHTTPError(request: request, httpResponse: httpResponse, bytes: bytes, requestLabel: "MiMo ToolUse")
        }

        return try await consumeToolUseStream(
            bytes: bytes, timeoutSeconds: timeoutSeconds,
            options: ChatCompletionsToolUseStreamOptions(parseReasoningContent: true, checkContentFilter: true),
            onStreamedText: onStreamedText, onUsage: onUsage
        )
    }

    // MARK: - MiMo-Specific Helpers

    private func mimoThinking(
        for profile: ResolvedModelProfile,
        executionOptions: ProjectChatService.ModelExecutionOptions
    ) -> ChatCompletionsThinking? {
        guard profile.thinkingSupported else { return nil }
        return ChatCompletionsThinking(enabled: executionOptions.mimoThinkingEnabled)
    }

    private func mimoResponseFormat(from format: ResponsesTextFormat?) -> MiMoResponseFormat? {
        guard format != nil else { return nil }
        return MiMoResponseFormat(type: "json_object")
    }
}
