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

    // MARK: - Model-Aware Limits

    /// Maximum output tokens.  If the model record carries a user override,
    /// that value wins; otherwise we fall back to the built-in lookup table.
    func maxOutputTokens(
        providerKind: LLMProviderRecord.Kind,
        modelID: String,
        capabilities: LLMProviderModelCapabilities? = nil
    ) -> Int {
        if let override = capabilities?.maxOutputTokensOverride, override > 0 {
            return override
        }
        return builtInMaxOutputTokens(providerKind: providerKind, modelID: modelID)
    }

    /// Built-in lookup table for max output tokens.
    /// Sources:
    ///  - OpenAI:    https://developers.openai.com/api/docs/models/
    ///  - Anthropic: https://docs.anthropic.com/en/docs/about-claude/models
    ///  - Gemini:    https://ai.google.dev/gemini-api/docs/models/
    private func builtInMaxOutputTokens(
        providerKind: LLMProviderRecord.Kind,
        modelID: String
    ) -> Int {
        let id = modelID.lowercased()

        switch providerKind {
        case .openAICompatible:
            // o3 / o4-mini: 200K context, 100K output
            if id.contains("o3") || id.contains("o4")       { return 100_000 }
            // gpt-5.4 / gpt-5.4-pro: 1.05M context, 128K output
            // gpt-5.3-codex:          400K context, 128K output
            // gpt-5-mini:             400K context, 128K output
            if id.contains("gpt-5")                          { return 128_000 }
            // gpt-4.1 / gpt-4.1-mini / gpt-4.1-nano: ~1M context, 32K output
            if id.contains("gpt-4.1") || id.contains("4-1") { return 32_768 }
            // gpt-4o: 128K context, 16K output
            if id.contains("gpt-4o")                         { return 16_384 }
            return 16_384

        case .anthropic:
            // claude-opus-4-6:   200K context, 128K output
            // claude-opus-4-5:   200K context,  64K output
            // claude-opus-4-1/0: 200K context,  32K output
            if id.contains("opus") {
                if id.contains("4-6")                        { return 128_000 }
                if id.contains("4-5")                        { return 64_000 }
                return 32_000
            }
            // claude-sonnet-*:   200K context, 64K output
            if id.contains("sonnet")                         { return 64_000 }
            // claude-haiku-4-5:  200K context, 64K output
            // claude-3-haiku:    200K context,  4K output
            if id.contains("haiku") {
                if id.contains("4-5") || id.contains("4.5") { return 64_000 }
                return 4_096
            }
            return 64_000

        case .googleGemini:
            // gemini-2.5-pro/flash: ~1M context, 65K output
            if id.contains("2.5-pro")   { return 65_536 }
            if id.contains("2.5-flash") { return 65_536 }
            // gemini-2.0-flash:     ~1M context,  8K output
            if id.contains("2.0-flash") { return 8_192 }
            return 16_384
        }
    }

    /// Thinking budget for Anthropic extended thinking, derived from the
    /// model's max output tokens and the requested effort level.
    ///
    /// For **non-tool-use** requests, `budget_tokens` must be < `max_tokens`
    /// (Anthropic constraint), so the budget is a fraction of `maxOutputTokens`.
    ///
    /// For **tool-use** (interleaved thinking), Anthropic allows `budget_tokens`
    /// to exceed `max_tokens` — the limit becomes the full context window (200K).
    /// Use `anthropicThinkingBudgetForToolUse` for that path.
    ///
    ///  - low:    25 % of max output
    ///  - medium: 50 %
    ///  - high:   66 %
    ///  - xhigh:  80 %
    func anthropicThinkingBudget(
        modelID: String,
        effort: ProjectChatService.ReasoningEffort
    ) -> Int {
        let maxOutput = maxOutputTokens(providerKind: .anthropic, modelID: modelID)
        let fraction: Double
        switch effort {
        case .low:    fraction = 0.25
        case .medium: fraction = 0.50
        case .high:   fraction = 0.66
        case .xhigh:  fraction = 0.80
        }
        // Must be < maxOutput (API constraint) and leave room for visible output.
        let raw = Int(Double(maxOutput) * fraction)
        return max(1024, min(raw, maxOutput - 4096))
    }

    /// Thinking budget for tool-use requests (interleaved thinking).
    /// Anthropic allows budget_tokens to exceed max_tokens in this mode;
    /// the effective ceiling is the context window (200K tokens).
    func anthropicThinkingBudgetForToolUse(
        effort: ProjectChatService.ReasoningEffort
    ) -> Int {
        switch effort {
        case .low:    return 10_000
        case .medium: return 32_000
        case .high:   return 64_000
        case .xhigh:  return 128_000
        }
    }

    /// Thinking budget for Gemini thinking models.
    func geminiThinkingBudget(effort: ProjectChatService.ReasoningEffort) -> Int {
        switch effort {
        case .low:    return 2_048
        case .medium: return 8_192
        case .high:   return 16_384
        case .xhigh:  return 32_768
        }
    }

    /// Estimate the context window size in characters for a given provider/model.
    /// Uses `chars ≈ tokens × 3.5` as a conservative approximation.
    func maxConversationCharacters(
        providerKind: LLMProviderRecord.Kind,
        modelID: String,
        capabilities: LLMProviderModelCapabilities? = nil
    ) -> Int {
        let tokens: Int
        if let override = capabilities?.contextWindowTokensOverride, override > 0 {
            tokens = override
        } else {
            tokens = contextWindowTokens(providerKind: providerKind, modelID: modelID)
        }
        return Int(Double(tokens) * 3.5 * compactionTargetRatio)
    }

    /// Return the known context window size in tokens for well-known models.
    /// Falls back to a conservative default per provider.
    private func contextWindowTokens(
        providerKind: LLMProviderRecord.Kind,
        modelID: String
    ) -> Int {
        let id = modelID.lowercased()

        switch providerKind {
        case .openAICompatible:
            // gpt-5.4 / gpt-5.4-pro: 1,050,000
            if id.contains("5.4") || id.contains("5-4")      { return 1_050_000 }
            // gpt-5.3-codex / gpt-5-mini: 400,000
            if id.contains("gpt-5")                           { return 400_000 }
            // gpt-4.1 family: ~1,048,000
            if id.contains("gpt-4.1") || id.contains("4-1")  { return 1_047_576 }
            // o3 / o4-mini: 200,000
            if id.contains("o3") || id.contains("o4")         { return 200_000 }
            // gpt-4o / gpt-4-turbo: 128,000
            if id.contains("gpt-4")                           { return 128_000 }
            return 128_000

        case .anthropic:
            return 200_000

        case .googleGemini:
            // gemini-2.5/2.0/1.5 all have ~1M context
            if id.contains("2.5") || id.contains("2.0")  { return 1_048_576 }
            if id.contains("1.5")                         { return 2_000_000 }
            return 1_048_576
        }
    }
}
