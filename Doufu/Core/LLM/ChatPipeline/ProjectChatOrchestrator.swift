//
//  ProjectChatOrchestrator.swift
//  Doufu
//
//  Created by Codex on 2026/03/05.
//

import Foundation

/// Partial state accumulated by the agent loop before it was interrupted.
/// Attached to errors so that downstream handlers can still process
/// file changes that occurred before the interruption.
struct PartialAgentResult {
    let changedPaths: [String]
    let accumulatedText: String
    let toolActivityLog: [String]
}

/// Wrapper error that carries partial agent state alongside the original error.
struct AgentInterruptedError: Error {
    let underlyingError: Error
    let partialResult: PartialAgentResult
}

final class ProjectChatOrchestrator {
    private actor UsageAccumulator {
        private(set) var inputTokens: Int64 = 0
        private(set) var outputTokens: Int64 = 0
        /// Most recent input token count from a single API call — used for
        /// context-window-aware compaction decisions.
        private(set) var lastSingleCallInputTokens: Int?

        func record(inputTokens: Int?, outputTokens: Int?) {
            let normalizedInput = max(0, inputTokens ?? 0)
            let normalizedOutput = max(0, outputTokens ?? 0)
            self.inputTokens += Int64(normalizedInput)
            self.outputTokens += Int64(normalizedOutput)
            if normalizedInput > 0 {
                lastSingleCallInputTokens = normalizedInput
            }
        }

        var totals: (inputTokens: Int64, outputTokens: Int64)? {
            guard inputTokens > 0 || outputTokens > 0 else {
                return nil
            }
            return (inputTokens, outputTokens)
        }
    }

    private let configuration: ProjectChatConfiguration
    private let memoryManager: SessionMemoryManager
    private let promptBuilder: PromptBuilder
    private let streamingClient: LLMStreamingClient
    private let tokenUsageStore = LLMTokenUsageStore.shared
    private let gitService = ProjectGitService.shared

    init(
        configuration: ProjectChatConfiguration,
        memoryManager: SessionMemoryManager? = nil,
        promptBuilder: PromptBuilder? = nil,
        streamingClient: LLMStreamingClient? = nil
    ) {
        self.configuration = configuration
        self.memoryManager = memoryManager ?? SessionMemoryManager(configuration: configuration)
        self.promptBuilder = promptBuilder ?? PromptBuilder(configuration: configuration)
        self.streamingClient = streamingClient ?? LLMStreamingClient(configuration: configuration)
    }

    /// Mutable state accumulated across agent loop iterations.
    private struct AgentLoopState {
        var conversation: [AgentConversationItem]
        var allChangedPaths: [String] = []
        var allToolMetadata: [AgentToolProvider.ToolResultMetadata] = []
        var accumulatedText = ""
        var totalToolCalls = 0
        var toolActivityLog: [String] = []
        var toolActivityEntries: [ToolActivityEntry] = []
    }

    func sendAndApply(
        userMessage: String,
        history: [ProjectChatService.ChatTurn],
        sessionContext: ChatSessionContext,
        credential: ProjectChatService.ProviderCredential,
        memory: SessionMemory? = nil,
        executionOptions: ProjectChatService.ModelExecutionOptions,
        confirmationHandler: ToolConfirmationHandler? = nil,
        permissionMode: ToolPermissionMode = .standard,
        validationServerBaseURL: URL? = nil,
        validationBridge: DoufuBridge? = nil,
        onStreamedText: (@MainActor (String) -> Void)? = nil,
        onProgress: (@MainActor (ToolProgressEvent) -> Void)? = nil,
        onToolStarted: (@MainActor (String) -> Void)? = nil,
        onToolCompleted: (@MainActor (ToolActivityEntry) -> Void)? = nil
    ) async throws -> ProjectChatService.ResultPayload {
        let projectIdentifier = sessionContext.projectID
        let workspaceURL = sessionContext.workspaceURL
        let trimmedMessage = userMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMessage.isEmpty else {
            throw ProjectChatService.ServiceError.invalidResponse
        }

        let normalizedHistory = memoryManager.normalizedHistoryTurns(history, excludingLatestUserMessage: trimmedMessage)
        let requestMemory = memoryManager.buildRequestMemory(base: memory, latestUserMessage: trimmedMessage)
        let usageAccumulator = UsageAccumulator()
        let toolProvider = AgentToolProvider(workspaceURL: workspaceURL, configuration: configuration)
        toolProvider.confirmationHandler = confirmationHandler
        toolProvider.permissionMode = permissionMode
        toolProvider.codeValidator = CodeValidator()
        toolProvider.validationServerBaseURL = validationServerBaseURL
        toolProvider.validationBridge = validationBridge

        var state = AgentLoopState(conversation: [])

        do {
        autoSaveBeforeAgentLoop(workspaceURL: workspaceURL)

        let systemPrompt = buildSystemPrompt(workspaceURL: workspaceURL)
        let conversation = buildInitialConversation(
            normalizedHistory: normalizedHistory,
            trimmedMessage: trimmedMessage,
            requestMemory: requestMemory
        )

        state = AgentLoopState(conversation: conversation)

        if let onProgress {
            onProgress(.text(String(localized: "orchestrator.thinking")))
        }

        let budgetWarningThreshold = Int(Double(configuration.maxAgentIterations) * 0.8)

        for iteration in 0 ..< configuration.maxAgentIterations {
            try Task.checkCancellation()

            injectBudgetWarningIfNeeded(
                &state.conversation,
                iteration: iteration,
                threshold: budgetWarningThreshold
            )

            let streamCallback: (@MainActor (String) -> Void)? = onStreamedText.map { callback in
                { @MainActor partialText in
                    let trimmed = partialText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        callback(trimmed)
                    }
                }
            }

            let lastInputTokens = await usageAccumulator.lastSingleCallInputTokens
            compactConversationIfNeeded(&state.conversation, credential: credential, lastInputTokens: lastInputTokens)

            let response = try await streamingClient.requestWithTools(
                systemInstruction: systemPrompt,
                conversationItems: state.conversation,
                tools: toolProvider.toolDefinitions(),
                credential: credential,
                projectUsageIdentifier: projectIdentifier,
                executionOptions: executionOptions,
                onStreamedText: streamCallback,
                onUsage: nil
            )
            await usageAccumulator.record(
                inputTokens: response.usage?.inputTokens,
                outputTokens: response.usage?.outputTokens
            )

            let responseText = response.textContent.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)

            if let thinking = response.thinkingContent, !thinking.isEmpty, let onProgress {
                onProgress(.thinking(content: thinking))
            }

            // No tool calls — final or truncated response
            if response.toolCalls.isEmpty {
                if !responseText.isEmpty {
                    state.accumulatedText += (state.accumulatedText.isEmpty ? "" : "\n\n") + responseText
                }
                if let onStreamedText {
                    onStreamedText(responseText)
                }

                // Auto-continue on max_tokens truncation
                if response.stopReason == .maxTokens {
                    state.conversation.append(.assistantMessage(text: responseText, toolCalls: []))
                    state.conversation.append(.userMessage("Please continue from where you left off."))
                    LLMProviderHelpers.debugLog("[Doufu Agent] response truncated (max_tokens), requesting continuation")
                    continue
                }

                return try await buildFinalResult(
                    accumulatedText: state.accumulatedText,
                    allChangedPaths: state.allChangedPaths,
                    allToolMetadata: state.allToolMetadata,
                    toolActivityLog: state.toolActivityLog,
                    toolActivityEntries: state.toolActivityEntries,
                    requestMemory: requestMemory,
                    trimmedMessage: trimmedMessage,
                    workspaceURL: workspaceURL,
                    projectIdentifier: projectIdentifier,
                    usageAccumulator: usageAccumulator,
                    credential: credential,
                    onStreamedText: onStreamedText
                )
            }

            // Has tool calls — accumulate text, then execute
            if !responseText.isEmpty {
                state.accumulatedText += (state.accumulatedText.isEmpty ? "" : "\n\n") + responseText
                if let onStreamedText {
                    onStreamedText(responseText)
                }
            }

            state.conversation.append(.assistantMessage(text: responseText, toolCalls: response.toolCalls))

            try await executeToolCalls(
                response.toolCalls,
                state: &state,
                toolProvider: toolProvider,
                onProgress: onProgress,
                onToolStarted: onToolStarted,
                onToolCompleted: onToolCompleted
            )

            LLMProviderHelpers.debugLog("[Doufu Agent] iteration \(iteration + 1): \(response.toolCalls.count) tool calls executed, \(state.allChangedPaths.count) files changed total")
        }

        // Max iterations reached
        let rawMaxMessage = state.accumulatedText.isEmpty
            ? String(localized: "orchestrator.max_iterations_reached")
            : state.accumulatedText + "\n\n" + String(localized: "orchestrator.max_iterations_suffix")

        return try await buildFinalResult(
            accumulatedText: rawMaxMessage,
            allChangedPaths: state.allChangedPaths,
            allToolMetadata: state.allToolMetadata,
            toolActivityLog: state.toolActivityLog,
            toolActivityEntries: state.toolActivityEntries,
            requestMemory: requestMemory,
            trimmedMessage: trimmedMessage,
            workspaceURL: workspaceURL,
            projectIdentifier: projectIdentifier,
            usageAccumulator: usageAccumulator,
            credential: credential,
            onStreamedText: nil
        )

        } catch {
            let _ = await persistedUsage(
                from: usageAccumulator,
                credential: credential,
                projectIdentifier: projectIdentifier
            )

            // If any files were changed before the error/cancellation,
            // create a checkpoint and wrap the error so downstream
            // handlers can still reflect the changes in the UI.
            if !state.allChangedPaths.isEmpty {
                createCheckpointAfterAgentLoop(workspaceURL: workspaceURL, userMessage: trimmedMessage)
                let partial = PartialAgentResult(
                    changedPaths: state.allChangedPaths,
                    accumulatedText: state.accumulatedText,
                    toolActivityLog: state.toolActivityLog
                )
                throw AgentInterruptedError(underlyingError: error, partialResult: partial)
            }

            throw error
        }
    }

    // MARK: - Pipeline Phases

    private func buildSystemPrompt(workspaceURL: URL) -> String {
        let agentsMarkdown = readAgentsMarkdown(workspaceURL: workspaceURL)
        let doufuMarkdown = readDoufuMarkdown(workspaceURL: workspaceURL)
        return promptBuilder.agentSystemPrompt(
            agentsMarkdown: agentsMarkdown,
            doufuMarkdown: doufuMarkdown
        )
    }

    private func buildInitialConversation(
        normalizedHistory: [ProjectChatService.ChatTurn],
        trimmedMessage: String,
        requestMemory: SessionMemory
    ) -> [AgentConversationItem] {
        var conversation: [AgentConversationItem] = []

        let historyItems = memoryManager.buildHistoryInputMessages(from: normalizedHistory)
        for item in historyItems {
            let role = item.role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let text = item.content.map(\.text).joined(separator: "\n")
            if role == "user" {
                conversation.append(.userMessage(text))
            } else if role == "assistant" {
                conversation.append(.assistantMessage(text: text, toolCalls: []))
            }
        }

        let memoryJSON = memoryManager.encodeMemoryToJSONString(requestMemory)
        let userPrompt = promptBuilder.agentUserPrompt(
            userMessage: trimmedMessage,
            memoryJSON: memoryJSON
        )
        conversation.append(.userMessage(userPrompt))

        return conversation
    }

    private func injectBudgetWarningIfNeeded(
        _ conversation: inout [AgentConversationItem],
        iteration: Int,
        threshold: Int
    ) {
        guard iteration == threshold else { return }
        let remaining = configuration.maxAgentIterations - iteration
        let warning = "[System: You have \(remaining) tool-use iterations remaining. Please complete your current task and provide a summary. Do not start new tasks.]"
        if case let .userMessage(existingText) = conversation.last {
            conversation[conversation.count - 1] = .userMessage(existingText + "\n\n" + warning)
        } else {
            conversation.append(.userMessage(warning))
        }
    }

    private func executeToolCalls(
        _ toolCalls: [AgentToolCall],
        state: inout AgentLoopState,
        toolProvider: AgentToolProvider,
        onProgress: (@MainActor (ToolProgressEvent) -> Void)?,
        onToolStarted: (@MainActor (String) -> Void)? = nil,
        onToolCompleted: (@MainActor (ToolActivityEntry) -> Void)? = nil
    ) async throws {
        let readOnlyTools: Set<String> = ["read_file", "list_directory", "search_files", "grep_files", "glob_files", "diff_file", "changed_files"]
        let maxBudget = configuration.maxAgentIterations * configuration.maxToolCallsPerIteration

        // Process tool calls in order, parallelizing consecutive read-only groups
        // while preserving the model's intended execution sequence.
        var i = 0
        while i < toolCalls.count {
            try Task.checkCancellation()

            if state.totalToolCalls >= maxBudget {
                // Budget exhausted — emit synthetic error results for remaining calls
                // so that every tool_call has a matching toolResult.
                for remaining in toolCalls[i...] {
                    state.conversation.append(.toolResult(
                        callID: remaining.id, name: remaining.name,
                        content: "Tool call skipped: maximum tool call budget exceeded.",
                        isError: true
                    ))
                }
                LLMProviderHelpers.debugLog("[Doufu Agent] exceeded maximum total tool calls, skipped \(toolCalls.count - i) calls")
                break
            }

            // Collect a consecutive run of read-only calls starting at i
            var readGroupEnd = i
            while readGroupEnd < toolCalls.count && readOnlyTools.contains(toolCalls[readGroupEnd].name) {
                readGroupEnd += 1
            }

            if readGroupEnd > i {
                // We have a consecutive read-only group — execute in parallel
                let group = Array(toolCalls[i..<readGroupEnd])
                let parallelResults = await executeToolCallsInParallel(
                    group,
                    toolProvider: toolProvider,
                    totalToolCalls: &state.totalToolCalls,
                    maxTotalToolCalls: maxBudget,
                    onProgress: onProgress,
                    toolActivityLog: &state.toolActivityLog
                )
                let executedCount = parallelResults.count
                for (toolCall, result) in parallelResults {
                    let desc = describeToolCall(toolCall)
                    let entry = buildToolActivityEntry(toolCall: toolCall, description: desc, result: result)
                    state.toolActivityEntries.append(entry)
                    if let onToolCompleted {
                        onToolCompleted(entry)
                    }
                    collectToolResult(result, into: &state)
                    let truncatedOutput = truncateToolResult(result.output)
                    state.conversation.append(.toolResult(
                        callID: toolCall.id, name: toolCall.name,
                        content: truncatedOutput, isError: result.isError
                    ))
                }
                // Emit synthetic results for calls that were truncated by budget
                if executedCount < group.count {
                    for skipped in group[executedCount...] {
                        state.conversation.append(.toolResult(
                            callID: skipped.id, name: skipped.name,
                            content: "Tool call skipped: maximum tool call budget exceeded.",
                            isError: true
                        ))
                    }
                }
                i = readGroupEnd
            } else {
                // Non-read-only call — execute sequentially
                let toolCall = toolCalls[i]

                state.totalToolCalls += 1
                if state.totalToolCalls > maxBudget {
                    // Over budget — emit synthetic result for this and remaining calls
                    for remaining in toolCalls[i...] {
                        state.conversation.append(.toolResult(
                            callID: remaining.id, name: remaining.name,
                            content: "Tool call skipped: maximum tool call budget exceeded.",
                            isError: true
                        ))
                    }
                    LLMProviderHelpers.debugLog("[Doufu Agent] exceeded maximum total tool calls, skipped \(toolCalls.count - i) calls")
                    break
                }

                let toolDescription = describeToolCall(toolCall)
                state.toolActivityLog.append(toolDescription)

                if let onToolStarted {
                    onToolStarted(toolDescription)
                }

                let result = await toolProvider.execute(toolCall: toolCall, onProgress: onProgress)
                try Task.checkCancellation()

                let entry = buildToolActivityEntry(toolCall: toolCall, description: toolDescription, result: result)
                state.toolActivityEntries.append(entry)
                if let onToolCompleted {
                    onToolCompleted(entry)
                }
                collectToolResult(result, into: &state)
                let truncatedOutput = truncateToolResult(result.output)
                state.conversation.append(.toolResult(
                    callID: toolCall.id, name: toolCall.name,
                    content: truncatedOutput, isError: result.isError
                ))
                i += 1
            }
        }
    }

    private func collectToolResult(
        _ result: AgentToolProvider.ToolExecutionResult,
        into state: inout AgentLoopState
    ) {
        if !result.changedPaths.isEmpty {
            let enriched = enrichPathsWithSummary(result.changedPaths, summary: result.changeSummary)
            mergeChangedPaths(enriched, into: &state.allChangedPaths)
        }
        if let meta = result.metadata {
            state.allToolMetadata.append(meta)
        }
    }

    private func buildFinalResult(
        accumulatedText: String,
        allChangedPaths: [String],
        allToolMetadata: [AgentToolProvider.ToolResultMetadata],
        toolActivityLog: [String],
        toolActivityEntries: [ToolActivityEntry],
        requestMemory: SessionMemory,
        trimmedMessage: String,
        workspaceURL: URL,
        projectIdentifier: String,
        usageAccumulator: UsageAccumulator,
        credential: ProjectChatService.ProviderCredential,
        onStreamedText: (@MainActor (String) -> Void)?
    ) async throws -> ProjectChatService.ResultPayload {
        let rawFinalMessage = accumulatedText.isEmpty ? String(localized: "orchestrator.done") : accumulatedText
        let (modelMemoryUpdate, afterMemory) = extractMemoryUpdate(from: rawFinalMessage)
        let cleanedFinalMessage = extractAndPersistDoufuUpdate(from: afterMemory, workspaceURL: workspaceURL)
        let finalMessage = cleanedFinalMessage.isEmpty ? String(localized: "orchestrator.done") : cleanedFinalMessage

        if let onStreamedText, cleanedFinalMessage != rawFinalMessage {
            onStreamedText(finalMessage)
        }

        if !allChangedPaths.isEmpty {
            createCheckpointAfterAgentLoop(workspaceURL: workspaceURL, userMessage: trimmedMessage)
        }

        let updatedMemory = memoryManager.buildRolledMemory(
            current: requestMemory,
            userMessage: trimmedMessage,
            assistantMessage: finalMessage,
            changedPaths: allChangedPaths,
            modelMemoryUpdate: modelMemoryUpdate
        )

        return ProjectChatService.ResultPayload(
            assistantMessage: finalMessage,
            changedPaths: allChangedPaths,
            updatedMemory: updatedMemory,
            requestTokenUsage: await persistedUsage(
                from: usageAccumulator,
                credential: credential,
                projectIdentifier: projectIdentifier
            ),
            toolActivitySummary: Self.serializeToolActivitySummary(entries: toolActivityEntries, fallbackLog: toolActivityLog),
            toolMetadata: allToolMetadata
        )
    }

    // MARK: - Helpers

    private func describeToolCall(_ toolCall: AgentToolCall) -> String {
        let args = toolCall.decodedArguments() ?? [:]
        let path = args["path"] as? String

        switch toolCall.name {
        case "read_file":
            return String(format: String(localized: "tool.activity.read_file"), path ?? "?")
        case "write_file":
            return String(format: String(localized: "tool.activity.write_file"), path ?? "?")
        case "edit_file":
            let editsCount = (args["edits"] as? [Any])?.count ?? 0
            return String(format: String(localized: "tool.activity.edit_file"), path ?? "?", editsCount)
        case "delete_file":
            return String(format: String(localized: "tool.activity.delete_file"), path ?? "?")
        case "move_file":
            let source = args["source"] as? String ?? "?"
            let dest = args["destination"] as? String ?? "?"
            return String(format: String(localized: "tool.activity.move_file"), source, dest)
        case "revert_file":
            return String(format: String(localized: "tool.activity.revert_file"), path ?? "?")
        case "diff_file":
            return String(format: String(localized: "tool.activity.diff_file"), path ?? "?")
        case "changed_files":
            return String(localized: "tool.activity.changed_files")
        case "list_directory":
            return String(format: String(localized: "tool.activity.list_directory"), path ?? ".")
        case "search_files":
            let query = args["query"] as? String ?? "?"
            return String(format: String(localized: "tool.activity.search_files"), query)
        case "grep_files":
            let pattern = args["pattern"] as? String ?? "?"
            return String(format: String(localized: "tool.activity.grep_files"), pattern)
        case "glob_files":
            let pattern = args["pattern"] as? String ?? "?"
            return String(format: String(localized: "tool.activity.glob_files"), pattern)
        case "web_search":
            let query = args["query"] as? String ?? "?"
            return String(format: String(localized: "tool.activity.web_search"), query)
        case "web_fetch":
            let url = args["url"] as? String ?? "?"
            return String(format: String(localized: "tool.activity.web_fetch"), url)
        default:
            return String(format: String(localized: "tool.activity.unknown"), toolCall.name)
        }
    }

    private static func serializeToolActivitySummary(
        entries: [ToolActivityEntry],
        fallbackLog: [String]
    ) -> String? {
        if !entries.isEmpty, let data = try? JSONEncoder().encode(entries),
           let json = String(data: data, encoding: .utf8) {
            return json
        }
        return fallbackLog.isEmpty ? nil : fallbackLog.joined(separator: "\n")
    }

    private func buildToolActivityEntry(
        toolCall: AgentToolCall,
        description: String,
        result: AgentToolProvider.ToolExecutionResult
    ) -> ToolActivityEntry {
        let truncatedOutput = String(result.output.prefix(2000))
        let args = toolCall.decodedArguments() ?? [:]
        let path = args["path"] as? String

        guard let meta = result.metadata else {
            return ToolActivityEntry(
                toolName: toolCall.name, description: description,
                output: truncatedOutput, isError: result.isError, path: path
            )
        }

        switch meta {
        case let .fileRead(metaPath, lineCount, sizeBytes):
            return ToolActivityEntry(
                toolName: toolCall.name, description: description,
                output: truncatedOutput, isError: result.isError,
                path: metaPath, lineCount: lineCount, sizeBytes: sizeBytes
            )
        case let .fileWritten(metaPath, isNew, sizeBytes):
            return ToolActivityEntry(
                toolName: toolCall.name, description: description,
                output: truncatedOutput, isError: result.isError,
                path: metaPath, sizeBytes: sizeBytes, isNew: isNew
            )
        case let .fileEdited(metaPath, editCount, diffPreview):
            return ToolActivityEntry(
                toolName: toolCall.name, description: description,
                output: truncatedOutput, isError: result.isError,
                path: metaPath, editCount: editCount,
                diffPreview: String(diffPreview.prefix(2000))
            )
        case let .fileDeleted(metaPath, sizeBytes):
            return ToolActivityEntry(
                toolName: toolCall.name, description: description,
                output: truncatedOutput, isError: result.isError,
                path: metaPath, sizeBytes: sizeBytes
            )
        case let .fileMoved(source, destination):
            return ToolActivityEntry(
                toolName: toolCall.name, description: description,
                output: truncatedOutput, isError: result.isError,
                source: source, destination: destination
            )
        case let .fileReverted(metaPath):
            return ToolActivityEntry(
                toolName: toolCall.name, description: description,
                output: truncatedOutput, isError: result.isError,
                path: metaPath
            )
        case let .directoryListed(metaPath, entryCount, _, _):
            return ToolActivityEntry(
                toolName: toolCall.name, description: description,
                output: truncatedOutput, isError: result.isError,
                path: metaPath, matchCount: entryCount
            )
        case let .searchResult(queryStr, matchCount, matchedFiles):
            return ToolActivityEntry(
                toolName: toolCall.name, description: description,
                output: truncatedOutput, isError: result.isError,
                query: queryStr, matchCount: matchCount,
                matchedFiles: Array(matchedFiles.prefix(20))
            )
        case let .webResult(urlStr, code):
            return ToolActivityEntry(
                toolName: toolCall.name, description: description,
                output: truncatedOutput, isError: result.isError,
                url: urlStr, statusCode: code
            )
        case let .codeValidation(metaPath, errorCount, passed):
            return ToolActivityEntry(
                toolName: toolCall.name, description: description,
                output: truncatedOutput, isError: result.isError,
                path: metaPath, errorCount: errorCount, passed: passed
            )
        }
    }

    private func persistedUsage(
        from accumulator: UsageAccumulator,
        credential: ProjectChatService.ProviderCredential,
        projectIdentifier: String?
    ) async -> ProjectChatService.RequestTokenUsage? {
        guard let totals = await accumulator.totals else {
            return nil
        }

        let tokenUsageID = tokenUsageStore.recordUsage(
            providerID: credential.providerID,
            model: credential.modelID,
            inputTokens: clampedTokenCount(totals.inputTokens),
            outputTokens: clampedTokenCount(totals.outputTokens),
            projectIdentifier: projectIdentifier
        )

        return ProjectChatService.RequestTokenUsage(
            tokenUsageID: tokenUsageID,
            inputTokens: totals.inputTokens,
            outputTokens: totals.outputTokens
        )
    }

    private func clampedTokenCount(_ value: Int64) -> Int {
        if value <= 0 {
            return 0
        }
        if value >= Int64(Int.max) {
            return Int.max
        }
        return Int(value)
    }

    private func readAgentsMarkdown(workspaceURL: URL) -> String? {
        let agentsURL = workspaceURL.appendingPathComponent("AGENTS.md")
        guard FileManager.default.fileExists(atPath: agentsURL.path),
              let content = try? String(contentsOf: agentsURL, encoding: .utf8),
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }
        return content
    }

    private func readDoufuMarkdown(workspaceURL: URL) -> String? {
        let doufuURL = workspaceURL.appendingPathComponent("DOUFU.MD")
        guard FileManager.default.fileExists(atPath: doufuURL.path),
              let content = try? String(contentsOf: doufuURL, encoding: .utf8),
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }
        return content
    }

    private func autoSaveBeforeAgentLoop(workspaceURL: URL) {
        do {
            try gitService.ensureRepository(at: workspaceURL)
            try gitService.autoSaveIfDirty(repositoryURL: workspaceURL)
        } catch {
            LLMProviderHelpers.debugLog("[Doufu Agent] git auto-save failed: \(error.localizedDescription)")
        }
    }

    private func createCheckpointAfterAgentLoop(workspaceURL: URL, userMessage: String) {
        do {
            try gitService.createCheckpoint(repositoryURL: workspaceURL, userMessage: userMessage)
        } catch {
            LLMProviderHelpers.debugLog("[Doufu Agent] git checkpoint failed: \(error.localizedDescription)")
        }
    }

    private func truncateToolResult(_ output: String) -> String {
        let maxChars = configuration.maxToolResultCharacters
        guard output.count > maxChars else { return output }
        let cutoff = output.prefix(maxChars)
        // Prefer cutting at a newline boundary to avoid mid-line truncation
        if let lastNewline = cutoff.lastIndex(of: "\n") {
            return String(cutoff[...lastNewline])
                + "\n[Output truncated at \(maxChars) characters]"
        }
        return String(cutoff)
            + "\n\n[Output truncated at \(maxChars) characters]"
    }

    /// Compact the conversation when it approaches the model's context window.
    ///
    /// When actual token counts from the API are available (after the first
    /// iteration), compaction uses them directly for an accurate measurement.
    /// Otherwise it falls back to character-based estimation.
    ///
    /// Compaction proceeds in four passes, each increasingly aggressive:
    /// 1. Compact re-readable tool results (read_file, list_directory) — model can re-read.
    /// 2. Compact search tool results — re-search is costlier but still possible.
    /// 3. Compact all remaining large non-error tool results.
    /// 4. Drop the oldest conversation turns (preserving the most recent N items).
    private func compactConversationIfNeeded(
        _ conversation: inout [AgentConversationItem],
        credential: ProjectChatService.ProviderCredential,
        lastInputTokens: Int? = nil
    ) {
        let contextWindow = credential.profile.contextWindowTokens

        // If we have actual token counts from the last API call, use them
        // directly — this is far more accurate than character estimation.
        if let inputTokens = lastInputTokens {
            let usageRatio = Double(inputTokens) / Double(contextWindow)
            guard usageRatio > configuration.compactionTargetRatio else { return }
        } else {
            let maxConversationChars = configuration.maxConversationCharacters(
                contextWindowTokens: contextWindow
            )
            let totalChars = conversationCharacterCount(conversation)
            guard totalChars > maxConversationChars else { return }
        }

        // Compaction target: character-based budget (used for pass thresholds)
        let maxConversationChars = configuration.maxConversationCharacters(
            contextWindowTokens: contextWindow
        )
        let totalChars = conversationCharacterCount(conversation)

        let protectedTail = configuration.compactionProtectedTailItems
        let compactableEnd = max(0, conversation.count - protectedTail)

        let reReadableTools: Set<String> = ["read_file", "list_directory"]
        let searchTools: Set<String> = ["search_files", "grep_files", "glob_files", "web_search", "web_fetch"]

        // Pass 1: aggressively compact re-readable tool results (model can re-read)
        var excess = totalChars - maxConversationChars
        for i in 0..<compactableEnd {
            guard excess > 0 else { break }
            if case let .toolResult(callID, name, content, isError) = conversation[i],
               !isError, reReadableTools.contains(name), content.count > 300 {
                let truncated = String(content.prefix(100)) + "\n[Compacted]"
                let saved = content.count - truncated.count
                conversation[i] = .toolResult(callID: callID, name: name, content: truncated, isError: isError)
                excess -= saved
            }
        }

        // Pass 2: moderately compact search results (preserve more context)
        for i in 0..<compactableEnd {
            guard excess > 0 else { break }
            if case let .toolResult(callID, name, content, isError) = conversation[i],
               !isError, searchTools.contains(name), content.count > 800 {
                let truncated = String(content.prefix(400)) + "\n[Compacted]"
                let saved = content.count - truncated.count
                conversation[i] = .toolResult(callID: callID, name: name, content: truncated, isError: isError)
                excess -= saved
            }
        }

        // Pass 3: compact remaining large non-error results if still over budget
        for i in 0..<compactableEnd {
            guard excess > 0 else { break }
            if case let .toolResult(callID, name, content, isError) = conversation[i],
               !isError, content.count > 500 {
                let truncated = String(content.prefix(200)) + "\n[Compacted]"
                let saved = content.count - truncated.count
                guard saved > 0 else { continue }
                conversation[i] = .toolResult(callID: callID, name: name, content: truncated, isError: isError)
                excess -= saved
            }
        }

        // Pass 4: drop oldest *complete* turn groups if still over budget.
        // A turn group is: userMessage, followed by assistantMessage, followed
        // by zero or more toolResult items that belong to that assistant turn.
        // We never split a group — this guarantees every toolResult has its
        // matching assistant tool_call in the conversation, satisfying the
        // Anthropic/OpenAI pairing constraint.
        if excess > 0, compactableEnd > 0 {
            var dropEnd = 0
            var freedChars = 0

            while dropEnd < compactableEnd, freedChars < excess {
                // Find the end of the next complete turn group starting at dropEnd.
                let groupEnd = findTurnGroupEnd(in: conversation, from: dropEnd, limit: compactableEnd)
                guard groupEnd > dropEnd else { break } // safety: no progress

                var groupChars = 0
                for i in dropEnd..<groupEnd {
                    groupChars += conversationItemCharCount(conversation[i])
                }
                dropEnd = groupEnd
                freedChars += groupChars
            }

            if dropEnd > 0 {
                let droppedCount = dropEnd
                let marker = AgentConversationItem.userMessage(
                    "[System: \(droppedCount) earlier conversation items removed to fit context window.]"
                )
                conversation.replaceSubrange(0..<dropEnd, with: [marker])
            }
        }
    }

    private func conversationCharacterCount(_ conversation: [AgentConversationItem]) -> Int {
        conversation.reduce(0) { $0 + conversationItemCharCount($1) }
    }

    private func conversationItemCharCount(_ item: AgentConversationItem) -> Int {
        switch item {
        case let .userMessage(text):
            return text.count
        case let .assistantMessage(text, toolCalls):
            return text.count + toolCalls.reduce(0) { $0 + $1.argumentsJSON.count }
        case let .toolResult(_, _, content, _):
            return content.count
        }
    }

    /// Find the end index of the next complete turn group starting at `from`.
    /// A turn group is: [userMessage] [assistantMessage] [toolResult*].
    /// Returns `from` if no complete group can be formed before `limit`.
    private func findTurnGroupEnd(
        in conversation: [AgentConversationItem],
        from start: Int,
        limit: Int
    ) -> Int {
        var i = start

        // Skip leading toolResults that belong to a prior (already-dropped) group.
        while i < limit {
            if case .toolResult = conversation[i] { i += 1 } else { break }
        }

        // Consume one userMessage (if present).
        if i < limit, case .userMessage = conversation[i] { i += 1 }

        // Consume one assistantMessage (if present).
        if i < limit, case .assistantMessage = conversation[i] { i += 1 }

        // Consume all following toolResults that belong to this assistant turn.
        while i < limit {
            if case .toolResult = conversation[i] { i += 1 } else { break }
        }

        // If we didn't advance at all, force advance by 1 to avoid infinite loop
        // (shouldn't happen with well-formed conversations, but be defensive).
        if i == start && i < limit { i += 1 }

        return i
    }

    /// Execute read-only tool calls concurrently and return results in the original call order.
    private func executeToolCallsInParallel(
        _ calls: [AgentToolCall],
        toolProvider: AgentToolProvider,
        totalToolCalls: inout Int,
        maxTotalToolCalls: Int,
        onProgress: (@MainActor (ToolProgressEvent) -> Void)?,
        toolActivityLog: inout [String]
    ) async -> [(AgentToolCall, AgentToolProvider.ToolExecutionResult)] {
        // Enforce tool call budget: only execute as many calls as the remaining budget allows.
        let remaining = max(0, maxTotalToolCalls - totalToolCalls)
        let effectiveCalls: [AgentToolCall]
        if calls.count > remaining {
            LLMProviderHelpers.debugLog("[Doufu Agent] parallel tool calls truncated from \(calls.count) to \(remaining) (budget exhausted)")
            effectiveCalls = Array(calls.prefix(remaining))
        } else {
            effectiveCalls = calls
        }

        guard !effectiveCalls.isEmpty else { return [] }

        // Log activity for all calls first
        for call in effectiveCalls {
            totalToolCalls += 1
            let description = describeToolCall(call)
            toolActivityLog.append(description)
        }

        if let onProgress {
            if effectiveCalls.count == 1 {
                onProgress(.text(describeToolCall(effectiveCalls[0])))
            } else {
                let descriptions = effectiveCalls.map { describeToolCall($0) }
                onProgress(.parallelBatch(count: effectiveCalls.count, descriptions: descriptions))
            }
        }

        // Execute concurrently using a task group
        let indexedResults = await withTaskGroup(
            of: (Int, AgentToolCall, AgentToolProvider.ToolExecutionResult).self,
            returning: [(AgentToolCall, AgentToolProvider.ToolExecutionResult)].self
        ) { group in
            for (index, call) in effectiveCalls.enumerated() {
                group.addTask {
                    let result = await toolProvider.execute(toolCall: call)
                    return (index, call, result)
                }
            }

            var collected: [(Int, AgentToolCall, AgentToolProvider.ToolExecutionResult)] = []
            for await item in group {
                collected.append(item)
            }
            // Sort by original index to preserve call order
            return collected.sorted { $0.0 < $1.0 }.map { ($0.1, $0.2) }
        }

        return indexedResults
    }

    private func mergeChangedPaths(_ paths: [String], into target: inout [String]) {
        let maxSummaryLength = 80
        // Deduplicate by path prefix (before " — ") so that enriched entries
        // update rather than duplicate plain path entries.
        for path in paths {
            let pathKey = Self.extractPathKey(from: path)
            if let existingIdx = target.firstIndex(where: { Self.extractPathKey(from: $0) == pathKey }) {
                // Replace if the new entry has a summary and the old one doesn't,
                // or append summaries for multiple edits.
                let existingSummary = Self.extractSummary(from: target[existingIdx])
                let newSummary = Self.extractSummary(from: path)
                if let new = newSummary {
                    if let existing = existingSummary {
                        let merged = "\(existing), \(new)"
                        let summary = merged.count > maxSummaryLength ? "multiple edits" : merged
                        target[existingIdx] = "\(pathKey) — \(summary)"
                    } else {
                        target[existingIdx] = path
                    }
                }
                // If new has no summary, keep existing as-is
            } else {
                target.append(path)
            }
        }
    }

    /// Attach a change summary to each path: "index.html" + "edited 2 regions" → "index.html — edited 2 regions"
    private func enrichPathsWithSummary(_ paths: [String], summary: String?) -> [String] {
        guard let summary, !summary.isEmpty else { return paths }
        let truncated = summary.count > 60 ? String(summary.prefix(60)) : summary
        return paths.map { path in
            // Don't double-enrich paths that already have a summary
            if path.contains(" — ") { return path }
            return "\(path) — \(truncated)"
        }
    }

    private static func extractPathKey(from entry: String) -> String {
        if let dashRange = entry.range(of: " — ") {
            return String(entry[..<dashRange.lowerBound])
        }
        return entry
    }

    private static func extractSummary(from entry: String) -> String? {
        guard let dashRange = entry.range(of: " — ") else { return nil }
        return String(entry[dashRange.upperBound...])
    }

    /// Parse a `<doufu-update>` block from the model's response text, persist
    /// new lines to DOUFU.MD, and return the text with the block removed.
    @discardableResult
    private func extractAndPersistDoufuUpdate(from text: String, workspaceURL: URL) -> String {
        let openTag = "<doufu-update>"
        let closeTag = "</doufu-update>"

        guard let openRange = text.range(of: openTag),
              let closeRange = text.range(of: closeTag, range: openRange.upperBound..<text.endIndex)
        else {
            return text
        }

        let blockContent = String(text[openRange.upperBound..<closeRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Remove the block from displayed text
        let fullBlockRange = openRange.lowerBound..<closeRange.upperBound
        var cleaned = text
        cleaned.removeSubrange(fullBlockRange)
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

        // Parse lines to append
        let newLines = blockContent
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard !newLines.isEmpty else { return cleaned }

        // Read existing DOUFU.MD content for deduplication
        let doufuURL = workspaceURL.appendingPathComponent("DOUFU.MD")
        let existingContent = (try? String(contentsOf: doufuURL, encoding: .utf8)) ?? ""
        let existingLines = Set(
            existingContent
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        )

        // Filter out lines that already exist (case-insensitive trimmed comparison)
        let linesToAppend = newLines.filter { line in
            !existingLines.contains(line.lowercased())
        }

        guard !linesToAppend.isEmpty else { return cleaned }

        // Append to DOUFU.MD (create if needed)
        do {
            var content = existingContent
            if !content.isEmpty && !content.hasSuffix("\n") {
                content += "\n"
            }
            content += linesToAppend.joined(separator: "\n") + "\n"
            try content.write(to: doufuURL, atomically: true, encoding: .utf8)
            LLMProviderHelpers.debugLog("[Doufu Agent] appended \(linesToAppend.count) lines to DOUFU.MD")
        } catch {
            LLMProviderHelpers.debugLog("[Doufu Agent] failed to write DOUFU.MD: \(error.localizedDescription)")
        }

        return cleaned
    }

    /// Parse a `<memory-update>` JSON block from the model's response text.
    /// Returns the parsed update and the text with the block removed.
    ///
    /// Also handles the `<tool_call><function=memory-update>` variant that
    /// some models emit when they misinterpret metadata instructions.
    private func extractMemoryUpdate(from text: String) -> (update: PatchMemoryUpdate?, cleanedText: String) {
        // Standard format: <memory-update>{JSON}</memory-update>
        let openTag = "<memory-update>"
        let closeTag = "</memory-update>"

        if let openRange = text.range(of: openTag),
           let closeRange = text.range(of: closeTag, range: openRange.upperBound..<text.endIndex) {
            let jsonString = String(text[openRange.upperBound..<closeRange.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)

            var update: PatchMemoryUpdate?
            if let data = jsonString.data(using: .utf8) {
                update = try? JSONDecoder().decode(PatchMemoryUpdate.self, from: data)
            }

            var cleaned = text
            cleaned.removeSubrange(openRange.lowerBound..<closeRange.upperBound)
            cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
            return (update, cleaned)
        }

        // Fallback: <tool_call><function=memory-update><parameter=...>...</parameter></function></tool_call>
        let (toolCallUpdate, afterToolCall) = extractMemoryUpdateFromToolCallBlocks(in: text)
        return (toolCallUpdate, afterToolCall)
    }

    /// Parse `<tool_call>` blocks that some models emit for memory-update.
    ///
    /// Format:
    /// ```
    /// <tool_call> <function=memory-update>
    ///   <parameter=objective>text</parameter>
    ///   <parameter=todo_items>["a","b"]</parameter>
    ///   <parameter=constraints>["c"]</parameter>
    /// </function> </tool_call>
    /// ```
    private func extractMemoryUpdateFromToolCallBlocks(in text: String) -> (update: PatchMemoryUpdate?, cleanedText: String) {
        guard let blockRegex = try? NSRegularExpression(
            pattern: #"<tool_call>[\s\S]*?</tool_call>"#
        ) else {
            return (nil, text)
        }

        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        let matches = blockRegex.matches(in: text, range: fullRange)
        guard !matches.isEmpty else {
            return (nil, text)
        }

        var bestUpdate: PatchMemoryUpdate?

        // Try to parse memory-update from each <tool_call> block
        let paramRegex = try? NSRegularExpression(
            pattern: #"<parameter=(\w+)>([\s\S]*?)</parameter>"#
        )

        for match in matches {
            let blockString = nsText.substring(with: match.range)
            // Only parse blocks that target memory-update
            guard blockString.contains("memory-update") || blockString.contains("memory_update") else {
                continue
            }
            guard let paramRegex else { continue }

            let blockNS = blockString as NSString
            let blockRange = NSRange(location: 0, length: blockNS.length)
            let paramMatches = paramRegex.matches(in: blockString, range: blockRange)

            var objective: String?
            var constraints: [String]?
            var todoItems: [String]?

            for pm in paramMatches {
                guard pm.numberOfRanges >= 3 else { continue }
                let key = blockNS.substring(with: pm.range(at: 1))
                let value = blockNS.substring(with: pm.range(at: 2))
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                switch key {
                case "objective":
                    objective = value.isEmpty ? nil : value
                case "constraints":
                    constraints = parseJSONStringArray(value)
                case "todo_items":
                    todoItems = parseJSONStringArray(value)
                default:
                    break
                }
            }

            if objective != nil || constraints != nil || todoItems != nil {
                bestUpdate = PatchMemoryUpdate(
                    objective: objective,
                    constraints: constraints,
                    todoItems: todoItems
                )
            }
        }

        // Remove all <tool_call> blocks from the displayed text
        let cleaned = blockRegex.stringByReplacingMatches(in: text, range: fullRange, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return (bestUpdate, cleaned)
    }

    /// Try to parse a string as a JSON array of strings.
    /// Falls back to splitting by comma for plain text lists.
    private func parseJSONStringArray(_ text: String) -> [String]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "[]" { return [] }

        // Try JSON array first
        if trimmed.hasPrefix("["),
           let data = trimmed.data(using: .utf8),
           let array = try? JSONDecoder().decode([String].self, from: data) {
            return array
        }

        // Plain text: single item
        return [trimmed]
    }

}
