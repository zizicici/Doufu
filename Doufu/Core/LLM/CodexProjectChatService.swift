//
//  CodexProjectChatService.swift
//  Doufu
//
//  Created by Codex on 2026/03/05.
//

import Foundation

final class CodexProjectChatService {

    struct ProviderCredential {
        let providerID: String
        let providerLabel: String
        let baseURL: URL
        let bearerToken: String
        let chatGPTAccountID: String?
    }

    enum Role: String {
        case user
        case assistant
    }

    struct ChatTurn {
        let role: Role
        let text: String
    }

    struct SessionMemory: Codable, Equatable {
        var objective: String
        var constraints: [String]
        var changedFiles: [String]
        var todoItems: [String]

        static let empty = SessionMemory(
            objective: "",
            constraints: [],
            changedFiles: [],
            todoItems: []
        )
    }

    struct ResultPayload {
        let assistantMessage: String
        let changedPaths: [String]
        let updatedMemory: SessionMemory
    }

    enum ServiceError: LocalizedError {
        case noProjectFiles
        case invalidResponse
        case invalidPatchJSON
        case invalidPath(String)
        case networkFailed(String)

        var errorDescription: String? {
            switch self {
            case .noProjectFiles:
                return "项目目录为空，无法生成上下文。"
            case .invalidResponse:
                return "模型响应格式无效，请重试。"
            case .invalidPatchJSON:
                return "模型未返回可解析的 JSON 变更。"
            case let .invalidPath(path):
                return "模型返回了不安全的文件路径：\(path)"
            case let .networkFailed(message):
                return message
            }
        }
    }

    private let jsonDecoder = JSONDecoder()
    private let jsonEncoder = JSONEncoder()

    private let maxFilesForCatalog = 300
    private let maxBytesPerCatalogFile = 120_000
    private let maxPreviewCharactersForCatalog = 220
    private let maxFilesForContext = 20
    private let maxBytesPerContextFile = 45_000
    private let maxContextBytesTotal = 220_000
    private let maxFilePathsFromSelection = 16
    private let maxPlannedTasks = 5
    private let maxFilesPerTaskContext = 3
    private let maxHistoryTurns = 16
    private let maxHistoryTurnsDirectlyIncluded = 8
    private let maxHistorySummaryCharacters = 1_600
    private let maxMemoryObjectiveCharacters = 180
    private let maxMemoryConstraintItems = 8
    private let maxMemoryChangedFiles = 24
    private let maxMemoryTodoItems = 8
    private let maxMemoryItemCharacters = 120
    private let maxTaskTitleCharacters = 48
    private let maxTaskGoalCharacters = 260
    private let model = "gpt-5.3-codex"

    init() {
        jsonEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    func sendAndApply(
        userMessage: String,
        history: [ChatTurn],
        projectURL: URL,
        credential: ProviderCredential,
        memory: SessionMemory? = nil,
        onStreamedText: (@MainActor (String) -> Void)? = nil,
        onProgress: (@MainActor (String) -> Void)? = nil
    ) async throws -> ResultPayload {
        let trimmedMessage = userMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMessage.isEmpty else {
            throw ServiceError.invalidResponse
        }

        if let onProgress {
            await onProgress("正在扫描项目文件...")
        }

        let fileCandidates = try collectProjectFileCandidates(from: projectURL)
        let normalizedHistory = normalizedHistoryTurns(history, excludingLatestUserMessage: trimmedMessage)
        let requestMemory = buildRequestMemory(base: memory, latestUserMessage: trimmedMessage)
        let historyItems = buildHistoryInputMessages(from: normalizedHistory)

        if let onProgress {
            await onProgress("正在规划执行步骤...")
        }

        let taskPlan = await resolveTaskPlanOrFallback(
            userMessage: trimmedMessage,
            historyItems: historyItems,
            memory: requestMemory,
            fileCandidates: fileCandidates,
            credential: credential
        )

        var allChangedPaths: [String] = []
        var currentMemory = requestMemory
        var taskMessages: [String] = []

        for (index, task) in taskPlan.tasks.enumerated() {
            let stepNumber = index + 1
            let totalSteps = taskPlan.tasks.count
            let taskRequestText = buildTaskRequestText(
                originalUserMessage: trimmedMessage,
                task: task,
                stepNumber: stepNumber,
                totalSteps: totalSteps
            )

            if let onProgress {
                await onProgress("正在执行任务 \(stepNumber)/\(totalSteps)：\(task.title)")
            }

            do {
                let selectedPaths = await resolveSelectedPathsOrFallback(
                    userMessage: taskRequestText,
                    historyItems: historyItems,
                    memory: currentMemory,
                    fileCandidates: fileCandidates,
                    credential: credential
                )

                let snapshots = buildContextSnapshots(
                    from: fileCandidates,
                    selectedPaths: Array(selectedPaths.prefix(maxFilesPerTaskContext)),
                    maxFiles: maxFilesPerTaskContext
                )
                let filesJSON = try encodeFileSnapshotsToJSONString(snapshots)

                if let onProgress {
                    await onProgress("正在生成任务 \(stepNumber)/\(totalSteps) 的改动...")
                }

                let responseText = try await requestPatchResponseStreaming(
                    userMessage: taskRequestText,
                    historyItems: historyItems,
                    memory: currentMemory,
                    filesJSON: filesJSON,
                    credential: credential,
                    onStreamedText: onStreamedText
                )
                let patch = try parsePatchPayload(from: responseText)

                if let onProgress {
                    await onProgress("正在应用任务 \(stepNumber)/\(totalSteps) 的改动...")
                }

                let changedPaths = try applyChanges(patch.changes, to: projectURL)
                if !changedPaths.isEmpty {
                    AppProjectStore.shared.touchProjectUpdatedAt(projectURL: projectURL)
                    appendUniquePaths(changedPaths, into: &allChangedPaths)
                }

                let message = patch.assistantMessage.trimmingCharacters(in: .whitespacesAndNewlines)
                let normalizedMessage = message.isEmpty ? "已完成更新。" : message
                taskMessages.append("任务\(stepNumber)「\(task.title)」：\(normalizedMessage)")

                currentMemory = buildRolledMemory(
                    current: currentMemory,
                    userMessage: taskRequestText,
                    assistantMessage: normalizedMessage,
                    changedPaths: changedPaths,
                    modelMemoryUpdate: patch.memoryUpdate
                )
                currentMemory = rollTodoFromRemainingTasks(
                    memory: currentMemory,
                    remainingTasks: Array(taskPlan.tasks.suffix(totalSteps - stepNumber))
                )
            } catch {
                let failureDescription = error.localizedDescription
                let normalizedFailure = failureDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "未知错误"
                    : failureDescription

                if !allChangedPaths.isEmpty {
                    let partialSummary = """
                    已完成 \(stepNumber - 1)/\(taskPlan.tasks.count) 个任务，当前任务「\(task.title)」失败：\(normalizedFailure)。
                    之前任务的改动已保留。请重试以继续后续任务。
                    """
                    currentMemory = rollTodoFromRemainingTasks(
                        memory: currentMemory,
                        remainingTasks: Array(taskPlan.tasks.suffix(taskPlan.tasks.count - (stepNumber - 1)))
                    )
                    return ResultPayload(
                        assistantMessage: partialSummary,
                        changedPaths: allChangedPaths,
                        updatedMemory: currentMemory
                    )
                }
                throw error
            }
        }

        let finalMessage = buildFinalAssistantMessage(
            taskPlanSummary: taskPlan.summary,
            taskMessages: taskMessages
        )
        return ResultPayload(
            assistantMessage: finalMessage,
            changedPaths: allChangedPaths,
            updatedMemory: currentMemory
        )
    }

    private func requestPatchResponseStreaming(
        userMessage: String,
        historyItems: [ResponseInputMessage],
        memory: SessionMemory,
        filesJSON: String,
        credential: ProviderCredential,
        onStreamedText: (@MainActor (String) -> Void)?
    ) async throws -> String {
        let developerInstruction = """
        你是 Doufu App 内的 Codex 工程助手。你会根据用户需求，直接修改本地网页项目文件。
        默认目标设备是 iPhone 竖屏，必须优先保证移动端体验，并尽量贴近 iOS 原生观感，避免强烈网页感。
        如果项目根目录存在 AGENTS.md，你必须严格遵循其规则，并在规则冲突时以 AGENTS.md 为最高优先级。

        移动端硬性要求（除非用户明确要求例外）：
        1) 保持移动优先布局，默认单栏，避免桌面化多栏主布局。
        2) 正确处理 Safe Area（top/right/bottom/left）。
        3) 交互控件触控区域高度至少 44px。
        4) 不依赖 hover 完成关键交互。
        5) 样式要克制、清晰、轻量，贴近原生 App，而非传统网页风格。

        你必须严格输出 JSON 对象，不要输出 markdown，不要输出代码块，不要输出额外说明。
        JSON schema:
        {
          "assistant_message": "给用户的简短说明",
          "changes": [
            {
              "path": "相对于项目根目录的文件路径，如 index.html 或 src/main.js",
              "content": "文件完整内容（覆盖写入）"
            }
          ],
          "memory_update": {
            "objective": "可选，更新后的目标摘要",
            "constraints": ["可选，约束列表"],
            "todo_items": ["可选，后续待办列表"]
          }
        }
        规则：
        1) path 必须是相对路径，禁止以 / 开头，禁止 ..。
        2) 只改与用户需求相关的最小文件集。
        3) 若无需改动，返回 changes: []。
        4) 修改网页时尽量保证可直接运行（html/css/js 一致）。
        """

        let userPrompt = """
        设备上下文：
        - Platform: iPhone
        - Orientation: portrait
        - 要求：移动优先、Safe Area 完整适配、降低网页感、提升原生感

        会话记忆块（JSON）：
        \(encodeMemoryToJSONString(memory))

        当前项目文件（JSON）：
        \(filesJSON)

        用户请求：
        \(userMessage)
        """

        var inputItems = historyItems
        inputItems.append(ResponseInputMessage(role: "user", text: userPrompt))

        return try await requestModelResponseStreaming(
            requestLabel: "generate_patch",
            developerInstruction: developerInstruction,
            inputItems: inputItems,
            credential: credential,
            initialReasoningEffort: recommendedReasoningEffort(for: userMessage),
            onStreamedText: onStreamedText
        )
    }

    private func requestSelectedPaths(
        userMessage: String,
        historyItems: [ResponseInputMessage],
        memory: SessionMemory,
        fileCandidates: [ProjectFileCandidate],
        credential: ProviderCredential
    ) async throws -> [String] {
        let fileCatalogJSON = try encodeFileCatalogToJSONString(fileCandidates)

        let developerInstruction = """
        你是 Doufu App 的上下文检索助手。你的任务是从文件清单中挑选最相关的文件路径，供后续代码修改阶段读取。
        你必须严格输出 JSON 对象，不要输出 markdown，不要输出代码块，不要输出额外说明。
        JSON schema:
        {
          "selected_paths": ["相对路径1", "相对路径2"],
          "notes": "可选，简短说明"
        }
        规则：
        1) 只能从给定清单中选择路径，禁止编造不存在的路径。
        2) 优先选择与用户请求直接相关的文件。
        3) 至少选择 1 个，最多选择 \(maxFilePathsFromSelection) 个。
        4) 若项目中存在 AGENTS.md，优先纳入 selected_paths。
        """

        let userPrompt = """
        用户请求：
        \(userMessage)

        会话记忆块（JSON）：
        \(encodeMemoryToJSONString(memory))

        文件清单（JSON）：
        \(fileCatalogJSON)
        """

        var inputItems = historyItems
        inputItems.append(ResponseInputMessage(role: "user", text: userPrompt))

        let responseText = try await requestModelResponseStreaming(
            requestLabel: "select_context_files",
            developerInstruction: developerInstruction,
            inputItems: inputItems,
            credential: credential,
            initialReasoningEffort: .high,
            onStreamedText: nil
        )
        let payload = try parseFileSelectionPayload(from: responseText)
        return sanitizeSelectedPaths(payload.selectedPaths, fileCandidates: fileCandidates)
    }

    private func requestTaskPlan(
        userMessage: String,
        historyItems: [ResponseInputMessage],
        memory: SessionMemory,
        fileCandidates: [ProjectFileCandidate],
        credential: ProviderCredential
    ) async throws -> TaskPlan {
        let filePathListJSON = try encodeFilePathListToJSONString(fileCandidates)

        let developerInstruction = """
        你是 Doufu App 的任务规划助手。你需要把用户请求拆成可顺序执行的 1 到 \(maxPlannedTasks) 个子任务。
        你必须严格输出 JSON 对象，不要输出 markdown，不要输出代码块，不要输出额外说明。
        JSON schema:
        {
          "summary": "任务总览，简短一句话",
          "tasks": [
            {
              "title": "任务标题（简短）",
              "goal": "该任务要完成的具体目标"
            }
          ]
        }
        规则：
        1) tasks 至少 1 个，最多 \(maxPlannedTasks) 个。
        2) 每个任务要可独立执行，且按顺序执行更稳妥。
        3) 若用户请求很简单，返回 1 个任务即可。
        4) 不要输出不存在的文件路径。
        """

        let userPrompt = """
        用户请求：
        \(userMessage)

        会话记忆块（JSON）：
        \(encodeMemoryToJSONString(memory))

        项目文件路径列表（JSON）：
        \(filePathListJSON)
        """

        var inputItems = historyItems
        inputItems.append(ResponseInputMessage(role: "user", text: userPrompt))

        let responseText = try await requestModelResponseStreaming(
            requestLabel: "plan_tasks",
            developerInstruction: developerInstruction,
            inputItems: inputItems,
            credential: credential,
            initialReasoningEffort: .high,
            onStreamedText: nil
        )

        let payload = try parseTaskPlanPayload(from: responseText)
        let sanitizedTasks = sanitizeTaskPlanItems(payload.tasks)
        guard !sanitizedTasks.isEmpty else {
            throw ServiceError.invalidResponse
        }
        let summary = normalizedMemoryItem(payload.summary, maxCharacters: maxTaskGoalCharacters) ?? "按步骤执行用户请求。"
        return TaskPlan(summary: summary, tasks: sanitizedTasks)
    }

    private func resolveTaskPlanOrFallback(
        userMessage: String,
        historyItems: [ResponseInputMessage],
        memory: SessionMemory,
        fileCandidates: [ProjectFileCandidate],
        credential: ProviderCredential
    ) async -> TaskPlan {
        do {
            return try await requestTaskPlan(
                userMessage: userMessage,
                historyItems: historyItems,
                memory: memory,
                fileCandidates: fileCandidates,
                credential: credential
            )
        } catch {
            print("[DoufuCodexChat Debug] task planning failed, fallback single task. error=\(error.localizedDescription)")
            let fallbackTitle = normalizedMemoryItem("执行用户请求", maxCharacters: maxTaskTitleCharacters) ?? "执行请求"
            let fallbackGoal = normalizedMemoryItem(userMessage, maxCharacters: maxTaskGoalCharacters) ?? userMessage
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
            let title = normalizedMemoryItem(item.title, maxCharacters: maxTaskTitleCharacters) ?? ""
            let goal = normalizedMemoryItem(item.goal, maxCharacters: maxTaskGoalCharacters) ?? ""
            guard !goal.isEmpty else {
                continue
            }

            let normalizedTitle = title.isEmpty ? "任务\(output.count + 1)" : title
            let dedupeKey = "\(normalizedTitle.lowercased())|\(goal.lowercased())"
            guard seen.insert(dedupeKey).inserted else {
                continue
            }

            output.append(TaskPlanItem(title: normalizedTitle, goal: goal))
            if output.count >= maxPlannedTasks {
                break
            }
        }
        return output
    }

    private func resolveSelectedPathsOrFallback(
        userMessage: String,
        historyItems: [ResponseInputMessage],
        memory: SessionMemory,
        fileCandidates: [ProjectFileCandidate],
        credential: ProviderCredential
    ) async -> [String] {
        do {
            let selected = try await requestSelectedPaths(
                userMessage: userMessage,
                historyItems: historyItems,
                memory: memory,
                fileCandidates: fileCandidates,
                credential: credential
            )
            if !selected.isEmpty {
                return selected
            }
        } catch {
            print("[DoufuCodexChat Debug] context selection failed, fallback to heuristics. error=\(error.localizedDescription)")
        }

        return fallbackSelectionPaths(from: fileCandidates, userMessage: userMessage)
    }

    private func requestModelResponseStreaming(
        requestLabel: String,
        developerInstruction: String,
        inputItems: [ResponseInputMessage],
        credential: ProviderCredential,
        initialReasoningEffort: ResponsesReasoning.Effort,
        onStreamedText: (@MainActor (String) -> Void)?
    ) async throws -> String {
        var activeRequestBody = ResponsesRequest(
            model: model,
            instructions: developerInstruction,
            input: inputItems,
            stream: true,
            store: isChatGPTCodexBackend(url: credential.baseURL) ? false : nil,
            reasoning: ResponsesReasoning(effort: initialReasoningEffort)
        )
        var didFallbackReasoning = false

        while true {
            var request = URLRequest(url: credential.baseURL.appendingPathComponent("responses"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            request.setValue("Bearer \(credential.bearerToken)", forHTTPHeaderField: "Authorization")
            request.setValue("responses=experimental", forHTTPHeaderField: "OpenAI-Beta")
            request.setValue("codex_cli_rs", forHTTPHeaderField: "originator")
            let timeoutSeconds = activeRequestBody.reasoning?.effort == .xhigh ? 600.0 : 400.0
            request.timeoutInterval = timeoutSeconds
            if let accountID = credential.chatGPTAccountID?.trimmingCharacters(in: .whitespacesAndNewlines), !accountID.isEmpty {
                request.setValue(accountID, forHTTPHeaderField: "chatgpt-account-id")
            }
            request.httpBody = try jsonEncoder.encode(activeRequestBody)

            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw ServiceError.networkFailed("请求失败：无效响应。")
            }

            guard (200 ... 299).contains(httpResponse.statusCode) else {
                let data = try await consumeStreamBytes(bytes: bytes)

                if shouldFallbackReasoningToHigh(
                    currentEffort: activeRequestBody.reasoning?.effort,
                    responseBodyData: data,
                    alreadyFallback: didFallbackReasoning
                ) {
                    didFallbackReasoning = true
                    activeRequestBody.reasoning = ResponsesReasoning(effort: .high)
                    print("[DoufuCodexChat Debug] reasoning xhigh was rejected by backend; retrying with high. stage=\(requestLabel)")
                    continue
                }

                logFailedResponseDebug(
                    request: request,
                    httpResponse: httpResponse,
                    responseBodyData: data,
                    requestLabel: requestLabel
                )
                let message = parseErrorMessage(from: data) ?? HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
                throw ServiceError.networkFailed("请求失败：\(message)")
            }

            return try await consumeStreamingResponse(
                bytes: bytes,
                request: request,
                httpResponse: httpResponse,
                onStreamedText: onStreamedText,
                timeoutSeconds: timeoutSeconds,
                requestLabel: requestLabel
            )
        }
    }

    private func consumeStreamingResponse(
        bytes: URLSession.AsyncBytes,
        request: URLRequest,
        httpResponse: HTTPURLResponse,
        onStreamedText: (@MainActor (String) -> Void)?,
        timeoutSeconds: TimeInterval,
        requestLabel: String
    ) async throws -> String {
        return try await withTimeout(seconds: timeoutSeconds + 10) { [self] in
            var streamedText = ""
            var completedResponseText: String?
            var pendingDataLines: [String] = []
            var rawSSEEventPayloads: [String] = []

            for try await rawLine in bytes.lines {
                let line = rawLine.trimmingCharacters(in: .newlines)
                if line.isEmpty {
                    self.recordSSEEventPayload(dataLines: pendingDataLines, into: &rawSSEEventPayloads)
                    try await self.processSSEEvent(
                        from: pendingDataLines,
                        streamedText: &streamedText,
                        completedResponseText: &completedResponseText,
                        onStreamedText: onStreamedText
                    )
                    pendingDataLines.removeAll(keepingCapacity: true)
                    continue
                }

                guard line.hasPrefix("data:") else {
                    continue
                }

                var dataLine = String(line.dropFirst(5))
                if dataLine.hasPrefix(" ") {
                    dataLine.removeFirst()
                }
                pendingDataLines.append(dataLine)
            }

            self.recordSSEEventPayload(dataLines: pendingDataLines, into: &rawSSEEventPayloads)
            try await self.processSSEEvent(
                from: pendingDataLines,
                streamedText: &streamedText,
                completedResponseText: &completedResponseText,
                onStreamedText: onStreamedText
            )

            let normalizedStreamedText = streamedText.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedCompletedResponseText = completedResponseText?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            let finalResponseText: String?
            if !normalizedStreamedText.isEmpty {
                finalResponseText = normalizedStreamedText
            } else if !normalizedCompletedResponseText.isEmpty {
                finalResponseText = normalizedCompletedResponseText
            } else {
                finalResponseText = nil
            }

            if let finalResponseText {
                self.logSuccessfulResponseDebug(
                    request: request,
                    httpResponse: httpResponse,
                    finalResponseText: finalResponseText,
                    rawSSEEventPayloads: rawSSEEventPayloads,
                    requestLabel: requestLabel
                )
                return finalResponseText
            }

            self.logInvalidResponseDebug(
                request: request,
                httpResponse: httpResponse,
                streamedText: streamedText,
                completedResponseText: completedResponseText,
                rawSSEEventPayloads: rawSSEEventPayloads,
                requestLabel: requestLabel
            )
            throw ServiceError.invalidResponse
        }
    }

    private func recommendedReasoningEffort(for userMessage: String) -> ResponsesReasoning.Effort {
        let normalizedMessage = userMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedMessage.isEmpty else {
            return .high
        }

        let lowered = normalizedMessage.lowercased()
        let explicitXhighKeywords = [
            "xhigh", "最高推理", "最强推理", "深度推理", "深度思考", "复杂重构", "大规模重构",
            "系统级重构", "架构升级", "end-to-end architecture", "large refactor", "complex architecture"
        ]

        if explicitXhighKeywords.contains(where: { lowered.contains($0) }) {
            return .xhigh
        }
        return .high
    }

    private func shouldFallbackReasoningToHigh(
        currentEffort: ResponsesReasoning.Effort?,
        responseBodyData: Data,
        alreadyFallback: Bool
    ) -> Bool {
        guard !alreadyFallback else {
            return false
        }
        guard currentEffort == .xhigh else {
            return false
        }

        let message = parseErrorMessage(from: responseBodyData)?.lowercased() ?? ""
        if message.contains("reasoning") && message.contains("effort") {
            return true
        }
        if message.contains("xhigh") && (message.contains("invalid") || message.contains("unsupported")) {
            return true
        }
        return false
    }

    private func processSSEEvent(
        from dataLines: [String],
        streamedText: inout String,
        completedResponseText: inout String?,
        onStreamedText: (@MainActor (String) -> Void)?
    ) async throws {
        guard !dataLines.isEmpty else {
            return
        }

        let eventPayload = dataLines.joined(separator: "\n")
        if eventPayload == "[DONE]" {
            return
        }

        if let (eventObject, eventType) = decodeSSEEvent(from: eventPayload) {
            try await handleSSEEventObject(
                eventObject,
                eventType: eventType,
                streamedText: &streamedText,
                completedResponseText: &completedResponseText,
                onStreamedText: onStreamedText
            )
            return
        }

        // Some backends send newline-delimited JSON events without blank-line separators.
        // Fallback: process each line as an independent SSE payload.
        var handledAny = false
        for line in dataLines {
            let candidate = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !candidate.isEmpty, candidate != "[DONE]" else {
                continue
            }
            guard let (eventObject, eventType) = decodeSSEEvent(from: candidate) else {
                continue
            }
            handledAny = true
            try await handleSSEEventObject(
                eventObject,
                eventType: eventType,
                streamedText: &streamedText,
                completedResponseText: &completedResponseText,
                onStreamedText: onStreamedText
            )
        }

        if handledAny {
            return
        }
    }

    private func withTimeout<T>(
        seconds: TimeInterval,
        operation: @escaping () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask { [seconds] in
                let nanoseconds = UInt64(max(1, seconds) * 1_000_000_000)
                try await Task.sleep(nanoseconds: nanoseconds)
                throw ServiceError.networkFailed("请求超时，请重试。")
            }

            guard let first = try await group.next() else {
                group.cancelAll()
                throw ServiceError.networkFailed("请求失败，请重试。")
            }
            group.cancelAll()
            return first
        }
    }

    private func decodeSSEEvent(from payload: String) -> ([String: Any], String)? {
        guard
            let data = payload.data(using: .utf8),
            let eventObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let eventType = eventObject["type"] as? String
        else {
            return nil
        }
        return (eventObject, eventType)
    }

    private func handleSSEEventObject(
        _ eventObject: [String: Any],
        eventType: String,
        streamedText: inout String,
        completedResponseText: inout String?,
        onStreamedText: (@MainActor (String) -> Void)?
    ) async throws {
        switch eventType {
        case "response.output_text.delta":
            guard let delta = eventObject["delta"] as? String, !delta.isEmpty else {
                return
            }
            streamedText.append(delta)
            if let onStreamedText {
                await onStreamedText(streamedText)
            }

        case "response.output_text.done":
            guard
                streamedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                let text = extractPlainText(from: eventObject["text"]),
                !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                return
            }
            completedResponseText = text
            if let onStreamedText {
                await onStreamedText(text)
            }

        case "response.output_item.done", "response.output_item.added":
            guard
                streamedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                let itemObject = eventObject["item"] as? [String: Any],
                let text = extractText(fromOutputItemObject: itemObject),
                !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                return
            }
            completedResponseText = text
            if let onStreamedText {
                await onStreamedText(text)
            }

        case "response.completed":
            guard let responseObject = eventObject["response"] as? [String: Any] else {
                return
            }

            if let text = extractText(fromResponseObject: responseObject),
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                completedResponseText = text
                if streamedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let onStreamedText {
                    await onStreamedText(text)
                }
            }

            if let responseData = try? JSONSerialization.data(withJSONObject: responseObject),
               let decodedResponse = try? jsonDecoder.decode(ResponsesResponse.self, from: responseData),
               let text = extractOutputText(from: decodedResponse),
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if completedResponseText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
                    completedResponseText = text
                }
                if streamedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   let onStreamedText,
                   let finalText = completedResponseText {
                    await onStreamedText(finalText)
                }
            }

        case "error":
            let message = parseStreamingErrorMessage(from: eventObject) ?? "流式响应失败。"
            throw ServiceError.networkFailed("请求失败：\(message)")

        case "response.failed":
            let message = parseNestedErrorMessage(from: eventObject["response"]) ?? "响应失败。"
            throw ServiceError.networkFailed("请求失败：\(message)")

        case "response.incomplete":
            let message = parseIncompleteReason(from: eventObject["response"]) ?? "响应不完整。"
            throw ServiceError.networkFailed("请求失败：\(message)")

        default:
            return
        }
    }

    private func consumeStreamBytes(bytes: URLSession.AsyncBytes) async throws -> Data {
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
        }
        return data
    }

    private func collectProjectFileCandidates(from projectURL: URL) throws -> [ProjectFileCandidate] {
        guard let enumerator = FileManager.default.enumerator(
            at: projectURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw ServiceError.noProjectFiles
        }

        var candidates: [ProjectFileCandidate] = []

        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.isDirectoryKey])
            if values?.isDirectory == true {
                continue
            }

            let relativePath = normalizedRelativePath(fileURL: fileURL, rootURL: projectURL)
            guard isSupportedTextFile(relativePath) else {
                continue
            }

            guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else {
                continue
            }
            let truncatedData = data.prefix(maxBytesPerCatalogFile)
            guard let content = String(data: truncatedData, encoding: .utf8) else {
                continue
            }

            let lineCount = max(1, content.split(whereSeparator: \.isNewline).count)
            let byteCount = min(data.count, maxBytesPerCatalogFile)
            let preview = makePreview(from: content, maxCharacters: maxPreviewCharactersForCatalog)

            candidates.append(
                ProjectFileCandidate(
                    path: relativePath,
                    content: content,
                    byteCount: byteCount,
                    lineCount: lineCount,
                    preview: preview
                )
            )
            if candidates.count >= maxFilesForCatalog {
                break
            }
        }

        let sorted = candidates.sorted { $0.path < $1.path }
        guard !sorted.isEmpty else {
            throw ServiceError.noProjectFiles
        }
        return sorted
    }

    private func normalizedHistoryTurns(
        _ history: [ChatTurn],
        excludingLatestUserMessage userMessage: String
    ) -> [ChatTurn] {
        var turns = history
        let normalizedUserMessage = userMessage.trimmingCharacters(in: .whitespacesAndNewlines)

        if let last = turns.last,
           last.role == .user,
           last.text.trimmingCharacters(in: .whitespacesAndNewlines) == normalizedUserMessage {
            turns.removeLast()
        }

        return Array(turns.suffix(maxHistoryTurns))
    }

    private func buildHistoryInputMessages(from historyTurns: [ChatTurn]) -> [ResponseInputMessage] {
        let turns = Array(historyTurns.suffix(maxHistoryTurns))
        guard turns.count > maxHistoryTurnsDirectlyIncluded else {
            return turns.map { ResponseInputMessage(role: $0.role.rawValue, text: $0.text) }
        }

        let olderTurns = Array(turns.dropLast(maxHistoryTurnsDirectlyIncluded))
        let recentTurns = Array(turns.suffix(maxHistoryTurnsDirectlyIncluded))

        var items: [ResponseInputMessage] = []
        let summary = summarizeHistoryTurns(olderTurns)
        if !summary.isEmpty {
            let summaryMessage = """
            对话历史摘要（自动压缩）：
            \(summary)
            """
            items.append(ResponseInputMessage(role: "user", text: summaryMessage))
        }

        items.append(contentsOf: recentTurns.map { ResponseInputMessage(role: $0.role.rawValue, text: $0.text) })
        return items
    }

    private func summarizeHistoryTurns(_ turns: [ChatTurn]) -> String {
        guard !turns.isEmpty else {
            return ""
        }

        var lines: [String] = []
        var currentLength = 0
        for turn in turns {
            let roleLabel = turn.role == .user ? "用户" : "助手"
            let normalized = turn.text
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else {
                continue
            }

            let trimmed = normalized.count > 160 ? String(normalized.prefix(160)) + "..." : normalized
            let line = "- \(roleLabel)：\(trimmed)"
            let nextLength = currentLength + line.count + 1
            if nextLength > maxHistorySummaryCharacters {
                break
            }
            lines.append(line)
            currentLength = nextLength
        }

        return lines.joined(separator: "\n")
    }

    private func buildRequestMemory(
        base: SessionMemory?,
        latestUserMessage: String
    ) -> SessionMemory {
        var memory = base ?? .empty
        if let objective = normalizedMemoryItem(memory.objective, maxCharacters: maxMemoryObjectiveCharacters) {
            memory.objective = objective
        } else if let inferredObjective = inferObjective(from: latestUserMessage) {
            memory.objective = inferredObjective
        }

        memory.constraints = mergeUniqueItems(
            inferConstraints(from: latestUserMessage),
            memory.constraints,
            limit: maxMemoryConstraintItems
        )

        if let pendingTodo = pendingTodoItem(for: latestUserMessage) {
            memory.todoItems = mergeUniqueItems(
                [pendingTodo],
                memory.todoItems,
                limit: maxMemoryTodoItems
            )
        }

        return sanitizeMemory(memory)
    }

    private func buildRolledMemory(
        current: SessionMemory,
        userMessage: String,
        assistantMessage: String,
        changedPaths: [String],
        modelMemoryUpdate: PatchMemoryUpdate?
    ) -> SessionMemory {
        var memory = current

        if let modelMemoryUpdate {
            if let objective = normalizedMemoryItem(
                modelMemoryUpdate.objective,
                maxCharacters: maxMemoryObjectiveCharacters
            ) {
                memory.objective = objective
            }
            if let constraints = modelMemoryUpdate.constraints, !constraints.isEmpty {
                memory.constraints = mergeUniqueItems(
                    constraints,
                    memory.constraints,
                    limit: maxMemoryConstraintItems
                )
            }
            if let todoItems = modelMemoryUpdate.todoItems, !todoItems.isEmpty {
                memory.todoItems = mergeUniqueItems(
                    todoItems,
                    memory.todoItems,
                    limit: maxMemoryTodoItems
                )
            }
        }

        memory.constraints = mergeUniqueItems(
            inferConstraints(from: userMessage),
            memory.constraints,
            limit: maxMemoryConstraintItems
        )

        if !changedPaths.isEmpty {
            memory.changedFiles = mergeUniquePaths(
                changedPaths,
                memory.changedFiles,
                limit: maxMemoryChangedFiles
            )

            if let completedPending = pendingTodoItem(for: userMessage) {
                memory.todoItems.removeAll { $0 == completedPending }
            }
        } else if let pendingTodo = pendingTodoItem(for: userMessage) {
            memory.todoItems = mergeUniqueItems(
                [pendingTodo],
                memory.todoItems,
                limit: maxMemoryTodoItems
            )
        }

        if memory.objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let inferredObjective = inferObjective(from: userMessage) {
            memory.objective = inferredObjective
        }

        if memory.todoItems.isEmpty {
            let fallback = pendingTodoItem(for: assistantMessage) ?? pendingTodoItem(for: userMessage)
            if let fallback {
                memory.todoItems = [fallback]
            }
        }

        return sanitizeMemory(memory)
    }

    private func sanitizeMemory(_ memory: SessionMemory) -> SessionMemory {
        let objective = normalizedMemoryItem(
            memory.objective,
            maxCharacters: maxMemoryObjectiveCharacters
        ) ?? ""
        let constraints = sanitizeMemoryItems(memory.constraints, limit: maxMemoryConstraintItems)
        let changedFiles = sanitizeChangedFileItems(memory.changedFiles, limit: maxMemoryChangedFiles)
        let todoItems = sanitizeMemoryItems(memory.todoItems, limit: maxMemoryTodoItems)
        return SessionMemory(
            objective: objective,
            constraints: constraints,
            changedFiles: changedFiles,
            todoItems: todoItems
        )
    }

    private func sanitizeMemoryItems(_ items: [String], limit: Int) -> [String] {
        var output: [String] = []
        var seen = Set<String>()
        for item in items {
            guard let normalized = normalizedMemoryItem(item, maxCharacters: maxMemoryItemCharacters) else {
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

    private func sanitizeChangedFileItems(_ items: [String], limit: Int) -> [String] {
        var output: [String] = []
        var seen = Set<String>()
        for raw in items {
            let normalized = raw
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\\", with: "/")
            guard isSafeRelativePath(normalized) else {
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

    private func mergeUniquePaths(
        _ preferred: [String],
        _ existing: [String],
        limit: Int
    ) -> [String] {
        var output: [String] = []
        var seen = Set<String>()

        for raw in preferred + existing {
            let normalized = raw
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\\", with: "/")
            guard isSafeRelativePath(normalized) else {
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

    private func mergeUniqueItems(
        _ preferred: [String],
        _ existing: [String],
        limit: Int
    ) -> [String] {
        var output: [String] = []
        var seen = Set<String>()

        for item in preferred + existing {
            guard let normalized = normalizedMemoryItem(item, maxCharacters: maxMemoryItemCharacters) else {
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

    private func normalizedMemoryItem(_ text: String?, maxCharacters: Int) -> String? {
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

    private func inferObjective(from text: String) -> String? {
        normalizedMemoryItem(text, maxCharacters: maxMemoryObjectiveCharacters)
    }

    private func pendingTodoItem(for text: String) -> String? {
        guard let normalized = normalizedMemoryItem(text, maxCharacters: maxMemoryItemCharacters) else {
            return nil
        }
        return "待处理：\(normalized)"
    }

    private func inferConstraints(from text: String) -> [String] {
        let lowered = text.lowercased()
        var constraints: [String] = []

        if lowered.contains("iphone") || lowered.contains("ios") || text.contains("移动端") || text.contains("手机") {
            constraints.append("默认面向 iPhone 竖屏体验")
        }
        if lowered.contains("safe area") || text.contains("safe area") || text.contains("安全区") {
            constraints.append("必须正确处理 Safe Area")
        }
        if text.contains("原生") || text.contains("网页感") {
            constraints.append("视觉交互尽量贴近 iOS 原生，降低网页感")
        }
        if text.contains("44") || text.contains("触控") {
            constraints.append("关键点击区域保持可触达尺寸")
        }

        return constraints
    }

    private func encodeMemoryToJSONString(_ memory: SessionMemory) -> String {
        let payload = MemoryPromptPayload(
            objective: memory.objective,
            constraints: memory.constraints,
            changedFiles: memory.changedFiles,
            todoItems: memory.todoItems
        )
        guard
            let data = try? jsonEncoder.encode(payload),
            let text = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return text
    }

    private func buildTaskRequestText(
        originalUserMessage: String,
        task: TaskPlanItem,
        stepNumber: Int,
        totalSteps: Int
    ) -> String {
        """
        原始用户请求：
        \(originalUserMessage)

        当前执行步骤：\(stepNumber)/\(totalSteps)
        当前任务标题：\(task.title)
        当前任务目标：\(task.goal)
        """
    }

    private func rollTodoFromRemainingTasks(
        memory: SessionMemory,
        remainingTasks: [TaskPlanItem]
    ) -> SessionMemory {
        var nextMemory = memory
        let remainingTodoItems = remainingTasks.map { "待处理：\($0.title) - \($0.goal)" }
        nextMemory.todoItems = sanitizeMemoryItems(remainingTodoItems, limit: maxMemoryTodoItems)
        return sanitizeMemory(nextMemory)
    }

    private func appendUniquePaths(_ paths: [String], into target: inout [String]) {
        var seen = Set(target)
        for path in paths {
            let normalized = path
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\\", with: "/")
            guard isSafeRelativePath(normalized) else {
                continue
            }
            guard seen.insert(normalized).inserted else {
                continue
            }
            target.append(normalized)
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

    private func sanitizeSelectedPaths(
        _ selectedPaths: [String],
        fileCandidates: [ProjectFileCandidate]
    ) -> [String] {
        let validPaths = Set(fileCandidates.map(\.path))
        var results: [String] = []
        var seen = Set<String>()

        for rawPath in selectedPaths {
            let normalized = rawPath
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\\", with: "/")
            guard !normalized.isEmpty else {
                continue
            }
            guard validPaths.contains(normalized) else {
                continue
            }
            guard seen.insert(normalized).inserted else {
                continue
            }

            results.append(normalized)
            if results.count >= maxFilePathsFromSelection {
                break
            }
        }

        return results
    }

    private func fallbackSelectionPaths(
        from fileCandidates: [ProjectFileCandidate],
        userMessage: String
    ) -> [String] {
        guard !fileCandidates.isEmpty else {
            return []
        }

        let preferredPaths = ["AGENTS.md", "manifest.json", "index.html", "style.css", "script.js"]
        var ordered: [String] = []
        var seen = Set<String>()
        let availablePaths = Set(fileCandidates.map(\.path))

        for path in preferredPaths where availablePaths.contains(path) {
            ordered.append(path)
            seen.insert(path)
        }

        let messageTokens = Set(
            userMessage
                .lowercased()
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)
                .filter { $0.count >= 2 }
        )

        let scored = fileCandidates.map { candidate -> (path: String, score: Int) in
            let loweredPath = candidate.path.lowercased()
            var score = 0
            if loweredPath == "index.html" { score += 80 }
            if loweredPath.hasSuffix(".css") { score += 35 }
            if loweredPath.hasSuffix(".js") { score += 35 }
            if loweredPath.hasSuffix(".json") { score += 20 }
            if loweredPath.hasSuffix(".md") { score += 12 }
            if loweredPath.contains("manifest") { score += 20 }
            if loweredPath.contains("agent") { score += 25 }

            for token in messageTokens where loweredPath.contains(token) {
                score += 18
            }
            return (path: candidate.path, score: score)
        }
            .sorted { lhs, rhs in
                if lhs.score == rhs.score {
                    return lhs.path < rhs.path
                }
                return lhs.score > rhs.score
            }

        for item in scored where !seen.contains(item.path) {
            ordered.append(item.path)
            seen.insert(item.path)
            if ordered.count >= maxFilePathsFromSelection {
                break
            }
        }

        if ordered.isEmpty, let first = fileCandidates.first {
            ordered.append(first.path)
        }
        return ordered
    }

    private func buildContextSnapshots(
        from fileCandidates: [ProjectFileCandidate],
        selectedPaths: [String],
        maxFiles: Int? = nil
    ) -> [ProjectFileSnapshot] {
        guard !fileCandidates.isEmpty else {
            return []
        }
        let effectiveMaxFiles = max(1, maxFiles ?? maxFilesForContext)

        let fallbackPaths = fallbackSelectionPaths(from: fileCandidates, userMessage: "")
        var orderedPaths: [String] = []
        var seen = Set<String>()

        for path in selectedPaths + fallbackPaths {
            guard seen.insert(path).inserted else {
                continue
            }
            orderedPaths.append(path)
            if orderedPaths.count >= maxFilePathsFromSelection {
                break
            }
        }

        let candidateByPath = Dictionary(uniqueKeysWithValues: fileCandidates.map { ($0.path, $0) })
        var snapshots: [ProjectFileSnapshot] = []
        var consumedBytes = 0

        for path in orderedPaths.prefix(effectiveMaxFiles) {
            guard let candidate = candidateByPath[path] else {
                continue
            }

            let remainingBytes = maxContextBytesTotal - consumedBytes
            if remainingBytes <= 0 {
                break
            }

            let byteBudget = min(maxBytesPerContextFile, remainingBytes)
            let truncatedContent = truncatedToUTF8ByteCount(candidate.content, maxBytes: byteBudget)
            let normalized = truncatedContent.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else {
                continue
            }

            snapshots.append(ProjectFileSnapshot(path: path, content: truncatedContent))
            consumedBytes += truncatedContent.lengthOfBytes(using: .utf8)
        }

        if snapshots.isEmpty, let first = fileCandidates.first {
            let content = truncatedToUTF8ByteCount(first.content, maxBytes: min(maxBytesPerContextFile, maxContextBytesTotal))
            if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                snapshots = [ProjectFileSnapshot(path: first.path, content: content)]
            }
        }

        return snapshots
    }

    private func normalizedRelativePath(fileURL: URL, rootURL: URL) -> String {
        let rootPath = rootURL.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        var relative = filePath
        if relative.hasPrefix(prefix) {
            relative.removeFirst(prefix.count)
        }
        return relative.replacingOccurrences(of: "\\", with: "/")
    }

    private func isSupportedTextFile(_ relativePath: String) -> Bool {
        let allowedExtensions: Set<String> = ["html", "css", "js", "json", "txt", "md", "svg"]
        let ext = URL(fileURLWithPath: relativePath).pathExtension.lowercased()
        return allowedExtensions.contains(ext)
    }

    private func makePreview(from content: String, maxCharacters: Int) -> String {
        let normalized = content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > maxCharacters else {
            return normalized
        }
        return String(normalized.prefix(maxCharacters)) + "..."
    }

    private func truncatedToUTF8ByteCount(_ text: String, maxBytes: Int) -> String {
        guard maxBytes > 0 else {
            return ""
        }

        let data = Data(text.utf8)
        guard data.count > maxBytes else {
            return text
        }

        var upperBound = maxBytes
        while upperBound > 0 {
            let prefix = data.prefix(upperBound)
            if let decoded = String(data: prefix, encoding: .utf8) {
                return decoded
            }
            upperBound -= 1
        }
        return ""
    }

    private func encodeFileCatalogToJSONString(_ fileCandidates: [ProjectFileCandidate]) throws -> String {
        let catalog = fileCandidates.map { candidate in
            ProjectFileCatalogEntry(
                path: candidate.path,
                byteCount: candidate.byteCount,
                lineCount: candidate.lineCount,
                preview: candidate.preview
            )
        }
        let data = try jsonEncoder.encode(catalog)
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    private func encodeFilePathListToJSONString(_ fileCandidates: [ProjectFileCandidate]) throws -> String {
        let paths = fileCandidates.map(\.path)
        let data = try jsonEncoder.encode(paths)
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    private func encodeFileSnapshotsToJSONString(_ snapshots: [ProjectFileSnapshot]) throws -> String {
        let data = try jsonEncoder.encode(snapshots)
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    private func parsePatchPayload(from responseText: String) throws -> PatchPayload {
        let trimmed = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ServiceError.invalidPatchJSON
        }

        let jsonString = extractJSONObject(from: trimmed) ?? trimmed
        guard let data = jsonString.data(using: .utf8) else {
            throw ServiceError.invalidPatchJSON
        }

        do {
            return try jsonDecoder.decode(PatchPayload.self, from: data)
        } catch {
            throw ServiceError.invalidPatchJSON
        }
    }

    private func parseFileSelectionPayload(from responseText: String) throws -> FileSelectionPayload {
        let trimmed = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ServiceError.invalidResponse
        }

        let jsonString = extractJSONObject(from: trimmed) ?? trimmed
        guard let data = jsonString.data(using: .utf8) else {
            throw ServiceError.invalidResponse
        }

        do {
            return try jsonDecoder.decode(FileSelectionPayload.self, from: data)
        } catch {
            throw ServiceError.invalidResponse
        }
    }

    private func parseTaskPlanPayload(from responseText: String) throws -> TaskPlanPayload {
        let trimmed = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ServiceError.invalidResponse
        }

        let jsonString = extractJSONObject(from: trimmed) ?? trimmed
        guard let data = jsonString.data(using: .utf8) else {
            throw ServiceError.invalidResponse
        }

        do {
            return try jsonDecoder.decode(TaskPlanPayload.self, from: data)
        } catch {
            throw ServiceError.invalidResponse
        }
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

    private func applyChanges(_ changes: [PatchChange], to projectURL: URL) throws -> [String] {
        var changedPaths: [String] = []
        let rootPath = projectURL.standardizedFileURL.path
        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"

        for change in changes {
            let rawPath = change.path.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedPath = rawPath.replacingOccurrences(of: "\\", with: "/")
            guard isSafeRelativePath(normalizedPath) else {
                throw ServiceError.invalidPath(change.path)
            }

            let destinationURL = projectURL.appendingPathComponent(normalizedPath)
            let destinationPath = destinationURL.standardizedFileURL.path
            guard destinationPath.hasPrefix(rootPrefix) else {
                throw ServiceError.invalidPath(change.path)
            }

            let directoryURL = destinationURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            try change.content.write(to: destinationURL, atomically: true, encoding: .utf8)
            changedPaths.append(normalizedPath)
        }

        return changedPaths
    }

    private func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty else {
            return false
        }
        if path.hasPrefix("/") || path.hasPrefix("~") {
            return false
        }
        if path.contains("..") {
            return false
        }
        return true
    }

    private func extractOutputText(from response: ResponsesResponse) -> String? {
        let segments = (response.output ?? []).compactMap { outputItem -> String? in
            guard outputItem.type == "message" else {
                return nil
            }
            let texts = (outputItem.content ?? []).compactMap { contentItem -> String? in
                if contentItem.type == "output_text" || contentItem.type == "text" {
                    return contentItem.text
                }
                return nil
            }
            let merged = texts.joined(separator: "\n")
            return merged.isEmpty ? nil : merged
        }
        return segments.joined(separator: "\n")
    }

    private func extractText(fromResponseObject responseObject: [String: Any]) -> String? {
        if let outputText = extractPlainText(from: responseObject["output_text"]),
           !outputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return outputText
        }

        guard let outputItems = responseObject["output"] as? [[String: Any]] else {
            return nil
        }

        let texts = outputItems.compactMap { extractText(fromOutputItemObject: $0) }
        let merged = texts.joined(separator: "\n")
        return merged.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : merged
    }

    private func extractText(fromOutputItemObject outputItem: [String: Any]) -> String? {
        if let directText = extractPlainText(from: outputItem["text"]),
           !directText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return directText
        }

        guard let contentItems = outputItem["content"] as? [Any] else {
            return nil
        }

        let texts = contentItems.compactMap { contentObject -> String? in
            guard let dictionary = contentObject as? [String: Any] else {
                return nil
            }

            let contentType = (dictionary["type"] as? String)?.lowercased() ?? ""
            guard contentType == "output_text" || contentType == "text" || contentType == "input_text" else {
                return nil
            }
            return extractPlainText(from: dictionary["text"])
        }

        let merged = texts.joined(separator: "\n")
        return merged.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : merged
    }

    private func extractPlainText(from value: Any?) -> String? {
        if let text = value as? String {
            return text
        }
        if let textObject = value as? [String: Any],
           let valueText = textObject["value"] as? String {
            return valueText
        }
        return nil
    }

    private func parseErrorMessage(from data: Data) -> String? {
        guard !data.isEmpty else {
            return nil
        }

        if
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let error = json["error"] as? [String: Any],
            let message = error["message"] as? String,
            !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return message
        }

        if
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let message = json["message"] as? String,
            !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return message
        }

        if
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let detail = json["detail"] as? String,
            !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return detail
        }

        if let rawText = String(data: data, encoding: .utf8) {
            let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }

        return nil
    }

    private func parseStreamingErrorMessage(from eventObject: [String: Any]) -> String? {
        if
            let errorObject = eventObject["error"] as? [String: Any],
            let message = errorObject["message"] as? String,
            !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return message
        }
        if
            let message = eventObject["message"] as? String,
            !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return message
        }
        return nil
    }

    private func parseNestedErrorMessage(from responseObject: Any?) -> String? {
        guard let response = responseObject as? [String: Any] else {
            return nil
        }
        if
            let error = response["error"] as? [String: Any],
            let message = error["message"] as? String,
            !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return message
        }
        return nil
    }

    private func parseIncompleteReason(from responseObject: Any?) -> String? {
        guard let response = responseObject as? [String: Any] else {
            return nil
        }
        if
            let details = response["incomplete_details"] as? [String: Any],
            let reason = details["reason"] as? String,
            !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return reason
        }
        return nil
    }

    private func recordSSEEventPayload(dataLines: [String], into payloads: inout [String]) {
        guard !dataLines.isEmpty else {
            return
        }
        let payload = dataLines.joined(separator: "\n")
        if payload == "[DONE]" {
            return
        }
        payloads.append(payload)
    }

    private func logSuccessfulResponseDebug(
        request: URLRequest,
        httpResponse: HTTPURLResponse,
        finalResponseText: String,
        rawSSEEventPayloads: [String],
        requestLabel: String
    ) {
        print("========== [DoufuCodexChat Debug] HTTP 请求成功 ==========")
        print("Request Label: \(requestLabel)")
        print("URL: \(request.url?.absoluteString ?? "nil")")
        print("Status: \(httpResponse.statusCode)")
        print("Response Headers: \(httpResponse.allHeaderFields)")
        if let requestBody = request.httpBody, let requestBodyText = String(data: requestBody, encoding: .utf8) {
            print("Request Body: \(requestBodyText)")
        } else {
            print("Request Body: <nil>")
        }
        print("Final Response Text: \(finalResponseText)")
        print("SSE Event Count: \(rawSSEEventPayloads.count)")
        if rawSSEEventPayloads.isEmpty {
            print("SSE Events: <none>")
        } else {
            for (index, payload) in rawSSEEventPayloads.enumerated() {
                print("----- SSE[\(index)] -----")
                print(payload)
            }
        }
        print("========== [DoufuCodexChat Debug] 结束 ==========")
    }

    private func logFailedResponseDebug(
        request: URLRequest,
        httpResponse: HTTPURLResponse,
        responseBodyData: Data,
        requestLabel: String
    ) {
        print("========== [DoufuCodexChat Debug] HTTP 请求失败 ==========")
        print("Request Label: \(requestLabel)")
        print("URL: \(request.url?.absoluteString ?? "nil")")
        print("Status: \(httpResponse.statusCode)")
        print("Response Headers: \(httpResponse.allHeaderFields)")
        if let requestBody = request.httpBody, let requestBodyText = String(data: requestBody, encoding: .utf8) {
            print("Request Body: \(requestBodyText)")
        } else {
            print("Request Body: <nil>")
        }
        if let responseText = String(data: responseBodyData, encoding: .utf8) {
            print("Response Body: \(responseText)")
        } else {
            print("Response Body (base64): \(responseBodyData.base64EncodedString())")
        }
        print("========== [DoufuCodexChat Debug] 结束 ==========")
    }

    private func logInvalidResponseDebug(
        request: URLRequest,
        httpResponse: HTTPURLResponse,
        streamedText: String,
        completedResponseText: String?,
        rawSSEEventPayloads: [String],
        requestLabel: String
    ) {
        print("========== [DoufuCodexChat Debug] invalidResponse ==========")
        print("Request Label: \(requestLabel)")
        print("URL: \(request.url?.absoluteString ?? "nil")")
        print("Status: \(httpResponse.statusCode)")
        print("Response Headers: \(httpResponse.allHeaderFields)")
        if let requestBody = request.httpBody, let requestBodyText = String(data: requestBody, encoding: .utf8) {
            print("Request Body: \(requestBodyText)")
        } else {
            print("Request Body: <nil>")
        }

        let normalizedStreamed = streamedText.trimmingCharacters(in: .whitespacesAndNewlines)
        print("streamedText(empty? \(normalizedStreamed.isEmpty)): \(streamedText)")
        print("completedResponseText: \(completedResponseText ?? "<nil>")")

        print("SSE Event Count: \(rawSSEEventPayloads.count)")
        if rawSSEEventPayloads.isEmpty {
            print("SSE Events: <none>")
        } else {
            for (index, payload) in rawSSEEventPayloads.enumerated() {
                print("----- SSE[\(index)] -----")
                print(payload)
            }
        }
        print("========== [DoufuCodexChat Debug] 结束 ==========")
    }

    private func isChatGPTCodexBackend(url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        let path = url.path.lowercased()
        return host == "chatgpt.com" && path.contains("/backend-api/codex")
    }
}

private struct ResponsesRequest: Encodable {
    let model: String
    let instructions: String?
    let input: [ResponseInputMessage]
    let stream: Bool?
    let store: Bool?
    var reasoning: ResponsesReasoning?
}

private struct ResponsesReasoning: Encodable {
    enum Effort: String, Encodable {
        case high
        case xhigh
    }

    let effort: Effort
}

private struct ResponseInputMessage: Encodable {
    let role: String
    let content: [ResponseInputContent]

    init(role: String, text: String) {
        self.role = role
        let normalizedRole = role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let contentType = normalizedRole == "assistant" ? "output_text" : "input_text"
        content = [ResponseInputContent(type: contentType, text: text)]
    }
}

private struct ResponseInputContent: Encodable {
    let type: String
    let text: String
}

private struct ResponsesResponse: Decodable {
    let output: [ResponsesOutputItem]?
}

private struct ResponsesOutputItem: Decodable {
    let type: String
    let content: [ResponsesOutputContent]?
}

private struct ResponsesOutputContent: Decodable {
    let type: String
    let text: String?
}

private struct ProjectFileSnapshot: Codable {
    let path: String
    let content: String
}

private struct ProjectFileCandidate {
    let path: String
    let content: String
    let byteCount: Int
    let lineCount: Int
    let preview: String
}

private struct ProjectFileCatalogEntry: Codable {
    let path: String
    let byteCount: Int
    let lineCount: Int
    let preview: String
}

private struct FileSelectionPayload: Decodable {
    let selectedPaths: [String]

    private enum CodingKeys: String, CodingKey {
        case selectedPaths = "selected_paths"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        selectedPaths = try container.decodeIfPresent([String].self, forKey: .selectedPaths) ?? []
    }
}

private struct TaskPlan {
    let summary: String
    let tasks: [TaskPlanItem]
}

private struct TaskPlanItem: Codable {
    let title: String
    let goal: String
}

private struct TaskPlanPayload: Decodable {
    let summary: String
    let tasks: [TaskPlanItem]

    private enum CodingKeys: String, CodingKey {
        case summary
        case tasks
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        tasks = try container.decodeIfPresent([TaskPlanItem].self, forKey: .tasks) ?? []
    }
}

private struct MemoryPromptPayload: Encodable {
    let objective: String
    let constraints: [String]
    let changedFiles: [String]
    let todoItems: [String]

    private enum CodingKeys: String, CodingKey {
        case objective
        case constraints
        case changedFiles = "changed_files"
        case todoItems = "todo_items"
    }
}

private struct PatchMemoryUpdate: Decodable {
    let objective: String?
    let constraints: [String]?
    let todoItems: [String]?

    private enum CodingKeys: String, CodingKey {
        case objective
        case constraints
        case todoItems = "todo_items"
    }
}

private struct PatchPayload: Decodable {
    let assistantMessage: String
    let changes: [PatchChange]
    let memoryUpdate: PatchMemoryUpdate?

    private enum CodingKeys: String, CodingKey {
        case assistantMessage = "assistant_message"
        case changes
        case memoryUpdate = "memory_update"
    }
}

private struct PatchChange: Decodable {
    let path: String
    let content: String
}
