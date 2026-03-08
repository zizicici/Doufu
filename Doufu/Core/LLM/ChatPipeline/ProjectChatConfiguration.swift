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

    static let `default` = ProjectChatConfiguration()
}
