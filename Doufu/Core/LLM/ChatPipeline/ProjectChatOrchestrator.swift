//
//  ProjectChatOrchestrator.swift
//  Doufu
//
//  Created by Codex on 2026/03/05.
//

import Foundation

final class ProjectChatOrchestrator {
    private final class UsageAccumulator {
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

        // Read AGENTS.md if present
        let agentsMarkdown = readAgentsMarkdown(projectURL: projectURL)

        // Build system prompt
        let systemPrompt = promptBuilder.agentSystemPrompt(
            threadContext: threadContext,
            agentsMarkdown: agentsMarkdown
        )

        // Build initial conversation
        var conversation: [AgentConversationItem] = []

        // Add history turns
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

        if let onProgress {
            await onProgress("正在思考...")
        }

        for iteration in 0 ..< configuration.maxAgentIterations {
            try Task.checkCancellation()

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

            let response = try await streamingClient.requestWithTools(
                systemInstruction: systemPrompt,
                conversationItems: conversation,
                tools: toolProvider.toolDefinitions(),
                credential: credential,
                projectUsageIdentifier: projectURL.standardizedFileURL.path,
                executionOptions: executionOptions,
                onStreamedText: streamCallback,
                onUsage: { inputTokens, outputTokens in
                    usageAccumulator.record(inputTokens: inputTokens, outputTokens: outputTokens)
                }
            )

            let responseText = response.textContent.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)

            // No tool calls = final response
            if response.toolCalls.isEmpty {
                if !responseText.isEmpty {
                    accumulatedText += (accumulatedText.isEmpty ? "" : "\n\n") + responseText
                }
                if let onStreamedText {
                    await onStreamedText(accumulatedText)
                }

                let finalMessage = accumulatedText.isEmpty ? "已完成。" : accumulatedText

                if !allChangedPaths.isEmpty {
                    AppProjectStore.shared.touchProjectUpdatedAt(projectURL: projectURL)
                }

                let updatedMemory = memoryManager.buildRolledMemory(
                    current: requestMemory,
                    userMessage: trimmedMessage,
                    assistantMessage: finalMessage,
                    changedPaths: allChangedPaths,
                    modelMemoryUpdate: nil
                )

                return ProjectChatService.ResultPayload(
                    assistantMessage: finalMessage,
                    changedPaths: allChangedPaths,
                    updatedMemory: updatedMemory,
                    threadMemoryUpdate: nil,
                    requestTokenUsage: usageAccumulator.usage
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

            // Execute each tool call
            for toolCall in response.toolCalls {
                try Task.checkCancellation()

                totalToolCalls += 1
                if totalToolCalls > configuration.maxAgentIterations * configuration.maxToolCallsPerIteration {
                    debugLog("[Doufu Agent] exceeded maximum total tool calls, stopping")
                    break
                }

                if let onProgress {
                    let description = describeToolCall(toolCall)
                    await onProgress(description)
                }

                let result = await toolProvider.execute(toolCall: toolCall)

                // Track changed paths
                if !result.changedPaths.isEmpty {
                    mergeChangedPaths(result.changedPaths, into: &allChangedPaths)
                }

                // Add tool result to conversation
                conversation.append(.toolResult(
                    callID: toolCall.id,
                    name: toolCall.name,
                    content: result.output,
                    isError: result.isError
                ))
            }

            debugLog("[Doufu Agent] iteration \(iteration + 1): \(response.toolCalls.count) tool calls executed, \(allChangedPaths.count) files changed total")
        }

        // Max iterations reached
        let finalMessage = accumulatedText.isEmpty
            ? "已达到最大执行步骤数。请再发一条消息继续。"
            : accumulatedText + "\n\n（已达到最大执行步骤数）"

        if !allChangedPaths.isEmpty {
            AppProjectStore.shared.touchProjectUpdatedAt(projectURL: projectURL)
        }

        let updatedMemory = memoryManager.buildRolledMemory(
            current: requestMemory,
            userMessage: trimmedMessage,
            assistantMessage: finalMessage,
            changedPaths: allChangedPaths,
            modelMemoryUpdate: nil
        )

        return ProjectChatService.ResultPayload(
            assistantMessage: finalMessage,
            changedPaths: allChangedPaths,
            updatedMemory: updatedMemory,
            threadMemoryUpdate: nil,
            requestTokenUsage: usageAccumulator.usage
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
            let dest = args["destination"] as? String ?? "?"
            return "移动文件：\(path ?? "?") → \(dest)"
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

    private func createCheckpointBeforeAgentLoop(projectURL: URL, userMessage: String) {
        do {
            try gitService.ensureRepository(at: projectURL)
            try gitService.createCheckpoint(projectURL: projectURL, userMessage: userMessage)
        } catch {
            debugLog("[Doufu Agent] git checkpoint failed: \(error.localizedDescription)")
        }
    }

    private func mergeChangedPaths(_ paths: [String], into target: inout [String]) {
        ProjectPathResolver.mergeChangedPaths(paths, into: &target)
    }

    private func debugLog(_ message: @autoclosure () -> String) {
#if DEBUG
        print(message())
#endif
    }
}
