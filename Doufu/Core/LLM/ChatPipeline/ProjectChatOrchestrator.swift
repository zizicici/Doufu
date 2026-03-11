//
//  ProjectChatOrchestrator.swift
//  Doufu
//
//  Created by Codex on 2026/03/05.
//

import Foundation

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
        onProgress: (@MainActor (ToolProgressEvent) -> Void)? = nil
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
        toolProvider.codeValidator = await CodeValidator()
        toolProvider.validationServerBaseURL = validationServerBaseURL
        toolProvider.validationBridge = validationBridge

        do {
        // Auto-save any uncommitted changes (e.g. user manual edits)
        // before the agent starts, so they are preserved for undo.
        autoSaveBeforeAgentLoop(workspaceURL: workspaceURL)

        // Read AGENTS.md and DOUFU.MD if present
        let agentsMarkdown = readAgentsMarkdown(workspaceURL: workspaceURL)
        let doufuMarkdown = readDoufuMarkdown(workspaceURL: workspaceURL)

        // Build system prompt
        let systemPrompt = promptBuilder.agentSystemPrompt(
            agentsMarkdown: agentsMarkdown,
            doufuMarkdown: doufuMarkdown
        )

        // Build initial conversation
        var conversation: [AgentConversationItem] = []

        // Add history turns (include tool summaries so the model knows what happened)
        // Build an ID→toolSummary lookup from the normalized history for fast matching
        let toolSummaryByID: [String: String] = normalizedHistory.reduce(into: [:]) { map, turn in
            if turn.role == .assistant, let summary = turn.toolSummary, !summary.isEmpty {
                map[turn.id] = summary
            }
        }
        let historyItems = memoryManager.buildHistoryInputMessages(from: normalizedHistory)
        for item in historyItems {
            let role = item.role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let text = item.content.map(\.text).joined(separator: "\n")
            if role == "user" {
                conversation.append(.userMessage(text))
            } else if role == "assistant" {
                var assistantText = text
                // Use the turn ID embedded in the ResponseInputMessage to look up
                // the tool summary instead of fragile text comparison
                if let turnID = item.sourceTurnID,
                   let summary = toolSummaryByID[turnID], !summary.isEmpty {
                    assistantText += "\n\n<tool-activity>\n\(summary)\n</tool-activity>"
                }
                conversation.append(.assistantMessage(text: assistantText, toolCalls: []))
            }
        }

        // Add current user message with memory context
        let memoryJSON = memoryManager.encodeMemoryToJSONString(requestMemory)
        let userPrompt = promptBuilder.agentUserPrompt(
            userMessage: trimmedMessage,
            memoryJSON: memoryJSON
        )
        conversation.append(.userMessage(userPrompt))

        // Agent loop
        var allChangedPaths: [String] = []
        var allToolMetadata: [AgentToolProvider.ToolResultMetadata] = []
        var accumulatedText = ""
        var totalToolCalls = 0
        var toolActivityLog: [String] = []

        if let onProgress {
            await onProgress(.text(String(localized: "orchestrator.thinking")))
        }

        let budgetWarningThreshold = Int(Double(configuration.maxAgentIterations) * 0.8)

        for iteration in 0 ..< configuration.maxAgentIterations {
            try Task.checkCancellation()

            // Inject budget warning when approaching iteration limit.
            // Append as a system-like user message. If the last item is already
            // a userMessage (e.g. a continuation prompt), merge into it to
            // avoid violating the user/assistant alternation constraint.
            if iteration == budgetWarningThreshold {
                let remaining = configuration.maxAgentIterations - iteration
                let warning = "[System: You have \(remaining) tool-use iterations remaining. Please complete your current task and provide a summary. Do not start new tasks.]"
                if case let .userMessage(existingText) = conversation.last {
                    conversation[conversation.count - 1] = .userMessage(existingText + "\n\n" + warning)
                } else {
                    conversation.append(.userMessage(warning))
                }
            }

            // Stream text from the LLM response to the UI in real-time.
            // Only send the current iteration's partial text (not the full
            // accumulated text) so each progress bubble stays independent.
            let streamCallback: (@MainActor (String) -> Void)? = onStreamedText.map { callback in
                { @MainActor partialText in
                    let trimmed = partialText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        callback(trimmed)
                    }
                }
            }

            let lastInputTokens = await usageAccumulator.lastSingleCallInputTokens
            compactConversationIfNeeded(&conversation, credential: credential, lastInputTokens: lastInputTokens)

            let response = try await streamingClient.requestWithTools(
                systemInstruction: systemPrompt,
                conversationItems: conversation,
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

            // Emit extended thinking content if present
            if let thinking = response.thinkingContent, !thinking.isEmpty, let onProgress {
                await onProgress(.thinking(content: thinking))
            }

            // No tool calls — check if this is a final response or a truncated one
            if response.toolCalls.isEmpty {
                if !responseText.isEmpty {
                    accumulatedText += (accumulatedText.isEmpty ? "" : "\n\n") + responseText
                }
                if let onStreamedText {
                    await onStreamedText(responseText)
                }

                // If truncated by max_tokens, auto-continue
                if response.stopReason == .maxTokens {
                    conversation.append(.assistantMessage(text: responseText, toolCalls: []))
                    conversation.append(.userMessage("Please continue from where you left off."))
                    LLMProviderHelpers.debugLog("[Doufu Agent] response truncated (max_tokens), requesting continuation")
                    continue
                }

                let rawFinalMessage = accumulatedText.isEmpty ? String(localized: "orchestrator.done") : accumulatedText
                let (modelMemoryUpdate, afterMemory) = extractMemoryUpdate(from: rawFinalMessage)
                let cleanedFinalMessage = extractAndPersistDoufuUpdate(from: afterMemory, workspaceURL: workspaceURL)
                let finalMessage = cleanedFinalMessage.isEmpty ? String(localized: "orchestrator.done") : cleanedFinalMessage

                if let onStreamedText, cleanedFinalMessage != rawFinalMessage {
                    await onStreamedText(finalMessage)
                }

                if !allChangedPaths.isEmpty {
                    AppProjectStore.shared.touchProjectUpdatedAt(projectID: projectIdentifier)
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
                    toolActivitySummary: toolActivityLog.isEmpty ? nil : toolActivityLog.joined(separator: "\n"),
                    toolMetadata: allToolMetadata
                )
            }

            // Has tool calls — execute them
            if !responseText.isEmpty {
                accumulatedText += (accumulatedText.isEmpty ? "" : "\n\n") + responseText
                if let onStreamedText {
                    await onStreamedText(responseText)
                }
            }

            // Add assistant message with tool calls to conversation
            conversation.append(.assistantMessage(text: responseText, toolCalls: response.toolCalls))

            // Partition tool calls into read-only (parallelizable) and mutating (sequential)
            // validate_code uses a shared WKWebView and is NOT safe to parallelize.
            let readOnlyTools: Set<String> = ["read_file", "list_directory", "search_files", "grep_files", "glob_files", "diff_file", "changed_files"]
            let (parallelCalls, sequentialCalls) = partitionToolCalls(response.toolCalls, readOnly: readOnlyTools)

            // Execute read-only tools in parallel
            if !parallelCalls.isEmpty {
                let parallelResults = await executeToolCallsInParallel(
                    parallelCalls,
                    toolProvider: toolProvider,
                    totalToolCalls: &totalToolCalls,
                    maxTotalToolCalls: configuration.maxAgentIterations * configuration.maxToolCallsPerIteration,
                    onProgress: onProgress,
                    toolActivityLog: &toolActivityLog
                )
                for (toolCall, result) in parallelResults {
                    if !result.changedPaths.isEmpty {
                        let enriched = enrichPathsWithSummary(result.changedPaths, summary: result.changeSummary)
                        mergeChangedPaths(enriched, into: &allChangedPaths)
                    }
                    if let meta = result.metadata {
                        allToolMetadata.append(meta)
                    }
                    let truncatedOutput = truncateToolResult(result.output)
                    conversation.append(.toolResult(
                        callID: toolCall.id,
                        name: toolCall.name,
                        content: truncatedOutput,
                        isError: result.isError
                    ))
                }
            }

            // Execute mutating tools sequentially
            for toolCall in sequentialCalls {
                try Task.checkCancellation()

                totalToolCalls += 1
                if totalToolCalls > configuration.maxAgentIterations * configuration.maxToolCallsPerIteration {
                    LLMProviderHelpers.debugLog("[Doufu Agent] exceeded maximum total tool calls, stopping")
                    break
                }

                let toolDescription = describeToolCall(toolCall)
                toolActivityLog.append(toolDescription)

                let result = await toolProvider.execute(toolCall: toolCall, onProgress: onProgress)

                // Emit completion event if the tool produced one, otherwise fall back to text
                if let onProgress {
                    if let event = result.completionEvent {
                        await onProgress(event)
                    } else {
                        await onProgress(.text(toolDescription))
                    }
                }

                // Track changed paths and metadata
                if !result.changedPaths.isEmpty {
                    let enriched = enrichPathsWithSummary(result.changedPaths, summary: result.changeSummary)
                    mergeChangedPaths(enriched, into: &allChangedPaths)
                }
                if let meta = result.metadata {
                    allToolMetadata.append(meta)
                }

                // Add tool result to conversation (truncated to prevent context bloat)
                let truncatedOutput = truncateToolResult(result.output)
                conversation.append(.toolResult(
                    callID: toolCall.id,
                    name: toolCall.name,
                    content: truncatedOutput,
                    isError: result.isError
                ))
            }

            LLMProviderHelpers.debugLog("[Doufu Agent] iteration \(iteration + 1): \(response.toolCalls.count) tool calls executed, \(allChangedPaths.count) files changed total")
        }

        // Max iterations reached
        let rawMaxMessage = accumulatedText.isEmpty
            ? String(localized: "orchestrator.max_iterations_reached")
            : accumulatedText + "\n\n" + String(localized: "orchestrator.max_iterations_suffix")
        let (maxModelMemoryUpdate, afterMaxMemory) = extractMemoryUpdate(from: rawMaxMessage)
        let finalMessage = extractAndPersistDoufuUpdate(from: afterMaxMemory, workspaceURL: workspaceURL)

        if !allChangedPaths.isEmpty {
            AppProjectStore.shared.touchProjectUpdatedAt(projectID: projectIdentifier)
            createCheckpointAfterAgentLoop(workspaceURL: workspaceURL, userMessage: trimmedMessage)
        }

        let updatedMemory = memoryManager.buildRolledMemory(
            current: requestMemory,
            userMessage: trimmedMessage,
            assistantMessage: finalMessage,
            changedPaths: allChangedPaths,
            modelMemoryUpdate: maxModelMemoryUpdate
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
            toolActivitySummary: toolActivityLog.isEmpty ? nil : toolActivityLog.joined(separator: "\n"),
            toolMetadata: allToolMetadata
        )

        } catch {
            // Always record consumed tokens, even on cancel/error
            let _ = await persistedUsage(
                from: usageAccumulator,
                credential: credential,
                projectIdentifier: projectIdentifier
            )
            throw error
        }
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
                let truncated = String(content.prefix(100)) + "\n[Compacted — use \(name) again if needed]"
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
                let truncated = String(content.prefix(400)) + "\n[Compacted to save context space]"
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
                let truncated = String(content.prefix(200)) + "\n[Compacted to save context space]"
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
                    "[System: \(droppedCount) earlier conversation items were removed to fit the context window. Use tools to re-read any files you need.]"
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

    /// Partition tool calls into read-only (safe to parallelize) and mutating (must run sequentially).
    /// Preserves original ordering within each group.
    private func partitionToolCalls(
        _ calls: [AgentToolCall],
        readOnly: Set<String>
    ) -> (parallel: [AgentToolCall], sequential: [AgentToolCall]) {
        var parallel: [AgentToolCall] = []
        var sequential: [AgentToolCall] = []
        for call in calls {
            if readOnly.contains(call.name) {
                parallel.append(call)
            } else {
                sequential.append(call)
            }
        }
        return (parallel, sequential)
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
        // Log activity for all calls first
        for call in calls {
            totalToolCalls += 1
            let description = describeToolCall(call)
            toolActivityLog.append(description)
        }

        if let onProgress {
            if calls.count == 1 {
                await onProgress(.text(describeToolCall(calls[0])))
            } else {
                let descriptions = calls.map { describeToolCall($0) }
                await onProgress(.parallelBatch(count: calls.count, descriptions: descriptions))
            }
        }

        // Execute concurrently using a task group
        let indexedResults = await withTaskGroup(
            of: (Int, AgentToolCall, AgentToolProvider.ToolExecutionResult).self,
            returning: [(AgentToolCall, AgentToolProvider.ToolExecutionResult)].self
        ) { group in
            for (index, call) in calls.enumerated() {
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
                        target[existingIdx] = "\(pathKey) — \(existing), \(new)"
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
    private func extractMemoryUpdate(from text: String) -> (update: PatchMemoryUpdate?, cleanedText: String) {
        let openTag = "<memory-update>"
        let closeTag = "</memory-update>"

        guard let openRange = text.range(of: openTag),
              let closeRange = text.range(of: closeTag, range: openRange.upperBound..<text.endIndex)
        else {
            return (nil, text)
        }

        let jsonString = String(text[openRange.upperBound..<closeRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var update: PatchMemoryUpdate?
        if let data = jsonString.data(using: .utf8) {
            update = try? JSONDecoder().decode(PatchMemoryUpdate.self, from: data)
        }

        // Remove the entire <memory-update>...</memory-update> block from the displayed text
        let fullBlockRange = openRange.lowerBound..<closeRange.upperBound
        var cleaned = text
        cleaned.removeSubrange(fullBlockRange)
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

        return (update, cleaned)
    }

}
