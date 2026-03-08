//
//  ProjectChatConfiguration.swift
//  Doufu
//
//  Created by Codex on 2026/03/05.
//

import Foundation

struct ProjectChatConfiguration {
    let defaultModel = LLMProviderRecord.Kind.openAICompatible.defaultModelID

    let maxBytesPerCatalogFile = 120_000
    let maxBytesPerContextFile = 65_000

    let maxHistoryTurns = 16
    let maxHistoryTurnsDirectlyIncluded = 8
    let maxHistorySummaryCharacters = 3_200

    let maxMemoryObjectiveCharacters = 180
    let maxMemoryConstraintItems = 8
    let maxMemoryChangedFiles = 24
    let maxMemoryTodoItems = 8
    let maxMemoryItemCharacters = 120

    let lowReasoningTimeoutSeconds: TimeInterval = 240
    let mediumReasoningTimeoutSeconds: TimeInterval = 320
    let highReasoningTimeoutSeconds: TimeInterval = 400
    let xhighReasoningTimeoutSeconds: TimeInterval = 600
    let streamCompletionGraceSeconds: TimeInterval = 10

    let maxThreadMemoryCharactersInPrompt = 16_000

    let maxOutputTokens = 16_384

    let webFetchMaxBytes = 65_000
    let webFetchTimeoutSeconds: TimeInterval = 15
    let webSearchMaxResults = 10

    let maxAgentIterations = 25
    let maxToolCallsPerIteration = 8

    /// Maximum tool result size in characters to prevent conversation bloat.
    let maxToolResultCharacters = 32_000

    /// Maximum retries for transient network errors (429, 500, 502, 503).
    let maxTransientRetries = 2

    /// Minimum number of recent conversation items to preserve during compaction.
    /// These items are never compacted or dropped.
    let compactionProtectedTailItems = 6

    /// Fraction of the model's context window to target during compaction (leave
    /// headroom for the system prompt and the next response).
    let compactionTargetRatio = 0.70

    static let `default` = ProjectChatConfiguration()

    // MARK: - Model-Aware Context Window

    /// Estimate the context window size in characters for a given provider/model.
    /// Uses `chars ≈ tokens × 3.5` as a conservative approximation.
    func maxConversationCharacters(
        providerKind: LLMProviderRecord.Kind,
        modelID: String
    ) -> Int {
        let tokens = contextWindowTokens(providerKind: providerKind, modelID: modelID)
        return Int(Double(tokens) * 3.5 * compactionTargetRatio)
    }

    /// Return the known context window size in tokens for well-known models.
    /// Falls back to a conservative default per provider.
    private func contextWindowTokens(
        providerKind: LLMProviderRecord.Kind,
        modelID: String
    ) -> Int {
        let id = modelID.lowercased()

        // --- OpenAI-compatible ---
        if providerKind == .openAICompatible {
            if id.contains("gpt-5") && id.contains("pro") { return 256_000 }
            if id.contains("gpt-5")                        { return 128_000 }
            if id.contains("gpt-4o")                       { return 128_000 }
            if id.contains("gpt-4") && id.contains("turbo") { return 128_000 }
            if id.contains("o3") || id.contains("o4")      { return 200_000 }
            if id.contains("gpt-4")                        { return 128_000 }
            return 128_000  // safe default for OpenAI-like providers
        }

        // --- Anthropic ---
        if providerKind == .anthropic {
            if id.contains("opus")                         { return 200_000 }
            if id.contains("sonnet")                       { return 200_000 }
            if id.contains("haiku")                        { return 200_000 }
            return 200_000
        }

        // --- Google Gemini ---
        if providerKind == .googleGemini {
            if id.contains("2.5-pro")                      { return 1_000_000 }
            if id.contains("2.5-flash")                    { return 1_000_000 }
            if id.contains("2.0-flash")                    { return 1_000_000 }
            if id.contains("1.5-pro")                      { return 2_000_000 }
            return 1_000_000
        }

        return 128_000  // universal fallback
    }
}
