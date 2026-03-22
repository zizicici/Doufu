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
        var messages: [MiMoMessage] = []
        if !developerInstruction.isEmpty {
            messages.append(.system(content: developerInstruction))
        }
        let conversationMessages = LLMProviderHelpers.normalizedConversationMessages(
            from: inputItems, assistantRole: "assistant", userRole: "user"
        )
        for msg in conversationMessages {
            if msg.role == "assistant" {
                messages.append(.assistant(content: msg.text, toolCalls: nil, reasoningContent: nil))
            } else {
                messages.append(.user(content: msg.text))
            }
        }

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

        let messages = buildMiMoToolUseMessages(systemInstruction: systemInstruction, from: conversationItems)
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

    // MARK: - MiMo-Specific Message Builder

    private func buildMiMoToolUseMessages(
        systemInstruction: String,
        from items: [AgentConversationItem]
    ) -> [MiMoMessage] {
        var messages: [MiMoMessage] = []
        if !systemInstruction.isEmpty {
            messages.append(.system(content: systemInstruction))
        }
        for item in items {
            switch item {
            case let .userMessage(text):
                messages.append(.user(content: text))
            case let .assistantMessage(msg):
                let calls = msg.toolCalls.map { tc in
                    OpenRouterToolCall(id: tc.id, name: tc.name, arguments: tc.argumentsJSON)
                }
                messages.append(.assistant(
                    content: msg.text,
                    toolCalls: calls.isEmpty ? nil : calls,
                    reasoningContent: msg.thinkingContent
                ))
            case let .toolResult(callID, _, content, _):
                messages.append(.tool(toolCallID: callID, content: content))
            }
        }
        return messages
    }

    // MARK: - MiMo-Specific Helpers

    private func mimoThinking(
        for profile: ResolvedModelProfile,
        executionOptions: ProjectChatService.ModelExecutionOptions
    ) -> MiMoThinking? {
        guard profile.thinkingSupported else { return nil }
        return MiMoThinking(enabled: executionOptions.mimoThinkingEnabled)
    }

    private func mimoResponseFormat(from format: ResponsesTextFormat?) -> MiMoResponseFormat? {
        guard format != nil else { return nil }
        return MiMoResponseFormat(type: "json_object")
    }
}
