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
        onStreamedText: (@MainActor (String) -> Void)? = nil,
        onProgress: (@MainActor (String) -> Void)? = nil
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
        let historyItems = memoryManager.buildHistoryInputMessages(from: normalizedHistory)
        for (index, item) in historyItems.enumerated() {
            let role = item.role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let text = item.content.map(\.text).joined(separator: "\n")
            if role == "user" {
                conversation.append(.userMessage(text))
            } else if role == "assistant" {
                // Find the matching history turn to get tool summary
                let matchingTurn = normalizedHistory.first(where: { turn in
                    turn.role == .assistant && turn.text.trimmingCharacters(in: .whitespacesAndNewlines) == text.trimmingCharacters(in: .whitespacesAndNewlines)
                })
                var assistantText = text
                if let summary = matchingTurn?.toolSummary, !summary.isEmpty {
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
        var accumulatedText = ""
        var totalToolCalls = 0
        var toolActivityLog: [String] = []

        if let onProgress {
            await onProgress("正在思考...")
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

            compactConversationIfNeeded(&conversation)

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
                    toolActivitySummary: toolActivityLog.isEmpty ? nil : toolActivityLog.joined(separator: "\n")
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
            let readOnlyTools: Set<String> = ["read_file", "list_directory", "search_files", "grep_files", "glob_files"]
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
                if let onProgress {
                    await onProgress(toolDescription)
                }
                toolActivityLog.append(toolDescription)

                let result = await toolProvider.execute(toolCall: toolCall)

                // Track changed paths
                if !result.changedPaths.isEmpty {
                    mergeChangedPaths(result.changedPaths, into: &allChangedPaths)
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
            toolActivitySummary: toolActivityLog.isEmpty ? nil : toolActivityLog.joined(separator: "\n")
        )
    }

    // MARK: - Helpers

    private func describeToolCall(_ toolCall: AgentToolCall) -> String {
        let args = toolCall.decodedArguments() ?? [:]
        let path = args["path"] as? String

        switch toolCall.name {
        case "read_file":
            return "读取文件：\(path ?? "?")"
        case "write_file":
            return "写入文件：\(path ?? "?")"
        case "edit_file":
            let editsCount = (args["edits"] as? [Any])?.count ?? 0
            return "编辑文件：\(path ?? "?")（\(editsCount) 处修改）"
        case "delete_file":
            return "删除文件：\(path ?? "?")"
        case "move_file":
            let source = args["source"] as? String ?? "?"
            let dest = args["destination"] as? String ?? "?"
            return "移动文件：\(source) → \(dest)"
        case "revert_file":
            return "还原文件：\(path ?? "?")"
        case "list_directory":
            return "浏览目录：\(path ?? ".")"
        case "search_files":
            let query = args["query"] as? String ?? "?"
            return "搜索文件：\"\(query)\""
        case "grep_files":
            let pattern = args["pattern"] as? String ?? "?"
            return "正则搜索：/\(pattern)/"
        case "glob_files":
            let pattern = args["pattern"] as? String ?? "?"
            return "查找文件：\(pattern)"
        case "web_search":
            let query = args["query"] as? String ?? "?"
            return "搜索网页：\"\(query)\""
        case "web_fetch":
            let url = args["url"] as? String ?? "?"
            return "获取网页：\(url)"
        default:
            return "执行工具：\(toolCall.name)"
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

    /// Estimate the conversation size in characters (rough proxy for tokens).
    /// When the conversation is too large, compact old tool results to keep
    /// the context within reasonable bounds.
    ///
    /// Compaction strategy varies by tool type:
    /// - read_file / list_directory: aggressively compacted (model can re-read)
    /// - search_files / grep_files / glob_files / web_search: moderately compacted (re-search is expensive)
    /// - error results: preserved as-is (diagnostic info is important)
    private func compactConversationIfNeeded(_ conversation: inout [AgentConversationItem]) {
        let totalChars = conversation.reduce(0) { sum, item in
            switch item {
            case let .userMessage(text): return sum + text.count
            case let .assistantMessage(text, toolCalls):
                return sum + text.count + toolCalls.reduce(0) { $0 + $1.argumentsJSON.count }
            case let .toolResult(_, _, content, _): return sum + content.count
            }
        }

        // ~4 chars per token, target ~100k tokens → ~400k chars
        let maxConversationChars = 400_000
        guard totalChars > maxConversationChars else { return }

        let reReadableTools: Set<String> = ["read_file", "list_directory"]
        let searchTools: Set<String> = ["search_files", "grep_files", "glob_files", "web_search", "web_fetch"]

        // Pass 1: aggressively compact re-readable tool results (model can re-read)
        var excess = totalChars - maxConversationChars
        for i in conversation.indices {
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
        for i in conversation.indices {
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
        for i in conversation.indices {
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
        onProgress: (@MainActor (String) -> Void)?,
        toolActivityLog: inout [String]
    ) async -> [(AgentToolCall, AgentToolProvider.ToolExecutionResult)] {
        // Log activity for all calls first
        for call in calls {
            totalToolCalls += 1
            let description = describeToolCall(call)
            toolActivityLog.append(description)
        }

        if let onProgress {
            let summary = calls.count == 1
                ? describeToolCall(calls[0])
                : "并行执行 \(calls.count) 个读取操作..."
            await onProgress(summary)
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
