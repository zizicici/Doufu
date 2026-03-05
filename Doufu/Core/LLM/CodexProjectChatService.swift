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

    struct ResultPayload {
        let assistantMessage: String
        let changedPaths: [String]
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

    private let maxFilesForContext = 40
    private let maxBytesPerFile = 120_000
    private let model = "gpt-5.3-codex"

    init() {
        jsonEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    func sendAndApply(
        userMessage: String,
        history: [ChatTurn],
        projectURL: URL,
        credential: ProviderCredential,
        onStreamedText: (@MainActor (String) -> Void)? = nil
    ) async throws -> ResultPayload {
        let trimmedMessage = userMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMessage.isEmpty else {
            throw ServiceError.invalidResponse
        }

        let snapshots = try collectProjectFiles(from: projectURL)
        let filesJSON = try encodeFileSnapshotsToJSONString(snapshots)
        let responseText = try await requestCodexResponseStreaming(
            userMessage: trimmedMessage,
            history: history,
            filesJSON: filesJSON,
            credential: credential,
            onStreamedText: onStreamedText
        )
        let patch = try parsePatchPayload(from: responseText)
        let changedPaths = try applyChanges(patch.changes, to: projectURL)

        if !changedPaths.isEmpty {
            AppProjectStore.shared.touchProjectUpdatedAt(projectURL: projectURL)
        }

        let message = patch.assistantMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedMessage = message.isEmpty ? "已完成更新。" : message
        return ResultPayload(assistantMessage: normalizedMessage, changedPaths: changedPaths)
    }

    private func requestCodexResponseStreaming(
        userMessage: String,
        history: [ChatTurn],
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
          ]
        }
        规则：
        1) path 必须是相对路径，禁止以 / 开头，禁止 ..。
        2) 只改与用户需求相关的最小文件集。
        3) 若无需改动，返回 changes: []。
        4) 修改网页时尽量保证可直接运行（html/css/js 一致）。
        """

        let historyItems = history.suffix(12).map { turn in
            ResponseInputMessage(role: turn.role.rawValue, text: turn.text)
        }

        let userPrompt = """
        设备上下文：
        - Platform: iPhone
        - Orientation: portrait
        - 要求：移动优先、Safe Area 完整适配、降低网页感、提升原生感

        当前项目文件（JSON）：
        \(filesJSON)

        用户请求：
        \(userMessage)
        """

        var inputItems: [ResponseInputMessage] = []
        inputItems.append(contentsOf: historyItems)
        inputItems.append(ResponseInputMessage(role: "user", text: userPrompt))

        let initialReasoningEffort = recommendedReasoningEffort(for: userMessage)
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
                    print("[DoufuCodexChat Debug] reasoning xhigh was rejected by backend; retrying with high.")
                    continue
                }

                logFailedResponseDebug(
                    request: request,
                    httpResponse: httpResponse,
                    responseBodyData: data
                )
                let message = parseErrorMessage(from: data) ?? HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
                throw ServiceError.networkFailed("请求失败：\(message)")
            }

            return try await consumeStreamingResponse(
                bytes: bytes,
                request: request,
                httpResponse: httpResponse,
                onStreamedText: onStreamedText,
                timeoutSeconds: timeoutSeconds
            )
        }
    }

    private func consumeStreamingResponse(
        bytes: URLSession.AsyncBytes,
        request: URLRequest,
        httpResponse: HTTPURLResponse,
        onStreamedText: (@MainActor (String) -> Void)?,
        timeoutSeconds: TimeInterval
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
                    rawSSEEventPayloads: rawSSEEventPayloads
                )
                return finalResponseText
            }

            self.logInvalidResponseDebug(
                request: request,
                httpResponse: httpResponse,
                streamedText: streamedText,
                completedResponseText: completedResponseText,
                rawSSEEventPayloads: rawSSEEventPayloads
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

    private func collectProjectFiles(from projectURL: URL) throws -> [ProjectFileSnapshot] {
        guard let enumerator = FileManager.default.enumerator(
            at: projectURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw ServiceError.noProjectFiles
        }

        var snapshots: [ProjectFileSnapshot] = []

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
            let truncatedData = data.prefix(maxBytesPerFile)
            guard let content = String(data: truncatedData, encoding: .utf8) else {
                continue
            }

            snapshots.append(ProjectFileSnapshot(path: relativePath, content: content))
            if snapshots.count >= maxFilesForContext {
                break
            }
        }

        let sorted = snapshots.sorted { $0.path < $1.path }
        guard !sorted.isEmpty else {
            throw ServiceError.noProjectFiles
        }
        return sorted
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
        rawSSEEventPayloads: [String]
    ) {
        print("========== [DoufuCodexChat Debug] HTTP 请求成功 ==========")
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
        responseBodyData: Data
    ) {
        print("========== [DoufuCodexChat Debug] HTTP 请求失败 ==========")
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
        rawSSEEventPayloads: [String]
    ) {
        print("========== [DoufuCodexChat Debug] invalidResponse ==========")
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

private struct PatchPayload: Decodable {
    let assistantMessage: String
    let changes: [PatchChange]

    private enum CodingKeys: String, CodingKey {
        case assistantMessage = "assistant_message"
        case changes
    }
}

private struct PatchChange: Decodable {
    let path: String
    let content: String
}
