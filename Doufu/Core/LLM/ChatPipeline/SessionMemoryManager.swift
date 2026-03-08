//
//  SessionMemoryManager.swift
//  Doufu
//
//  Created by Codex on 2026/03/05.
//

import Foundation

final class SessionMemoryManager {
    private let configuration: ProjectChatConfiguration
    private let jsonEncoder = JSONEncoder()

    init(configuration: ProjectChatConfiguration) {
        self.configuration = configuration
        jsonEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    func normalizedHistoryTurns(
        _ history: [ProjectChatService.ChatTurn],
        excludingLatestUserMessage userMessage: String
    ) -> [ProjectChatService.ChatTurn] {
        var turns = history
        let normalizedUserMessage = userMessage.trimmingCharacters(in: .whitespacesAndNewlines)

        if let last = turns.last,
           last.role == .user,
           last.text.trimmingCharacters(in: .whitespacesAndNewlines) == normalizedUserMessage {
            turns.removeLast()
        }

        return Array(turns.suffix(configuration.maxHistoryTurns))
    }

    func buildHistoryInputMessages(from historyTurns: [ProjectChatService.ChatTurn]) -> [ResponseInputMessage] {
        let turns = Array(historyTurns.suffix(configuration.maxHistoryTurns))
        guard turns.count > configuration.maxHistoryTurnsDirectlyIncluded else {
            return turns.map { ResponseInputMessage(role: $0.role.rawValue, text: $0.text) }
        }

        let olderTurns = Array(turns.dropLast(configuration.maxHistoryTurnsDirectlyIncluded))
        let recentTurns = Array(turns.suffix(configuration.maxHistoryTurnsDirectlyIncluded))

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

    func buildRequestMemory(
        base: ProjectChatService.SessionMemory?,
        latestUserMessage: String
    ) -> ProjectChatService.SessionMemory {
        var memory = base ?? .empty
        if let objective = normalizedMemoryItem(memory.objective, maxCharacters: configuration.maxMemoryObjectiveCharacters) {
            memory.objective = objective
        } else if let inferredObjective = inferObjective(from: latestUserMessage) {
            memory.objective = inferredObjective
        }

        memory.constraints = mergeUniqueItems(
            inferConstraints(from: latestUserMessage),
            memory.constraints,
            limit: configuration.maxMemoryConstraintItems
        )

        if let pendingTodo = pendingTodoItem(for: latestUserMessage) {
            memory.todoItems = mergeUniqueItems(
                [pendingTodo],
                memory.todoItems,
                limit: configuration.maxMemoryTodoItems
            )
        }

        return sanitizeMemory(memory)
    }

    func buildRolledMemory(
        current: ProjectChatService.SessionMemory,
        userMessage: String,
        assistantMessage: String,
        changedPaths: [String],
        modelMemoryUpdate: PatchMemoryUpdate?
    ) -> ProjectChatService.SessionMemory {
        var memory = current

        if let modelMemoryUpdate {
            if let objective = normalizedMemoryItem(
                modelMemoryUpdate.resolvedObjective,
                maxCharacters: configuration.maxMemoryObjectiveCharacters
            ) {
                memory.objective = objective
            }
            let constraints = modelMemoryUpdate.resolvedConstraints
            if !constraints.isEmpty {
                memory.constraints = mergeUniqueItems(
                    constraints,
                    memory.constraints,
                    limit: configuration.maxMemoryConstraintItems
                )
            }
            let todoItems = modelMemoryUpdate.resolvedTodoItems
            if !todoItems.isEmpty {
                memory.todoItems = mergeUniqueItems(
                    todoItems,
                    memory.todoItems,
                    limit: configuration.maxMemoryTodoItems
                )
            }
        }

        memory.constraints = mergeUniqueItems(
            inferConstraints(from: userMessage),
            memory.constraints,
            limit: configuration.maxMemoryConstraintItems
        )

        if !changedPaths.isEmpty {
            memory.changedFiles = mergeUniquePaths(
                changedPaths,
                memory.changedFiles,
                limit: configuration.maxMemoryChangedFiles
            )

            if let completedPending = pendingTodoItem(for: userMessage) {
                memory.todoItems.removeAll { $0 == completedPending }
            }
        } else if let pendingTodo = pendingTodoItem(for: userMessage) {
            memory.todoItems = mergeUniqueItems(
                [pendingTodo],
                memory.todoItems,
                limit: configuration.maxMemoryTodoItems
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

    func rollTodoFromRemainingTasks(
        memory: ProjectChatService.SessionMemory,
        remainingTasks: [TaskPlanItem]
    ) -> ProjectChatService.SessionMemory {
        var nextMemory = memory
        let remainingTodoItems = remainingTasks.map { "Pending: \($0.title) - \($0.goal)" }
        nextMemory.todoItems = sanitizeMemoryItems(remainingTodoItems, limit: configuration.maxMemoryTodoItems)
        return sanitizeMemory(nextMemory)
    }

    func buildTaskRequestText(
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

    func mergeChangedPaths(_ paths: [String], into target: inout [String]) {
        ProjectPathResolver.mergeChangedPaths(paths, into: &target)
    }

    func encodeMemoryToJSONString(_ memory: ProjectChatService.SessionMemory) -> String {
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

    private func summarizeHistoryTurns(_ turns: [ProjectChatService.ChatTurn]) -> String {
        guard !turns.isEmpty else {
            return ""
        }

        var lines: [String] = []
        var currentLength = 0
        for turn in turns {
            let roleLabel = turn.role == .user ? "User" : "Assistant"
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
            if nextLength > configuration.maxHistorySummaryCharacters {
                break
            }
            lines.append(line)
            currentLength = nextLength
        }

        return lines.joined(separator: "\n")
    }

    private func sanitizeMemory(_ memory: ProjectChatService.SessionMemory) -> ProjectChatService.SessionMemory {
        let objective = normalizedMemoryItem(
            memory.objective,
            maxCharacters: configuration.maxMemoryObjectiveCharacters
        ) ?? ""
        let constraints = sanitizeMemoryItems(memory.constraints, limit: configuration.maxMemoryConstraintItems)
        let changedFiles = sanitizeChangedFileItems(memory.changedFiles, limit: configuration.maxMemoryChangedFiles)
        let todoItems = sanitizeMemoryItems(memory.todoItems, limit: configuration.maxMemoryTodoItems)
        return ProjectChatService.SessionMemory(
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
            guard let normalized = normalizedMemoryItem(item, maxCharacters: configuration.maxMemoryItemCharacters) else {
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
            guard let normalized = normalizedMemoryItem(item, maxCharacters: configuration.maxMemoryItemCharacters) else {
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
        normalizedMemoryItem(text, maxCharacters: configuration.maxMemoryObjectiveCharacters)
    }

    private func pendingTodoItem(for text: String) -> String? {
        guard let normalized = normalizedMemoryItem(text, maxCharacters: configuration.maxMemoryItemCharacters) else {
            return nil
        }
        return "Pending: \(normalized)"
    }

    private func inferConstraints(from text: String) -> [String] {
        let lowered = text.lowercased()
        var constraints: [String] = []

        if lowered.contains("iphone") || lowered.contains("ios") || text.contains("移动端") || text.contains("手机") {
            constraints.append("Default target: iPhone portrait")
        }
        if lowered.contains("safe area") || text.contains("safe area") || text.contains("安全区") {
            constraints.append("Must handle Safe Area correctly")
        }
        if text.contains("原生") || text.contains("网页感") || lowered.contains("native") {
            constraints.append("Visual style should be close to native iOS, minimize web-page feel")
        }
        if text.contains("44") || text.contains("触控") || lowered.contains("touch") {
            constraints.append("Key interactive areas must have adequate touch target size")
        }

        return constraints
    }

    private func isSafeRelativePath(_ path: String) -> Bool {
        ProjectPathResolver.isSafeRelativePath(path)
    }
}
