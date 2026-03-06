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
    private let scanner: ProjectFileScanner
    private let memoryManager: SessionMemoryManager
    private let promptBuilder: PromptBuilder
    private let streamingClient: LLMStreamingClient
    private let patchApplicator: PatchApplicator
    private let jsonDecoder = JSONDecoder()

    init(
        configuration: ProjectChatConfiguration,
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
        history: [ProjectChatService.ChatTurn],
        projectURL: URL,
        credential: ProjectChatService.ProviderCredential,
        memory: ProjectChatService.SessionMemory? = nil,
        threadContext: ProjectChatService.ThreadContext?,
        executionOptions: ProjectChatService.ModelExecutionOptions,
        onStreamedText: (@MainActor (String) -> Void)? = nil,
        onProgress: (@MainActor (String) -> Void)? = nil
    ) async throws -> ProjectChatService.ResultPayload {
        let trimmedMessage = userMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMessage.isEmpty else {
            throw ProjectChatService.ServiceError.invalidResponse
        }
        let modelID = resolvedModelID(from: credential)
        let normalizedHistory = memoryManager.normalizedHistoryTurns(history, excludingLatestUserMessage: trimmedMessage)
        let requestMemory = memoryManager.buildRequestMemory(base: memory, latestUserMessage: trimmedMessage)
        let historyItems = memoryManager.buildHistoryInputMessages(from: normalizedHistory)
        let requestReasoningEffort = mapReasoningEffort(executionOptions.reasoningEffort)
        let projectUsageIdentifier = projectURL.standardizedFileURL.path
        let usageAccumulator = UsageAccumulator()
        if let onProgress {
            await onProgress("正在思考...")
        }

        let executionRoute = try await resolveExecutionRouteOrFallback(
            userMessage: trimmedMessage,
            historyItems: historyItems,
            memory: requestMemory,
            threadContext: threadContext,
            credential: credential,
            modelID: modelID,
            reasoningEffort: requestReasoningEffort,
            projectUsageIdentifier: projectUsageIdentifier,
            executionOptions: executionOptions,
            usageAccumulator: usageAccumulator
        )
        if executionRoute.mode == .directAnswer {
            let directAnswerText = normalizedTaskItem(
                executionRoute.assistantMessage,
                maxCharacters: configuration.maxTaskGoalCharacters * 3
            ) ?? normalizedTaskItem(
                executionRoute.reason,
                maxCharacters: configuration.maxTaskGoalCharacters * 2
            ) ?? "我已理解。请继续告诉我你的目标。"

            let updatedMemory = memoryManager.buildRolledMemory(
                current: requestMemory,
                userMessage: trimmedMessage,
                assistantMessage: directAnswerText,
                changedPaths: [],
                modelMemoryUpdate: executionRoute.memoryUpdate
            )

            return ProjectChatService.ResultPayload(
                assistantMessage: directAnswerText,
                changedPaths: [],
                updatedMemory: updatedMemory,
                threadMemoryUpdate: normalizedThreadMemoryUpdate(memoryUpdate: executionRoute.memoryUpdate),
                requestTokenUsage: usageAccumulator.usage
            )
        }

        if let onProgress {
            let routeText = executionRoute.mode == .singlePass ? "单次快速路径" : "多任务路径"
            await onProgress("执行策略：\(routeText)")
        }

        if let onProgress {
            await onProgress("正在扫描项目文件...")
        }
        var fileCandidates = try scanner.collectProjectFileCandidates(
            from: projectURL,
            activeThreadMemoryPath: threadContext?.memoryFilePath
        )

        if executionRoute.mode == .singlePass {
            do {
                let result = try await sendAndApplySinglePass(
                    userMessage: trimmedMessage,
                    historyItems: historyItems,
                    fileCandidates: fileCandidates,
                    projectURL: projectURL,
                    credential: credential,
                    modelID: modelID,
                    requestMemory: requestMemory,
                    threadContext: threadContext,
                    reasoningEffort: requestReasoningEffort,
                    projectUsageIdentifier: projectUsageIdentifier,
                    executionOptions: executionOptions,
                    onStreamedText: onStreamedText,
                    onProgress: onProgress,
                    usageAccumulator: usageAccumulator
                )
                return ProjectChatService.ResultPayload(
                    assistantMessage: result.assistantMessage,
                    changedPaths: result.changedPaths,
                    updatedMemory: result.updatedMemory,
                    threadMemoryUpdate: result.threadMemoryUpdate,
                    requestTokenUsage: usageAccumulator.usage
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard isPatchPayloadFailure(error) else {
                    throw error
                }
                if let onProgress {
                    await onProgress("单次路径补丁解析失败，自动切换多任务拆分执行...")
                }
            }
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
            modelID: modelID,
            reasoningEffort: requestReasoningEffort,
            projectUsageIdentifier: projectUsageIdentifier,
            executionOptions: executionOptions,
            usageAccumulator: usageAccumulator
        )
        if let onProgress {
            let taskLines = taskPlan.tasks.enumerated().map { index, task in
                "\(index + 1). \(task.title)"
            }
            let planSummary = taskLines.joined(separator: "\n")
            await onProgress("执行计划已生成（共 \(taskPlan.tasks.count) 项）：\n\(planSummary)")
        }

        var allChangedPaths: [String] = []
        var currentMemory = requestMemory
        var taskMessages: [String] = []
        var latestThreadMemoryUpdate: ProjectChatService.ThreadMemoryUpdate?

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
                await onProgress("任务 \(stepNumber)/\(totalSteps)：\(task.title)\n目标：\(task.goal)")
            }

            do {
                let selectedPaths = try await resolveSelectedPathsOrFallback(
                    userMessage: taskRequestText,
                    historyItems: historyItems,
                    memory: currentMemory,
                    fileCandidates: fileCandidates,
                    threadContext: threadContext,
                    credential: credential,
                    modelID: modelID,
                    reasoningEffort: requestReasoningEffort,
                    projectUsageIdentifier: projectUsageIdentifier,
                    executionOptions: executionOptions,
                    usageAccumulator: usageAccumulator
                )

                let snapshots = scanner.buildContextSnapshots(
                    from: fileCandidates,
                    selectedPaths: Array(selectedPaths.prefix(configuration.maxFilesPerTaskContext)),
                    maxFiles: configuration.maxFilesPerTaskContext
                )
                let filesJSON = try scanner.encodeFileSnapshotsToJSONString(snapshots)

                if let onProgress {
                    await onProgress("任务 \(stepNumber)/\(totalSteps)「\(task.title)」：正在生成改动...")
                }

                let patch = try await requestPatchPayloadWithRetry(
                    userMessage: taskRequestText,
                    historyItems: historyItems,
                    memory: currentMemory,
                    filesJSON: filesJSON,
                    threadContext: threadContext,
                    credential: credential,
                    modelID: modelID,
                    reasoningEffort: requestReasoningEffort,
                    projectUsageIdentifier: projectUsageIdentifier,
                    executionOptions: executionOptions,
                    onStreamedText: onStreamedText,
                    onProgress: onProgress,
                    usageAccumulator: usageAccumulator
                )
                if let normalizedThreadMemoryUpdate = normalizedThreadMemoryUpdate(from: patch) {
                    latestThreadMemoryUpdate = normalizedThreadMemoryUpdate
                }

                if let onProgress {
                    await onProgress("任务 \(stepNumber)/\(totalSteps)「\(task.title)」：正在应用改动...")
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
                if let onProgress {
                    let changedCount = changedPaths.count
                    let changedText = changedCount == 0 ? "未产生文件变更" : "更新 \(changedCount) 个文件"
                    await onProgress("任务 \(stepNumber)/\(totalSteps)「\(task.title)」已完成：\(changedText)。")
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
                if isPatchPayloadFailure(error), allChangedPaths.isEmpty {
                    let message = "模型补丁返回过长或格式异常，已自动紧凑重试但仍失败。请将需求拆成更小步骤后重试。"
                    currentMemory = memoryManager.rollTodoFromRemainingTasks(
                        memory: currentMemory,
                        remainingTasks: Array(taskPlan.tasks.suffix(taskPlan.tasks.count - (stepNumber - 1)))
                    )
                    return ProjectChatService.ResultPayload(
                        assistantMessage: message,
                        changedPaths: [],
                        updatedMemory: currentMemory,
                        threadMemoryUpdate: latestThreadMemoryUpdate,
                        requestTokenUsage: usageAccumulator.usage
                    )
                }

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
                    return ProjectChatService.ResultPayload(
                        assistantMessage: partialSummary,
                        changedPaths: allChangedPaths,
                        updatedMemory: currentMemory,
                        threadMemoryUpdate: latestThreadMemoryUpdate,
                        requestTokenUsage: usageAccumulator.usage
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
        return ProjectChatService.ResultPayload(
            assistantMessage: finalMessage,
            changedPaths: allChangedPaths,
            updatedMemory: currentMemory,
            threadMemoryUpdate: latestThreadMemoryUpdate,
            requestTokenUsage: usageAccumulator.usage
        )
    }

    private func sendAndApplySinglePass(
        userMessage: String,
        historyItems: [ResponseInputMessage],
        fileCandidates: [ProjectFileCandidate],
        projectURL: URL,
        credential: ProjectChatService.ProviderCredential,
        modelID: String,
        requestMemory: ProjectChatService.SessionMemory,
        threadContext: ProjectChatService.ThreadContext?,
        reasoningEffort: ResponsesReasoning.Effort,
        projectUsageIdentifier: String,
        executionOptions: ProjectChatService.ModelExecutionOptions,
        onStreamedText: (@MainActor (String) -> Void)?,
        onProgress: (@MainActor (String) -> Void)?,
        usageAccumulator: UsageAccumulator
    ) async throws -> ProjectChatService.ResultPayload {
        if let onProgress {
            await onProgress("单次快速路径：正在生成改动...")
        }

        let selectedPaths = scanner.fallbackSelectionPaths(from: fileCandidates, userMessage: userMessage)
        let snapshots = scanner.buildContextSnapshots(
            from: fileCandidates,
            selectedPaths: Array(selectedPaths.prefix(configuration.singlePassContextFileLimit)),
            maxFiles: configuration.singlePassContextFileLimit
        )
        let filesJSON = try scanner.encodeFileSnapshotsToJSONString(snapshots)

        let patch = try await requestPatchPayloadWithRetry(
            userMessage: userMessage,
            historyItems: historyItems,
            memory: requestMemory,
            filesJSON: filesJSON,
            threadContext: threadContext,
            credential: credential,
            modelID: modelID,
            reasoningEffort: reasoningEffort,
            projectUsageIdentifier: projectUsageIdentifier,
            executionOptions: executionOptions,
            onStreamedText: onStreamedText,
            onProgress: onProgress,
            usageAccumulator: usageAccumulator
        )

        if let onProgress {
            await onProgress("单次快速路径：正在应用改动...")
        }

        let changedPaths = try patchApplicator.applyPatchPayload(patch, to: projectURL)
        if let onProgress {
            let changedCount = changedPaths.count
            let changedText = changedCount == 0 ? "未产生文件变更" : "更新 \(changedCount) 个文件"
            await onProgress("单次快速路径已完成：\(changedText)。")
        }
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

        return ProjectChatService.ResultPayload(
            assistantMessage: normalizedMessage,
            changedPaths: changedPaths,
            updatedMemory: updatedMemory,
            threadMemoryUpdate: normalizedThreadMemoryUpdate(from: patch),
            requestTokenUsage: nil
        )
    }

    private func requestExecutionRoute(
        userMessage: String,
        historyItems: [ResponseInputMessage],
        memory: ProjectChatService.SessionMemory,
        threadContext: ProjectChatService.ThreadContext?,
        credential: ProjectChatService.ProviderCredential,
        modelID: String,
        reasoningEffort: ResponsesReasoning.Effort,
        projectUsageIdentifier: String,
        executionOptions: ProjectChatService.ModelExecutionOptions,
        usageAccumulator: UsageAccumulator
    ) async throws -> ExecutionRoutePayload {
        let developerInstruction = promptBuilder.executionRouteDeveloperInstruction()
        let memoryJSON = memoryManager.encodeMemoryToJSONString(memory)
        let userPrompt = promptBuilder.executionRouteUserPrompt(
            userMessage: userMessage,
            memoryJSON: memoryJSON,
            threadContext: threadContext
        )

        var inputItems = historyItems
        inputItems.append(ResponseInputMessage(role: "user", text: userPrompt))
        let responseText = try await streamingClient.requestModelResponseStreaming(
            requestLabel: "dispatch_or_answer",
            model: modelID,
            developerInstruction: developerInstruction,
            inputItems: inputItems,
            credential: credential,
            projectUsageIdentifier: projectUsageIdentifier,
            initialReasoningEffort: reasoningEffort,
            executionOptions: executionOptions,
            responseFormat: promptBuilder.executionRouteResponseTextFormat(),
            onStreamedText: nil,
            onUsage: { inputTokens, outputTokens in
                usageAccumulator.record(inputTokens: inputTokens, outputTokens: outputTokens)
            }
        )
        let payload = try parseExecutionRoutePayload(from: responseText)
        return payload
    }

    private func requestPatchPayloadWithRetry(
        userMessage: String,
        historyItems: [ResponseInputMessage],
        memory: ProjectChatService.SessionMemory,
        filesJSON: String,
        threadContext: ProjectChatService.ThreadContext?,
        credential: ProjectChatService.ProviderCredential,
        modelID: String,
        reasoningEffort: ResponsesReasoning.Effort,
        projectUsageIdentifier: String,
        executionOptions: ProjectChatService.ModelExecutionOptions,
        onStreamedText: (@MainActor (String) -> Void)?,
        onProgress: (@MainActor (String) -> Void)?,
        usageAccumulator: UsageAccumulator
    ) async throws -> PatchPayload {
        let primaryResponseText = try await requestPatchResponseStreaming(
            userMessage: userMessage,
            historyItems: historyItems,
            memory: memory,
            filesJSON: filesJSON,
            threadContext: threadContext,
            credential: credential,
            modelID: modelID,
            reasoningEffort: reasoningEffort,
            projectUsageIdentifier: projectUsageIdentifier,
            executionOptions: executionOptions,
            compactMode: false,
            onStreamedText: onStreamedText,
            usageAccumulator: usageAccumulator
        )
        do {
            return try parsePatchPayload(from: primaryResponseText)
        } catch ProjectChatService.ServiceError.invalidPatchJSON {
            if let onProgress {
                await onProgress("改动响应过长或格式异常，正在请求紧凑补丁重试...")
            }
            let compactResponseText = try await requestPatchResponseStreaming(
                userMessage: userMessage,
                historyItems: historyItems,
                memory: memory,
                filesJSON: filesJSON,
                threadContext: threadContext,
                credential: credential,
                modelID: modelID,
                reasoningEffort: reasoningEffort,
                projectUsageIdentifier: projectUsageIdentifier,
                executionOptions: executionOptions,
                compactMode: true,
                onStreamedText: onStreamedText,
                usageAccumulator: usageAccumulator
            )
            return try parsePatchPayload(from: compactResponseText)
        }
    }

    private func isPatchPayloadFailure(_ error: Error) -> Bool {
        guard let serviceError = error as? ProjectChatService.ServiceError else {
            return false
        }
        switch serviceError {
        case .invalidPatchJSON, .invalidResponse:
            return true
        default:
            return false
        }
    }

    private func requestPatchResponseStreaming(
        userMessage: String,
        historyItems: [ResponseInputMessage],
        memory: ProjectChatService.SessionMemory,
        filesJSON: String,
        threadContext: ProjectChatService.ThreadContext?,
        credential: ProjectChatService.ProviderCredential,
        modelID: String,
        reasoningEffort: ResponsesReasoning.Effort,
        projectUsageIdentifier: String,
        executionOptions: ProjectChatService.ModelExecutionOptions,
        compactMode: Bool,
        onStreamedText: (@MainActor (String) -> Void)?,
        usageAccumulator: UsageAccumulator
    ) async throws -> String {
        let developerInstruction = promptBuilder.patchDeveloperInstruction(compactMode: compactMode)
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
            requestLabel: compactMode ? "generate_patch_compact" : "generate_patch",
            model: modelID,
            developerInstruction: developerInstruction,
            inputItems: inputItems,
            credential: credential,
            projectUsageIdentifier: projectUsageIdentifier,
            initialReasoningEffort: reasoningEffort,
            executionOptions: executionOptions,
            responseFormat: promptBuilder.patchResponseTextFormat(),
            onStreamedText: onStreamedText,
            onUsage: { inputTokens, outputTokens in
                usageAccumulator.record(inputTokens: inputTokens, outputTokens: outputTokens)
            }
        )
    }

    private func requestSelectedPaths(
        userMessage: String,
        historyItems: [ResponseInputMessage],
        memory: ProjectChatService.SessionMemory,
        fileCandidates: [ProjectFileCandidate],
        threadContext: ProjectChatService.ThreadContext?,
        credential: ProjectChatService.ProviderCredential,
        modelID: String,
        reasoningEffort: ResponsesReasoning.Effort,
        projectUsageIdentifier: String,
        executionOptions: ProjectChatService.ModelExecutionOptions,
        usageAccumulator: UsageAccumulator
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
            model: modelID,
            developerInstruction: developerInstruction,
            inputItems: inputItems,
            credential: credential,
            projectUsageIdentifier: projectUsageIdentifier,
            initialReasoningEffort: reasoningEffort,
            executionOptions: executionOptions,
            responseFormat: promptBuilder.fileSelectionResponseTextFormat(),
            onStreamedText: nil,
            onUsage: { inputTokens, outputTokens in
                usageAccumulator.record(inputTokens: inputTokens, outputTokens: outputTokens)
            }
        )
        let payload = try parseFileSelectionPayload(from: responseText)
        return scanner.sanitizeSelectedPaths(payload.selectedPaths, fileCandidates: fileCandidates)
    }

    private func requestTaskPlan(
        userMessage: String,
        historyItems: [ResponseInputMessage],
        memory: ProjectChatService.SessionMemory,
        fileCandidates: [ProjectFileCandidate],
        threadContext: ProjectChatService.ThreadContext?,
        credential: ProjectChatService.ProviderCredential,
        modelID: String,
        reasoningEffort: ResponsesReasoning.Effort,
        projectUsageIdentifier: String,
        executionOptions: ProjectChatService.ModelExecutionOptions,
        usageAccumulator: UsageAccumulator
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
            model: modelID,
            developerInstruction: developerInstruction,
            inputItems: inputItems,
            credential: credential,
            projectUsageIdentifier: projectUsageIdentifier,
            initialReasoningEffort: reasoningEffort,
            executionOptions: executionOptions,
            responseFormat: promptBuilder.taskPlanResponseTextFormat(),
            onStreamedText: nil,
            onUsage: { inputTokens, outputTokens in
                usageAccumulator.record(inputTokens: inputTokens, outputTokens: outputTokens)
            }
        )

        let payload = try parseTaskPlanPayload(from: responseText)
        let sanitizedTasks = sanitizeTaskPlanItems(payload.tasks)
        guard !sanitizedTasks.isEmpty else {
            throw ProjectChatService.ServiceError.invalidResponse
        }
        let summary = normalizedTaskItem(payload.summary, maxCharacters: configuration.maxTaskGoalCharacters) ?? "按步骤执行用户请求。"
        return TaskPlan(summary: summary, tasks: sanitizedTasks)
    }

    private func resolveExecutionRouteOrFallback(
        userMessage: String,
        historyItems: [ResponseInputMessage],
        memory: ProjectChatService.SessionMemory,
        threadContext: ProjectChatService.ThreadContext?,
        credential: ProjectChatService.ProviderCredential,
        modelID: String,
        reasoningEffort: ResponsesReasoning.Effort,
        projectUsageIdentifier: String,
        executionOptions: ProjectChatService.ModelExecutionOptions,
        usageAccumulator: UsageAccumulator
    ) async throws -> ExecutionRoutePayload {
        do {
            return try await requestExecutionRoute(
                userMessage: userMessage,
                historyItems: historyItems,
                memory: memory,
                threadContext: threadContext,
                credential: credential,
                modelID: modelID,
                reasoningEffort: reasoningEffort,
                projectUsageIdentifier: projectUsageIdentifier,
                executionOptions: executionOptions,
                usageAccumulator: usageAccumulator
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            debugLog("[DoufuCodexChat Debug] execution route failed, fallback to multi_task. error=\(error.localizedDescription)")
            return ExecutionRoutePayload(
                mode: .multiTask,
                reason: nil,
                assistantMessage: nil,
                memoryUpdate: nil
            )
        }
    }

    private func resolveTaskPlanOrFallback(
        userMessage: String,
        historyItems: [ResponseInputMessage],
        memory: ProjectChatService.SessionMemory,
        fileCandidates: [ProjectFileCandidate],
        threadContext: ProjectChatService.ThreadContext?,
        credential: ProjectChatService.ProviderCredential,
        modelID: String,
        reasoningEffort: ResponsesReasoning.Effort,
        projectUsageIdentifier: String,
        executionOptions: ProjectChatService.ModelExecutionOptions,
        usageAccumulator: UsageAccumulator
    ) async throws -> TaskPlan {
        do {
            return try await requestTaskPlan(
                userMessage: userMessage,
                historyItems: historyItems,
                memory: memory,
                fileCandidates: fileCandidates,
                threadContext: threadContext,
                credential: credential,
                modelID: modelID,
                reasoningEffort: reasoningEffort,
                projectUsageIdentifier: projectUsageIdentifier,
                executionOptions: executionOptions,
                usageAccumulator: usageAccumulator
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
        memory: ProjectChatService.SessionMemory,
        fileCandidates: [ProjectFileCandidate],
        threadContext: ProjectChatService.ThreadContext?,
        credential: ProjectChatService.ProviderCredential,
        modelID: String,
        reasoningEffort: ResponsesReasoning.Effort,
        projectUsageIdentifier: String,
        executionOptions: ProjectChatService.ModelExecutionOptions,
        usageAccumulator: UsageAccumulator
    ) async throws -> [String] {
        do {
            let selected = try await requestSelectedPaths(
                userMessage: userMessage,
                historyItems: historyItems,
                memory: memory,
                fileCandidates: fileCandidates,
                threadContext: threadContext,
                credential: credential,
                modelID: modelID,
                reasoningEffort: reasoningEffort,
                projectUsageIdentifier: projectUsageIdentifier,
                executionOptions: executionOptions,
                usageAccumulator: usageAccumulator
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
        try decodePayload(
            from: responseText,
            as: PatchPayload.self,
            invalidError: .invalidPatchJSON
        )
    }

    private func parseExecutionRoutePayload(from responseText: String) throws -> ExecutionRoutePayload {
        try decodePayload(
            from: responseText,
            as: ExecutionRoutePayload.self,
            invalidError: .invalidResponse
        )
    }

    private func parseFileSelectionPayload(from responseText: String) throws -> FileSelectionPayload {
        try decodePayload(
            from: responseText,
            as: FileSelectionPayload.self,
            invalidError: .invalidResponse
        )
    }

    private func parseTaskPlanPayload(from responseText: String) throws -> TaskPlanPayload {
        try decodePayload(
            from: responseText,
            as: TaskPlanPayload.self,
            invalidError: .invalidResponse
        )
    }

    private func normalizedThreadMemoryUpdate(from patch: PatchPayload) -> ProjectChatService.ThreadMemoryUpdate? {
        normalizedThreadMemoryUpdate(
            memoryUpdate: patch.memoryUpdate,
            legacyThreadMemoryUpdate: patch.threadMemoryUpdate
        )
    }

    private func normalizedThreadMemoryUpdate(
        memoryUpdate: PatchMemoryUpdate?,
        legacyThreadMemoryUpdate: PatchThreadMemoryUpdate? = nil
    ) -> ProjectChatService.ThreadMemoryUpdate? {
        if let memoryUpdate {
            let objective = normalizedTaskItem(
                memoryUpdate.resolvedObjective,
                maxCharacters: configuration.maxMemoryObjectiveCharacters
            )
            let constraints = normalizedThreadMemoryItems(
                memoryUpdate.resolvedConstraints,
                limit: configuration.maxMemoryConstraintItems,
                maxCharacters: configuration.maxMemoryItemCharacters
            )
            let todoItems = normalizedThreadMemoryItems(
                memoryUpdate.resolvedTodoItems,
                limit: configuration.maxMemoryTodoItems,
                maxCharacters: configuration.maxMemoryItemCharacters
            )
            let notes = normalizedThreadMemoryItems(
                memoryUpdate.resolvedNotes,
                limit: configuration.maxMemoryTodoItems,
                maxCharacters: configuration.maxHistorySummaryCharacters
            )

            let delta: ProjectChatService.ThreadMemoryUpdate.MemoryDelta?
            if objective != nil || !constraints.isEmpty || !todoItems.isEmpty || !notes.isEmpty {
                delta = .init(
                    objective: objective,
                    constraints: constraints,
                    todoItems: todoItems,
                    notes: notes
                )
            } else {
                delta = nil
            }

            let modernContent = memoryUpdate.threadContentMarkdown?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let nextVersionSummary = normalizedTaskItem(
                memoryUpdate.threadNextVersionSummary,
                maxCharacters: configuration.maxHistorySummaryCharacters
            )
            let nextVersionContentMarkdown = memoryUpdate.threadNextVersionContentMarkdown?
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if delta != nil || !(modernContent ?? "").isEmpty || memoryUpdate.threadShouldRollOver || nextVersionSummary != nil {
                return ProjectChatService.ThreadMemoryUpdate(
                    memoryDelta: delta,
                    contentMarkdown: modernContent,
                    shouldRollOver: memoryUpdate.threadShouldRollOver,
                    nextVersionSummary: nextVersionSummary,
                    nextVersionContentMarkdown: nextVersionContentMarkdown
                )
            }
        }

        guard let legacyThreadMemoryUpdate else {
            return nil
        }
        let legacyContent = legacyThreadMemoryUpdate.contentMarkdown?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !legacyContent.isEmpty else {
            return nil
        }

        let nextVersionSummary = normalizedTaskItem(
            legacyThreadMemoryUpdate.nextVersionSummary,
            maxCharacters: configuration.maxHistorySummaryCharacters
        )
        let nextVersionContentMarkdown = legacyThreadMemoryUpdate.nextVersionContentMarkdown?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return ProjectChatService.ThreadMemoryUpdate(
            memoryDelta: nil,
            contentMarkdown: legacyContent,
            shouldRollOver: legacyThreadMemoryUpdate.shouldRollOver,
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

    private func decodePayload<T: Decodable>(
        from responseText: String,
        as type: T.Type,
        invalidError: ProjectChatService.ServiceError
    ) throws -> T {
        let trimmed = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw invalidError
        }

        var candidates: [String] = []

        let strippedFence = stripMarkdownCodeFenceIfNeeded(from: trimmed)
        let extractedFromStripped = extractJSONObject(from: strippedFence) ?? strippedFence
        candidates.append(extractedFromStripped)

        if strippedFence != trimmed {
            let extractedFromOriginal = extractJSONObject(from: trimmed) ?? trimmed
            if extractedFromOriginal != extractedFromStripped {
                candidates.append(extractedFromOriginal)
            }
        }

        var normalizedCandidates: [String] = []
        normalizedCandidates.reserveCapacity(candidates.count * 2)
        for candidate in candidates {
            normalizedCandidates.append(candidate)
            let sanitizedJSONString = sanitizeJSONStringLiterals(candidate)
            if sanitizedJSONString != candidate {
                normalizedCandidates.append(sanitizedJSONString)
            }
            let structurallyRepaired = repairJSONStructure(candidate)
            if structurallyRepaired != candidate {
                normalizedCandidates.append(structurallyRepaired)
                let repairedAndSanitized = sanitizeJSONStringLiterals(structurallyRepaired)
                if repairedAndSanitized != structurallyRepaired {
                    normalizedCandidates.append(repairedAndSanitized)
                }
            }
        }

        var lastError: Error?
        for candidate in normalizedCandidates {
            guard let data = candidate.data(using: .utf8) else {
                continue
            }
            do {
                return try jsonDecoder.decode(T.self, from: data)
            } catch {
                lastError = error
                continue
            }
        }

        if let lastError {
            debugLog("[DoufuCodexChat Debug] decode payload failed type=\(String(describing: T.self)) error=\(detailedDecodingErrorDescription(lastError))")
        }
        throw invalidError
    }

    private func stripMarkdownCodeFenceIfNeeded(from text: String) -> String {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.hasPrefix("```"), normalized.hasSuffix("```") else {
            return normalized
        }

        var lines = normalized.components(separatedBy: .newlines)
        guard let firstLine = lines.first, firstLine.hasPrefix("```") else {
            return normalized
        }
        guard let lastLine = lines.last, lastLine.trimmingCharacters(in: .whitespacesAndNewlines) == "```" else {
            return normalized
        }

        lines.removeFirst()
        lines.removeLast()
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func sanitizeJSONStringLiterals(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        var result = String()
        result.reserveCapacity(text.count + 128)

        var isInsideString = false
        var index = 0

        while index < scalars.count {
            let scalar = scalars[index]

            if !isInsideString {
                result.unicodeScalars.append(scalar)
                if scalar == "\"" {
                    isInsideString = true
                }
                index += 1
                continue
            }

            if scalar == "\"" {
                if shouldTreatAsStringTerminator(in: scalars, quoteIndex: index) {
                    result.unicodeScalars.append(scalar)
                    isInsideString = false
                } else {
                    // Recover from malformed JSON that contains bare quotes inside a string literal.
                    result += "\\\""
                }
                index += 1
                continue
            }

            if scalar == "\\" {
                guard index + 1 < scalars.count else {
                    result += "\\\\"
                    index += 1
                    continue
                }

                let next = scalars[index + 1]
                if next == "u" {
                    if index + 5 < scalars.count {
                        let unicodeDigits = scalars[(index + 2)...(index + 5)]
                        let hasValidUnicodeDigits = unicodeDigits.allSatisfy { isHexDigit($0) }
                        if hasValidUnicodeDigits {
                            result.unicodeScalars.append("\\")
                            result.unicodeScalars.append(next)
                            for digit in unicodeDigits {
                                result.unicodeScalars.append(digit)
                            }
                            index += 6
                            continue
                        }
                    }
                    result += "\\\\"
                    index += 1
                    continue
                }

                let allowedEscapes: Set<UnicodeScalar> = ["\"", "\\", "/", "b", "f", "n", "r", "t"]
                if allowedEscapes.contains(next) {
                    result.unicodeScalars.append("\\")
                    result.unicodeScalars.append(next)
                    index += 2
                    continue
                }

                result += "\\\\"
                index += 1
                continue
            }

            switch scalar {
            case "\n":
                result += "\\n"
            case "\r":
                result += "\\r"
            case "\t":
                result += "\\t"
            default:
                if scalar.value < 0x20 {
                    result += String(format: "\\u%04X", scalar.value)
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
            index += 1
        }

        return result
    }

    private func repairJSONStructure(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        var result = String()
        result.reserveCapacity(text.count + 64)

        var stack: [UnicodeScalar] = []
        var isInsideString = false
        var isEscaped = false

        for scalar in scalars {
            if isInsideString {
                result.unicodeScalars.append(scalar)
                if isEscaped {
                    isEscaped = false
                    continue
                }
                if scalar == "\\" {
                    isEscaped = true
                } else if scalar == "\"" {
                    isInsideString = false
                }
                continue
            }

            if scalar == "\"" {
                isInsideString = true
                result.unicodeScalars.append(scalar)
                continue
            }

            if scalar == "{" || scalar == "[" {
                stack.append(scalar)
                result.unicodeScalars.append(scalar)
                continue
            }

            if scalar == "}" || scalar == "]" {
                let expectedOpen: UnicodeScalar = (scalar == "}") ? "{" : "["
                while let top = stack.last, top != expectedOpen {
                    stack.removeLast()
                    result.unicodeScalars.append(top == "{" ? "}" : "]")
                }
                if stack.last == expectedOpen {
                    stack.removeLast()
                    result.unicodeScalars.append(scalar)
                }
                continue
            }

            result.unicodeScalars.append(scalar)
        }

        while let top = stack.popLast() {
            result.unicodeScalars.append(top == "{" ? "}" : "]")
        }

        return result
    }

    private func shouldTreatAsStringTerminator(in scalars: [UnicodeScalar], quoteIndex: Int) -> Bool {
        var lookahead = quoteIndex + 1
        while lookahead < scalars.count {
            let scalar = scalars[lookahead]
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                lookahead += 1
                continue
            }
            switch scalar {
            case ",", "}", "]", ":":
                return true
            default:
                return false
            }
        }
        return true
    }

    private func isHexDigit(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 48...57, 65...70, 97...102:
            return true
        default:
            return false
        }
    }

    private func detailedDecodingErrorDescription(_ error: Error) -> String {
        if let decodingError = error as? DecodingError {
            switch decodingError {
            case let .typeMismatch(type, context):
                return "typeMismatch(\(type)) at \(codingPathString(context.codingPath)): \(context.debugDescription)"
            case let .valueNotFound(type, context):
                return "valueNotFound(\(type)) at \(codingPathString(context.codingPath)): \(context.debugDescription)"
            case let .keyNotFound(key, context):
                return "keyNotFound(\(key.stringValue)) at \(codingPathString(context.codingPath)): \(context.debugDescription)"
            case let .dataCorrupted(context):
                return "dataCorrupted at \(codingPathString(context.codingPath)): \(context.debugDescription)"
            @unknown default:
                return error.localizedDescription
            }
        }
        return error.localizedDescription
    }

    private func codingPathString(_ codingPath: [CodingKey]) -> String {
        guard !codingPath.isEmpty else {
            return "<root>"
        }
        return codingPath.map(\.stringValue).joined(separator: ".")
    }

    private func mapReasoningEffort(_ effort: ProjectChatService.ReasoningEffort) -> ResponsesReasoning.Effort {
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

    private func resolvedModelID(from credential: ProjectChatService.ProviderCredential) -> String {
        let normalized = credential.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? configuration.defaultModel : normalized
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

    private func normalizedThreadMemoryItems(
        _ items: [String],
        limit: Int,
        maxCharacters: Int
    ) -> [String] {
        var output: [String] = []
        var seen = Set<String>()
        for item in items {
            guard let normalized = normalizedTaskItem(item, maxCharacters: maxCharacters) else {
                continue
            }
            guard seen.insert(normalized).inserted else {
                continue
            }
            output.append(normalized)
            if output.count >= limit {
                break
            }
        }
        return output
    }

    private func debugLog(_ message: @autoclosure () -> String) {
#if DEBUG
        print(message())
#endif
    }
}
