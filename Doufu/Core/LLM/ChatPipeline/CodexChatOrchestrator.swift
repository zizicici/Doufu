//
//  CodexChatOrchestrator.swift
//  Doufu
//
//  Created by Codex on 2026/03/05.
//

import Foundation

final class CodexChatOrchestrator {
    private let configuration: CodexChatConfiguration
    private let scanner: ProjectFileScanner
    private let memoryManager: SessionMemoryManager
    private let promptBuilder: PromptBuilder
    private let streamingClient: LLMStreamingClient
    private let patchApplicator: PatchApplicator
    private let jsonDecoder = JSONDecoder()

    init(
        configuration: CodexChatConfiguration,
        scanner: ProjectFileScanner? = nil,
        memoryManager: SessionMemoryManager? = nil,
        promptBuilder: PromptBuilder? = nil,
        streamingClient: LLMStreamingClient? = nil,
        patchApplicator: PatchApplicator? = nil
    ) {
        self.configuration = configuration
        self.scanner = scanner ?? ProjectFileScanner(configuration: configuration)
        self.memoryManager = memoryManager ?? SessionMemoryManager(configuration: configuration)
        self.promptBuilder = promptBuilder ?? PromptBuilder(configuration: configuration)
        self.streamingClient = streamingClient ?? LLMStreamingClient(configuration: configuration)
        self.patchApplicator = patchApplicator ?? PatchApplicator()
    }

    func sendAndApply(
        userMessage: String,
        history: [CodexProjectChatService.ChatTurn],
        projectURL: URL,
        credential: CodexProjectChatService.ProviderCredential,
        memory: CodexProjectChatService.SessionMemory? = nil,
        threadContext: CodexProjectChatService.ThreadContext?,
        reasoningEffort: CodexProjectChatService.ReasoningEffort,
        onStreamedText: (@MainActor (String) -> Void)? = nil,
        onProgress: (@MainActor (String) -> Void)? = nil
    ) async throws -> CodexProjectChatService.ResultPayload {
        let trimmedMessage = userMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMessage.isEmpty else {
            throw CodexProjectChatService.ServiceError.invalidResponse
        }

        if let onProgress {
            await onProgress("正在扫描项目文件...")
        }

        var fileCandidates = try scanner.collectProjectFileCandidates(
            from: projectURL,
            activeThreadMemoryPath: threadContext?.memoryFilePath
        )
        let normalizedHistory = memoryManager.normalizedHistoryTurns(history, excludingLatestUserMessage: trimmedMessage)
        let requestMemory = memoryManager.buildRequestMemory(base: memory, latestUserMessage: trimmedMessage)
        let historyItems = memoryManager.buildHistoryInputMessages(from: normalizedHistory)
        let requestReasoningEffort = mapReasoningEffort(reasoningEffort)

        if let onProgress {
            await onProgress("正在决定执行策略...")
        }
        let executionRoute = try await resolveExecutionRouteOrFallback(
            userMessage: trimmedMessage,
            historyItems: historyItems,
            memory: requestMemory,
            fileCandidates: fileCandidates,
            threadContext: threadContext,
            credential: credential,
            reasoningEffort: requestReasoningEffort
        )

        if executionRoute == .singlePass {
            return try await sendAndApplySinglePass(
                userMessage: trimmedMessage,
                historyItems: historyItems,
                fileCandidates: fileCandidates,
                projectURL: projectURL,
                credential: credential,
                requestMemory: requestMemory,
                threadContext: threadContext,
                reasoningEffort: requestReasoningEffort,
                onStreamedText: onStreamedText,
                onProgress: onProgress
            )
        }

        if let onProgress {
            await onProgress("正在规划执行步骤...")
        }

        let taskPlan = try await resolveTaskPlanOrFallback(
            userMessage: trimmedMessage,
            historyItems: historyItems,
            memory: requestMemory,
            fileCandidates: fileCandidates,
            threadContext: threadContext,
            credential: credential,
            reasoningEffort: requestReasoningEffort
        )

        var allChangedPaths: [String] = []
        var currentMemory = requestMemory
        var taskMessages: [String] = []
        var latestThreadMemoryUpdate: CodexProjectChatService.ThreadMemoryUpdate?

        for (index, task) in taskPlan.tasks.enumerated() {
            let stepNumber = index + 1
            let totalSteps = taskPlan.tasks.count
            let taskRequestText = memoryManager.buildTaskRequestText(
                originalUserMessage: trimmedMessage,
                task: task,
                stepNumber: stepNumber,
                totalSteps: totalSteps
            )

            if let onProgress {
                await onProgress("正在执行任务 \(stepNumber)/\(totalSteps)：\(task.title)")
            }

            do {
                let selectedPaths = try await resolveSelectedPathsOrFallback(
                    userMessage: taskRequestText,
                    historyItems: historyItems,
                    memory: currentMemory,
                    fileCandidates: fileCandidates,
                    threadContext: threadContext,
                    credential: credential,
                    reasoningEffort: requestReasoningEffort
                )

                let snapshots = scanner.buildContextSnapshots(
                    from: fileCandidates,
                    selectedPaths: Array(selectedPaths.prefix(configuration.maxFilesPerTaskContext)),
                    maxFiles: configuration.maxFilesPerTaskContext
                )
                let filesJSON = try scanner.encodeFileSnapshotsToJSONString(snapshots)

                if let onProgress {
                    await onProgress("正在生成任务 \(stepNumber)/\(totalSteps) 的改动...")
                }

                let responseText = try await requestPatchResponseStreaming(
                    userMessage: taskRequestText,
                    historyItems: historyItems,
                    memory: currentMemory,
                    filesJSON: filesJSON,
                    threadContext: threadContext,
                    credential: credential,
                    reasoningEffort: requestReasoningEffort,
                    onStreamedText: onStreamedText
                )
                let patch = try parsePatchPayload(from: responseText)
                if let normalizedThreadMemoryUpdate = normalizedThreadMemoryUpdate(from: patch) {
                    latestThreadMemoryUpdate = normalizedThreadMemoryUpdate
                }

                if let onProgress {
                    await onProgress("正在应用任务 \(stepNumber)/\(totalSteps) 的改动...")
                }

                let changedPaths = try patchApplicator.applyPatchPayload(patch, to: projectURL)
                if !changedPaths.isEmpty {
                    AppProjectStore.shared.touchProjectUpdatedAt(projectURL: projectURL)
                    memoryManager.mergeChangedPaths(changedPaths, into: &allChangedPaths)
                    do {
                        fileCandidates = try scanner.collectProjectFileCandidates(
                            from: projectURL,
                            activeThreadMemoryPath: threadContext?.memoryFilePath
                        )
                    } catch {
                        debugLog("[DoufuCodexChat Debug] file candidate refresh failed, continue with previous snapshot. error=\(error.localizedDescription)")
                    }
                }

                let message = patch.assistantMessage.trimmingCharacters(in: .whitespacesAndNewlines)
                let normalizedMessage = message.isEmpty ? "已完成更新。" : message
                taskMessages.append("任务\(stepNumber)「\(task.title)」：\(normalizedMessage)")

                currentMemory = memoryManager.buildRolledMemory(
                    current: currentMemory,
                    userMessage: taskRequestText,
                    assistantMessage: normalizedMessage,
                    changedPaths: changedPaths,
                    modelMemoryUpdate: patch.memoryUpdate
                )
                currentMemory = memoryManager.rollTodoFromRemainingTasks(
                    memory: currentMemory,
                    remainingTasks: Array(taskPlan.tasks.suffix(totalSteps - stepNumber))
                )
            } catch {
                let failureDescription = error.localizedDescription
                let normalizedFailure = failureDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "未知错误"
                    : failureDescription

                if !allChangedPaths.isEmpty {
                    createAutoSnapshotIfNeeded(projectURL: projectURL, changedPaths: allChangedPaths)
                    let partialSummary = """
                    已完成 \(stepNumber - 1)/\(taskPlan.tasks.count) 个任务，当前任务「\(task.title)」失败：\(normalizedFailure)。
                    之前任务的改动已保留。请重试以继续后续任务。
                    """
                    currentMemory = memoryManager.rollTodoFromRemainingTasks(
                        memory: currentMemory,
                        remainingTasks: Array(taskPlan.tasks.suffix(taskPlan.tasks.count - (stepNumber - 1)))
                    )
                    return CodexProjectChatService.ResultPayload(
                        assistantMessage: partialSummary,
                        changedPaths: allChangedPaths,
                        updatedMemory: currentMemory,
                        threadMemoryUpdate: latestThreadMemoryUpdate
                    )
                }
                throw error
            }
        }

        let finalMessage = buildFinalAssistantMessage(
            taskPlanSummary: taskPlan.summary,
            taskMessages: taskMessages
        )
        createAutoSnapshotIfNeeded(projectURL: projectURL, changedPaths: allChangedPaths)
        return CodexProjectChatService.ResultPayload(
            assistantMessage: finalMessage,
            changedPaths: allChangedPaths,
            updatedMemory: currentMemory,
            threadMemoryUpdate: latestThreadMemoryUpdate
        )
    }

    private func sendAndApplySinglePass(
        userMessage: String,
        historyItems: [ResponseInputMessage],
        fileCandidates: [ProjectFileCandidate],
        projectURL: URL,
        credential: CodexProjectChatService.ProviderCredential,
        requestMemory: CodexProjectChatService.SessionMemory,
        threadContext: CodexProjectChatService.ThreadContext?,
        reasoningEffort: ResponsesReasoning.Effort,
        onStreamedText: (@MainActor (String) -> Void)?,
        onProgress: (@MainActor (String) -> Void)?
    ) async throws -> CodexProjectChatService.ResultPayload {
        if let onProgress {
            await onProgress("正在快速生成改动...")
        }

        let selectedPaths = scanner.fallbackSelectionPaths(from: fileCandidates, userMessage: userMessage)
        let snapshots = scanner.buildContextSnapshots(
            from: fileCandidates,
            selectedPaths: Array(selectedPaths.prefix(configuration.singlePassContextFileLimit)),
            maxFiles: configuration.singlePassContextFileLimit
        )
        let filesJSON = try scanner.encodeFileSnapshotsToJSONString(snapshots)

        let responseText = try await requestPatchResponseStreaming(
            userMessage: userMessage,
            historyItems: historyItems,
            memory: requestMemory,
            filesJSON: filesJSON,
            threadContext: threadContext,
            credential: credential,
            reasoningEffort: reasoningEffort,
            onStreamedText: onStreamedText
        )
        let patch = try parsePatchPayload(from: responseText)

        if let onProgress {
            await onProgress("正在应用改动...")
        }

        let changedPaths = try patchApplicator.applyPatchPayload(patch, to: projectURL)
        if !changedPaths.isEmpty {
            AppProjectStore.shared.touchProjectUpdatedAt(projectURL: projectURL)
            createAutoSnapshotIfNeeded(projectURL: projectURL, changedPaths: changedPaths)
        }

        let message = patch.assistantMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedMessage = message.isEmpty ? "已完成更新。" : message
        let updatedMemory = memoryManager.buildRolledMemory(
            current: requestMemory,
            userMessage: userMessage,
            assistantMessage: normalizedMessage,
            changedPaths: changedPaths,
            modelMemoryUpdate: patch.memoryUpdate
        )

        return CodexProjectChatService.ResultPayload(
            assistantMessage: normalizedMessage,
            changedPaths: changedPaths,
            updatedMemory: updatedMemory,
            threadMemoryUpdate: normalizedThreadMemoryUpdate(from: patch)
        )
    }

    private func requestExecutionRoute(
        userMessage: String,
        historyItems: [ResponseInputMessage],
        memory: CodexProjectChatService.SessionMemory,
        fileCandidates: [ProjectFileCandidate],
        threadContext: CodexProjectChatService.ThreadContext?,
        credential: CodexProjectChatService.ProviderCredential,
        reasoningEffort: ResponsesReasoning.Effort
    ) async throws -> ExecutionRouteMode {
        let fileCatalogJSON = try scanner.encodeFileCatalogToJSONString(fileCandidates)
        let developerInstruction = promptBuilder.executionRouteDeveloperInstruction()
        let memoryJSON = memoryManager.encodeMemoryToJSONString(memory)
        let userPrompt = promptBuilder.executionRouteUserPrompt(
            userMessage: userMessage,
            memoryJSON: memoryJSON,
            fileCatalogJSON: fileCatalogJSON,
            threadContext: threadContext
        )

        var inputItems = historyItems
        inputItems.append(ResponseInputMessage(role: "user", text: userPrompt))
        let responseText = try await streamingClient.requestModelResponseStreaming(
            requestLabel: "route_execution_mode",
            model: configuration.model,
            developerInstruction: developerInstruction,
            inputItems: inputItems,
            credential: credential,
            initialReasoningEffort: reasoningEffort,
            responseFormat: promptBuilder.executionRouteResponseTextFormat(),
            onStreamedText: nil
        )
        let payload = try parseExecutionRoutePayload(from: responseText)
        return payload.mode
    }

    private func requestPatchResponseStreaming(
        userMessage: String,
        historyItems: [ResponseInputMessage],
        memory: CodexProjectChatService.SessionMemory,
        filesJSON: String,
        threadContext: CodexProjectChatService.ThreadContext?,
        credential: CodexProjectChatService.ProviderCredential,
        reasoningEffort: ResponsesReasoning.Effort,
        onStreamedText: (@MainActor (String) -> Void)?
    ) async throws -> String {
        let developerInstruction = promptBuilder.patchDeveloperInstruction()
        let memoryJSON = memoryManager.encodeMemoryToJSONString(memory)
        let userPrompt = promptBuilder.patchUserPrompt(
            memoryJSON: memoryJSON,
            filesJSON: filesJSON,
            userMessage: userMessage,
            threadContext: threadContext
        )

        var inputItems = historyItems
        inputItems.append(ResponseInputMessage(role: "user", text: userPrompt))

        return try await streamingClient.requestModelResponseStreaming(
            requestLabel: "generate_patch",
            model: configuration.model,
            developerInstruction: developerInstruction,
            inputItems: inputItems,
            credential: credential,
            initialReasoningEffort: reasoningEffort,
            responseFormat: promptBuilder.patchResponseTextFormat(),
            onStreamedText: onStreamedText
        )
    }

    private func requestSelectedPaths(
        userMessage: String,
        historyItems: [ResponseInputMessage],
        memory: CodexProjectChatService.SessionMemory,
        fileCandidates: [ProjectFileCandidate],
        threadContext: CodexProjectChatService.ThreadContext?,
        credential: CodexProjectChatService.ProviderCredential,
        reasoningEffort: ResponsesReasoning.Effort
    ) async throws -> [String] {
        let fileCatalogJSON = try scanner.encodeFileCatalogToJSONString(fileCandidates)
        let developerInstruction = promptBuilder.fileSelectionDeveloperInstruction()
        let memoryJSON = memoryManager.encodeMemoryToJSONString(memory)
        let userPrompt = promptBuilder.fileSelectionUserPrompt(
            userMessage: userMessage,
            memoryJSON: memoryJSON,
            fileCatalogJSON: fileCatalogJSON,
            threadContext: threadContext
        )

        var inputItems = historyItems
        inputItems.append(ResponseInputMessage(role: "user", text: userPrompt))

        let responseText = try await streamingClient.requestModelResponseStreaming(
            requestLabel: "select_context_files",
            model: configuration.model,
            developerInstruction: developerInstruction,
            inputItems: inputItems,
            credential: credential,
            initialReasoningEffort: reasoningEffort,
            responseFormat: promptBuilder.fileSelectionResponseTextFormat(),
            onStreamedText: nil
        )
        let payload = try parseFileSelectionPayload(from: responseText)
        return scanner.sanitizeSelectedPaths(payload.selectedPaths, fileCandidates: fileCandidates)
    }

    private func requestTaskPlan(
        userMessage: String,
        historyItems: [ResponseInputMessage],
        memory: CodexProjectChatService.SessionMemory,
        fileCandidates: [ProjectFileCandidate],
        threadContext: CodexProjectChatService.ThreadContext?,
        credential: CodexProjectChatService.ProviderCredential,
        reasoningEffort: ResponsesReasoning.Effort
    ) async throws -> TaskPlan {
        let filePathListJSON = try scanner.encodeFilePathListToJSONString(fileCandidates)
        let developerInstruction = promptBuilder.taskPlanDeveloperInstruction()
        let memoryJSON = memoryManager.encodeMemoryToJSONString(memory)
        let userPrompt = promptBuilder.taskPlanUserPrompt(
            userMessage: userMessage,
            memoryJSON: memoryJSON,
            filePathListJSON: filePathListJSON,
            threadContext: threadContext
        )

        var inputItems = historyItems
        inputItems.append(ResponseInputMessage(role: "user", text: userPrompt))

        let responseText = try await streamingClient.requestModelResponseStreaming(
            requestLabel: "plan_tasks",
            model: configuration.model,
            developerInstruction: developerInstruction,
            inputItems: inputItems,
            credential: credential,
            initialReasoningEffort: reasoningEffort,
            responseFormat: promptBuilder.taskPlanResponseTextFormat(),
            onStreamedText: nil
        )

        let payload = try parseTaskPlanPayload(from: responseText)
        let sanitizedTasks = sanitizeTaskPlanItems(payload.tasks)
        guard !sanitizedTasks.isEmpty else {
            throw CodexProjectChatService.ServiceError.invalidResponse
        }
        let summary = normalizedTaskItem(payload.summary, maxCharacters: configuration.maxTaskGoalCharacters) ?? "按步骤执行用户请求。"
        return TaskPlan(summary: summary, tasks: sanitizedTasks)
    }

    private func resolveExecutionRouteOrFallback(
        userMessage: String,
        historyItems: [ResponseInputMessage],
        memory: CodexProjectChatService.SessionMemory,
        fileCandidates: [ProjectFileCandidate],
        threadContext: CodexProjectChatService.ThreadContext?,
        credential: CodexProjectChatService.ProviderCredential,
        reasoningEffort: ResponsesReasoning.Effort
    ) async throws -> ExecutionRouteMode {
        do {
            return try await requestExecutionRoute(
                userMessage: userMessage,
                historyItems: historyItems,
                memory: memory,
                fileCandidates: fileCandidates,
                threadContext: threadContext,
                credential: credential,
                reasoningEffort: reasoningEffort
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            debugLog("[DoufuCodexChat Debug] execution route failed, fallback to multi_task. error=\(error.localizedDescription)")
            return .multiTask
        }
    }

    private func resolveTaskPlanOrFallback(
        userMessage: String,
        historyItems: [ResponseInputMessage],
        memory: CodexProjectChatService.SessionMemory,
        fileCandidates: [ProjectFileCandidate],
        threadContext: CodexProjectChatService.ThreadContext?,
        credential: CodexProjectChatService.ProviderCredential,
        reasoningEffort: ResponsesReasoning.Effort
    ) async throws -> TaskPlan {
        do {
            return try await requestTaskPlan(
                userMessage: userMessage,
                historyItems: historyItems,
                memory: memory,
                fileCandidates: fileCandidates,
                threadContext: threadContext,
                credential: credential,
                reasoningEffort: reasoningEffort
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            debugLog("[DoufuCodexChat Debug] task planning failed, fallback single task. error=\(error.localizedDescription)")
            let fallbackTitle = normalizedTaskItem("执行用户请求", maxCharacters: configuration.maxTaskTitleCharacters) ?? "执行请求"
            let fallbackGoal = normalizedTaskItem(userMessage, maxCharacters: configuration.maxTaskGoalCharacters) ?? userMessage
            return TaskPlan(
                summary: "单任务执行用户请求。",
                tasks: [TaskPlanItem(title: fallbackTitle, goal: fallbackGoal)]
            )
        }
    }

    private func sanitizeTaskPlanItems(_ items: [TaskPlanItem]) -> [TaskPlanItem] {
        var output: [TaskPlanItem] = []
        var seen = Set<String>()

        for item in items {
            let title = normalizedTaskItem(item.title, maxCharacters: configuration.maxTaskTitleCharacters) ?? ""
            let goal = normalizedTaskItem(item.goal, maxCharacters: configuration.maxTaskGoalCharacters) ?? ""
            guard !goal.isEmpty else {
                continue
            }

            let normalizedTitle = title.isEmpty ? "任务\(output.count + 1)" : title
            let dedupeKey = "\(normalizedTitle.lowercased())|\(goal.lowercased())"
            guard seen.insert(dedupeKey).inserted else {
                continue
            }

            output.append(TaskPlanItem(title: normalizedTitle, goal: goal))
            if output.count >= configuration.maxPlannedTasks {
                break
            }
        }
        return output
    }

    private func resolveSelectedPathsOrFallback(
        userMessage: String,
        historyItems: [ResponseInputMessage],
        memory: CodexProjectChatService.SessionMemory,
        fileCandidates: [ProjectFileCandidate],
        threadContext: CodexProjectChatService.ThreadContext?,
        credential: CodexProjectChatService.ProviderCredential,
        reasoningEffort: ResponsesReasoning.Effort
    ) async throws -> [String] {
        do {
            let selected = try await requestSelectedPaths(
                userMessage: userMessage,
                historyItems: historyItems,
                memory: memory,
                fileCandidates: fileCandidates,
                threadContext: threadContext,
                credential: credential,
                reasoningEffort: reasoningEffort
            )
            if !selected.isEmpty {
                return selected
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            debugLog("[DoufuCodexChat Debug] context selection failed, fallback to heuristics. error=\(error.localizedDescription)")
        }

        return scanner.fallbackSelectionPaths(from: fileCandidates, userMessage: userMessage)
    }

    private func parsePatchPayload(from responseText: String) throws -> PatchPayload {
        let trimmed = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CodexProjectChatService.ServiceError.invalidPatchJSON
        }

        let jsonString = extractJSONObject(from: trimmed) ?? trimmed
        guard let data = jsonString.data(using: .utf8) else {
            throw CodexProjectChatService.ServiceError.invalidPatchJSON
        }

        do {
            return try jsonDecoder.decode(PatchPayload.self, from: data)
        } catch {
            throw CodexProjectChatService.ServiceError.invalidPatchJSON
        }
    }

    private func parseExecutionRoutePayload(from responseText: String) throws -> ExecutionRoutePayload {
        let trimmed = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CodexProjectChatService.ServiceError.invalidResponse
        }

        let jsonString = extractJSONObject(from: trimmed) ?? trimmed
        guard let data = jsonString.data(using: .utf8) else {
            throw CodexProjectChatService.ServiceError.invalidResponse
        }

        do {
            return try jsonDecoder.decode(ExecutionRoutePayload.self, from: data)
        } catch {
            throw CodexProjectChatService.ServiceError.invalidResponse
        }
    }

    private func parseFileSelectionPayload(from responseText: String) throws -> FileSelectionPayload {
        let trimmed = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CodexProjectChatService.ServiceError.invalidResponse
        }

        let jsonString = extractJSONObject(from: trimmed) ?? trimmed
        guard let data = jsonString.data(using: .utf8) else {
            throw CodexProjectChatService.ServiceError.invalidResponse
        }

        do {
            return try jsonDecoder.decode(FileSelectionPayload.self, from: data)
        } catch {
            throw CodexProjectChatService.ServiceError.invalidResponse
        }
    }

    private func parseTaskPlanPayload(from responseText: String) throws -> TaskPlanPayload {
        let trimmed = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CodexProjectChatService.ServiceError.invalidResponse
        }

        let jsonString = extractJSONObject(from: trimmed) ?? trimmed
        guard let data = jsonString.data(using: .utf8) else {
            throw CodexProjectChatService.ServiceError.invalidResponse
        }

        do {
            return try jsonDecoder.decode(TaskPlanPayload.self, from: data)
        } catch {
            throw CodexProjectChatService.ServiceError.invalidResponse
        }
    }

    private func normalizedThreadMemoryUpdate(from patch: PatchPayload) -> CodexProjectChatService.ThreadMemoryUpdate? {
        guard let patchUpdate = patch.threadMemoryUpdate else {
            return nil
        }

        let contentMarkdown = patchUpdate.contentMarkdown?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !contentMarkdown.isEmpty else {
            return nil
        }

        let nextVersionSummary = normalizedTaskItem(
            patchUpdate.nextVersionSummary,
            maxCharacters: configuration.maxHistorySummaryCharacters
        )
        let nextVersionContentMarkdown = patchUpdate.nextVersionContentMarkdown?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return CodexProjectChatService.ThreadMemoryUpdate(
            contentMarkdown: contentMarkdown,
            shouldRollOver: patchUpdate.shouldRollOver,
            nextVersionSummary: nextVersionSummary,
            nextVersionContentMarkdown: nextVersionContentMarkdown
        )
    }

    private func extractJSONObject(from rawText: String) -> String? {
        guard let firstBrace = rawText.firstIndex(of: "{"), let lastBrace = rawText.lastIndex(of: "}") else {
            return nil
        }
        guard firstBrace <= lastBrace else {
            return nil
        }
        return String(rawText[firstBrace ... lastBrace])
    }

    private func mapReasoningEffort(_ effort: CodexProjectChatService.ReasoningEffort) -> ResponsesReasoning.Effort {
        switch effort {
        case .low:
            return .low
        case .medium:
            return .medium
        case .high:
            return .high
        case .xhigh:
            return .xhigh
        }
    }

    private func createAutoSnapshotIfNeeded(projectURL: URL, changedPaths: [String]) {
        guard !changedPaths.isEmpty else {
            return
        }
        do {
            try AppProjectStore.shared.createSnapshot(projectURL: projectURL, kind: .auto)
        } catch {
            debugLog("[DoufuCodexChat Debug] auto snapshot failed: \(error.localizedDescription)")
        }
    }

    private func buildFinalAssistantMessage(
        taskPlanSummary: String,
        taskMessages: [String]
    ) -> String {
        let normalizedSummary = taskPlanSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedTaskMessages = taskMessages
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if normalizedTaskMessages.isEmpty {
            return normalizedSummary.isEmpty ? "已完成更新。" : normalizedSummary
        }

        if normalizedSummary.isEmpty {
            return normalizedTaskMessages.joined(separator: "\n")
        }
        return normalizedSummary + "\n\n" + normalizedTaskMessages.joined(separator: "\n")
    }

    private func normalizedTaskItem(_ text: String?, maxCharacters: Int) -> String? {
        guard let text else {
            return nil
        }
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return nil
        }
        guard normalized.count > maxCharacters else {
            return normalized
        }
        return String(normalized.prefix(maxCharacters)) + "..."
    }

    private func debugLog(_ message: @autoclosure () -> String) {
#if DEBUG
        print(message())
#endif
    }
}
