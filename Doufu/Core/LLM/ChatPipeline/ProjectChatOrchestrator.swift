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

        func record(inputTokens: Int?, outputTokens: Int?) {
            let normalizedInput = max(0, inputTokens ?? 0)
            let normalizedOutput = max(0, outputTokens ?? 0)
            self.inputTokens += Int64(normalizedInput)
            self.outputTokens += Int64(normalizedOutput)
        }

        var usage: ProjectChatService.RequestTokenUsage? {
            guard inputTokens > 0 || outputTokens > 0 else {
                return nil
            }
            return ProjectChatService.RequestTokenUsage(
                inputTokens: inputTokens,
                outputTokens: outputTokens
            )
        }
    }

    private let configuration: ProjectChatConfiguration
    private let memoryManager: SessionMemoryManager
    private let promptBuilder: PromptBuilder
    private let streamingClient: LLMStreamingClient
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
        projectURL: URL,
        credential: ProjectChatService.ProviderCredential,
        memory: ProjectChatService.SessionMemory? = nil,
        threadContext: ProjectChatService.ThreadContext?,
        executionOptions: ProjectChatService.ModelExecutionOptions,
        confirmationHandler: ToolConfirmationHandler? = nil,
        permissionMode: ToolPermissionMode = .standard,
        validationServerBaseURL: URL? = nil,
        validationBridge: DoufuBridge? = nil,
        onStreamedText: (@MainActor (String) -> Void)? = nil,
        onProgress: (@MainActor (ToolProgressEvent) -> Void)? = nil
    ) async throws -> ProjectChatService.ResultPayload {
        let trimmedMessage = userMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMessage.isEmpty else {
            throw ProjectChatService.ServiceError.invalidResponse
        }

        let normalizedHistory = memoryManager.normalizedHistoryTurns(history, excludingLatestUserMessage: trimmedMessage)
        let requestMemory = memoryManager.buildRequestMemory(base: memory, latestUserMessage: trimmedMessage)
        let usageAccumulator = UsageAccumulator()
        let toolProvider = AgentToolProvider(projectURL: projectURL, configuration: configuration)
        toolProvider.confirmationHandler = confirmationHandler
        toolProvider.permissionMode = permissionMode
        toolProvider.codeValidator = await CodeValidator()
        toolProvider.validationServerBaseURL = validationServerBaseURL
        toolProvider.validationBridge = validationBridge

        // Create git checkpoint before agent loop starts
        createCheckpointBeforeAgentLoop(projectURL: projectURL, userMessage: trimmedMessage)

        // Read AGENTS.md and DOUFU.MD if present
        let agentsMarkdown = readAgentsMarkdown(projectURL: projectURL)
        let doufuMarkdown = readDoufuMarkdown(projectURL: projectURL)

        // Build system prompt
        let systemPrompt = promptBuilder.agentSystemPrompt(
            threadContext: threadContext,
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
            await onProgress(.text("正在思考..."))
        }

        let budgetWarningThreshold = Int(Double(configuration.maxAgentIterations) * 0.8)

        for iteration in 0 ..< configuration.maxAgentIterations {
            try Task.checkCancellation()

            // Inject budget warning when approaching iteration limit
            if iteration == budgetWarningThreshold {
                let remaining = configuration.maxAgentIterations - iteration
                conversation.append(.userMessage(
                    "[System: You have \(remaining) tool-use iterations remaining. Please complete your current task and provide a summary. Do not start new tasks.]"
                ))
            }

            // Stream text from the LLM response to the UI in real-time.
            // We capture the current accumulated text prefix so that partial
            // streaming deltas are displayed after prior context.
            let currentPrefix = accumulatedText.isEmpty ? "" : accumulatedText + "\n\n"
            let streamCallback: (@MainActor (String) -> Void)? = onStreamedText.map { callback in
                { @MainActor partialText in
                    let trimmed = partialText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        callback(currentPrefix + trimmed)
                    }
                }
            }

            compactConversationIfNeeded(&conversation, credential: credential)

            let response = try await streamingClient.requestWithTools(
                systemInstruction: systemPrompt,
                conversationItems: conversation,
                tools: toolProvider.toolDefinitions(),
                credential: credential,
                projectUsageIdentifier: projectURL.standardizedFileURL.path,
                executionOptions: executionOptions,
                onStreamedText: streamCallback,
                onUsage: { inputTokens, outputTokens in
                    Task { await usageAccumulator.record(inputTokens: inputTokens, outputTokens: outputTokens) }
                }
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
                    await onStreamedText(accumulatedText)
                }

                // If truncated by max_tokens, auto-continue
                if response.stopReason == .maxTokens {
                    conversation.append(.assistantMessage(text: responseText, toolCalls: []))
                    conversation.append(.userMessage("Please continue from where you left off."))
                    debugLog("[Doufu Agent] response truncated (max_tokens), requesting continuation")
                    continue
                }

                let rawFinalMessage = accumulatedText.isEmpty ? "已完成。" : accumulatedText
                let (modelMemoryUpdate, cleanedFinalMessage) = extractMemoryUpdate(from: rawFinalMessage)
                let finalMessage = cleanedFinalMessage.isEmpty ? "已完成。" : cleanedFinalMessage

                if let onStreamedText, cleanedFinalMessage != rawFinalMessage {
                    await onStreamedText(finalMessage)
                }

                if !allChangedPaths.isEmpty {
                    AppProjectStore.shared.touchProjectUpdatedAt(projectURL: projectURL)
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
                    threadMemoryUpdate: nil,
                    requestTokenUsage: await usageAccumulator.usage,
                    toolActivitySummary: toolActivityLog.isEmpty ? nil : toolActivityLog.joined(separator: "\n"),
                    toolMetadata: allToolMetadata
                )
            }

            // Has tool calls — execute them
            if !responseText.isEmpty {
                accumulatedText += (accumulatedText.isEmpty ? "" : "\n\n") + responseText
                if let onStreamedText {
                    await onStreamedText(accumulatedText)
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
                        mergeChangedPaths(result.changedPaths, into: &allChangedPaths)
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
                    debugLog("[Doufu Agent] exceeded maximum total tool calls, stopping")
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
                    mergeChangedPaths(result.changedPaths, into: &allChangedPaths)
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

            debugLog("[Doufu Agent] iteration \(iteration + 1): \(response.toolCalls.count) tool calls executed, \(allChangedPaths.count) files changed total")
        }

        // Max iterations reached
        let rawMaxMessage = accumulatedText.isEmpty
            ? "已达到最大执行步骤数。请再发一条消息继续。"
            : accumulatedText + "\n\n（已达到最大执行步骤数）"
        let (maxModelMemoryUpdate, cleanedMaxMessage) = extractMemoryUpdate(from: rawMaxMessage)
        let finalMessage = cleanedMaxMessage

        if !allChangedPaths.isEmpty {
            AppProjectStore.shared.touchProjectUpdatedAt(projectURL: projectURL)
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
            threadMemoryUpdate: nil,
            requestTokenUsage: await usageAccumulator.usage,
            toolActivitySummary: toolActivityLog.isEmpty ? nil : toolActivityLog.joined(separator: "\n"),
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

    private func readAgentsMarkdown(projectURL: URL) -> String? {
        let agentsURL = projectURL.appendingPathComponent("AGENTS.md")
        guard FileManager.default.fileExists(atPath: agentsURL.path),
              let content = try? String(contentsOf: agentsURL, encoding: .utf8),
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }
        return content
    }

    private func readDoufuMarkdown(projectURL: URL) -> String? {
        let doufuURL = projectURL.appendingPathComponent("DOUFU.MD")
        guard FileManager.default.fileExists(atPath: doufuURL.path),
              let content = try? String(contentsOf: doufuURL, encoding: .utf8),
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }
        return content
    }

    private func createCheckpointBeforeAgentLoop(projectURL: URL, userMessage: String) {
        do {
            try gitService.ensureRepository(at: projectURL)
            try gitService.createCheckpoint(projectURL: projectURL, userMessage: userMessage)
        } catch {
            debugLog("[Doufu Agent] git checkpoint failed: \(error.localizedDescription)")
        }
    }

    private func truncateToolResult(_ output: String) -> String {
        guard output.count > configuration.maxToolResultCharacters else { return output }
        return String(output.prefix(configuration.maxToolResultCharacters))
            + "\n\n[Output truncated at \(configuration.maxToolResultCharacters) characters]"
    }

    /// Compact the conversation when it approaches the model's context window.
    ///
    /// The budget is derived from the active model's known context window size
    /// (via `ProjectChatConfiguration.maxConversationCharacters`), keeping a
    /// safety margin for the system prompt and the next response.
    ///
    /// Compaction proceeds in four passes, each increasingly aggressive:
    /// 1. Compact re-readable tool results (read_file, list_directory) — model can re-read.
    /// 2. Compact search tool results — re-search is costlier but still possible.
    /// 3. Compact all remaining large non-error tool results.
    /// 4. Drop the oldest conversation turns (preserving the most recent N items).
    private func compactConversationIfNeeded(
        _ conversation: inout [AgentConversationItem],
        credential: ProjectChatService.ProviderCredential
    ) {
        let maxConversationChars = configuration.maxConversationCharacters(
            contextWindowTokens: credential.profile.contextWindowTokens
        )

        var totalChars = conversationCharacterCount(conversation)
        guard totalChars > maxConversationChars else { return }

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
        ProjectPathResolver.mergeChangedPaths(paths, into: &target)
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

    private func debugLog(_ message: @autoclosure () -> String) {
#if DEBUG
        print(message())
#endif
    }
}
