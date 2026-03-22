//
//  OpenRouterProvider.swift
//  Doufu
//
//  Created by Claude on 2026/03/13.
//

import Foundation

final class OpenRouterProvider: ChatCompletionsBaseProvider, LLMProviderAdapter {

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
        let sendReasoning = !credential.profile.reasoningEfforts.isEmpty
        let effort = executionOptions.reasoningEffort
        let messages = buildNonToolMessages(developerInstruction: developerInstruction, inputItems: inputItems)

        let requestBody = OpenRouterChatRequest(
            model: model,
            messages: messages,
            tools: nil,
            stream: true,
            reasoning: sendReasoning ? OpenRouterReasoning(from: effort) : nil
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
        let effort = executionOptions.reasoningEffort
        let timeoutSeconds = LLMProviderHelpers.timeoutSeconds(for: effort, configuration: configuration)
        let sendReasoning = !credential.profile.reasoningEfforts.isEmpty

        let messages = buildToolUseMessages(systemInstruction: systemInstruction, from: conversationItems)
        let toolDefinitions = buildToolDefinitions(from: tools)

        let requestBody = OpenRouterChatRequest(
            model: model,
            messages: messages,
            tools: toolDefinitions,
            stream: true,
            reasoning: sendReasoning ? OpenRouterReasoning(from: effort) : nil
        )

        var request = buildURLRequest(credential: credential, path: "chat/completions", timeoutSeconds: timeoutSeconds)
        request.httpBody = try jsonEncoder.encode(requestBody)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProjectChatService.ServiceError.networkFailed(String(localized: "llm.error.invalid_response"))
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            try await throwHTTPError(request: request, httpResponse: httpResponse, bytes: bytes, requestLabel: "OpenRouter ToolUse")
        }

        return try await consumeToolUseStream(
            bytes: bytes, timeoutSeconds: timeoutSeconds,
            onStreamedText: onStreamedText, onUsage: onUsage
        )
    }
}
