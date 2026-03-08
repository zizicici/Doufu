//
//  LLMStreamingClient.swift
//  Doufu
//
//  Created by Codex on 2026/03/05.
//

import Foundation

final class LLMStreamingClient {
    private let configuration: ProjectChatConfiguration
    private lazy var openAIProvider = OpenAIProvider(configuration: configuration)
    private lazy var anthropicProvider = AnthropicProvider(configuration: configuration)
    private lazy var geminiProvider = GeminiProvider(configuration: configuration)

    init(configuration: ProjectChatConfiguration) {
        self.configuration = configuration
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
        var lastError: Error?
        for attempt in 0...configuration.maxTransientRetries {
            if attempt > 0 {
                let delaySeconds = Double(1 << (attempt - 1)) // 1s, 2s
                try await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
                try Task.checkCancellation()
            }
            do {
                return try await provider(for: credential.providerKind).requestWithTools(
                    systemInstruction: systemInstruction,
                    conversationItems: conversationItems,
                    tools: tools,
                    credential: credential,
                    projectUsageIdentifier: projectUsageIdentifier,
                    executionOptions: executionOptions,
                    onStreamedText: onStreamedText,
                    onUsage: onUsage
                )
            } catch let error as ProjectChatService.ServiceError {
                guard case let .networkFailed(message) = error,
                      Self.isTransientError(message),
                      attempt < configuration.maxTransientRetries
                else { throw error }
                lastError = error
                LLMProviderHelpers.debugLog("[Doufu] Transient error (attempt \(attempt + 1)): \(message)")
            }
        }
        throw lastError ?? ProjectChatService.ServiceError.networkFailed(String(localized: "llm.error.request_failed"))
    }

    private static func isTransientError(_ message: String) -> Bool {
        let lowered = message.lowercased()

        // Match HTTP status codes as word boundaries to avoid false positives
        // (e.g. "500" in "File size is 15002 bytes")
        let statusCodePattern = #"\b(429|500|502|503)\b"#
        if let regex = try? NSRegularExpression(pattern: statusCodePattern),
           regex.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)) != nil {
            return true
        }

        let transientPhrases = ["rate limit", "too many requests",
                                "internal server error", "bad gateway",
                                "service unavailable", "overloaded"]
        return transientPhrases.contains { lowered.contains($0) }
    }

    private func provider(for kind: LLMProviderRecord.Kind) -> LLMProviderAdapter {
        switch kind {
        case .openAICompatible: return openAIProvider
        case .anthropic: return anthropicProvider
        case .googleGemini: return geminiProvider
        }
    }
}
