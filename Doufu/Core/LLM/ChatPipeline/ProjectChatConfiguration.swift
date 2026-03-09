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

    /// Conservative characters-per-token ratio.  Lower values trigger compaction
    /// sooner, which is safer for CJK text and code (where the real ratio is
    /// closer to 1.5–2.0 chars/token rather than 3–4 for English prose).
    let charsPerTokenEstimate = 2.5

    static let `default` = ProjectChatConfiguration()

    // MARK: - Thinking Budgets

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
        maxOutputTokens: Int,
        effort: ProjectChatService.ReasoningEffort
    ) -> Int {
        let fraction: Double
        switch effort {
        case .low:    fraction = 0.25
        case .medium: fraction = 0.50
        case .high:   fraction = 0.66
        case .xhigh:  fraction = 0.80
        }
        // Must be < maxOutput (API constraint) and leave room for visible output.
        let raw = Int(Double(maxOutputTokens) * fraction)
        return max(1024, min(raw, maxOutputTokens - 4096))
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

    // MARK: - Compaction

    /// Estimate the usable context window size in characters from the
    /// resolved profile's token budget.
    func maxConversationCharacters(contextWindowTokens: Int) -> Int {
        Int(Double(contextWindowTokens) * charsPerTokenEstimate * compactionTargetRatio)
    }
}
