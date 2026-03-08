//
//  LLMStreamingClient.swift
//  Doufu
//
//  Created by Codex on 2026/03/05.
//

import Foundation

final class LLMStreamingClient {
    private let configuration: ProjectChatConfiguration
    private let openAIProvider: OpenAIProvider
    private let anthropicProvider: AnthropicProvider
    private let geminiProvider: GeminiProvider

    init(configuration: ProjectChatConfiguration) {
        self.configuration = configuration
        self.openAIProvider = OpenAIProvider(configuration: configuration)
        self.anthropicProvider = AnthropicProvider(configuration: configuration)
        self.geminiProvider = GeminiProvider(configuration: configuration)
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
        try await provider(for: credential.providerKind).requestStreaming(
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
        try await provider(for: credential.providerKind).requestWithTools(
            systemInstruction: systemInstruction,
            conversationItems: conversationItems,
            tools: tools,
            credential: credential,
            projectUsageIdentifier: projectUsageIdentifier,
            executionOptions: executionOptions,
            onStreamedText: onStreamedText,
            onUsage: onUsage
        )
    }

    private func provider(for kind: LLMProviderRecord.Kind) -> LLMProviderAdapter {
        switch kind {
        case .openAICompatible: return openAIProvider
        case .anthropic: return anthropicProvider
        case .googleGemini: return geminiProvider
        }
    }
}
