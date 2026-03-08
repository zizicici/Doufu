//
//  ProjectChatConfiguration.swift
//  Doufu
//
//  Created by Codex on 2026/03/05.
//

import Foundation

struct ProjectChatConfiguration {
    let defaultModel = LLMProviderRecord.Kind.openAICompatible.defaultModelID

    let maxFilesForCatalog = 300
    let maxBytesPerCatalogFile = 120_000
    let maxPreviewCharactersForCatalog = 220

    let maxFilesForContext = 20
    let maxBytesPerContextFile = 65_000
    let maxContextBytesTotal = 360_000
    let maxFilePathsFromSelection = 16

    let maxPlannedTasks = 5
    let maxFilesPerTaskContext = 6

    let maxHistoryTurns = 16
    let maxHistoryTurnsDirectlyIncluded = 8
    let maxHistorySummaryCharacters = 3_200

    let maxMemoryObjectiveCharacters = 180
    let maxMemoryConstraintItems = 8
    let maxMemoryChangedFiles = 24
    let maxMemoryTodoItems = 8
    let maxMemoryItemCharacters = 120

    let maxTaskTitleCharacters = 48
    let maxTaskGoalCharacters = 260

    let singlePassFileThreshold = 8
    let singlePassContextFileLimit = 8

    let lowReasoningTimeoutSeconds: TimeInterval = 240
    let mediumReasoningTimeoutSeconds: TimeInterval = 320
    let highReasoningTimeoutSeconds: TimeInterval = 400
    let xhighReasoningTimeoutSeconds: TimeInterval = 600
    let streamCompletionGraceSeconds: TimeInterval = 10

    let maxThreadMemoryCharactersInPrompt = 16_000
    let maxDebugTextCharacters = 1_600

    let maxContextRefinementRounds = 1
    let maxFilesPerRefinementRequest = 5
    let maxPatchRepairAttempts = 1

    let maxOutputTokens = 8192

    let webFetchMaxBytes = 65_000
    let webFetchTimeoutSeconds: TimeInterval = 15
    let webSearchMaxResults = 10

    let maxAgentIterations = 25
    let maxToolCallsPerIteration = 8

    static let `default` = ProjectChatConfiguration()
}
