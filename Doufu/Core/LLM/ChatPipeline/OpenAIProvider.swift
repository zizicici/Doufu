//
//  OpenAIProvider.swift
//  Doufu
//
//  Created by Codex on 2026/03/08.
//

import Foundation

final class OpenAIProvider: LLMProviderAdapter {
    private let configuration: ProjectChatConfiguration
    private let jsonDecoder = JSONDecoder()
    private let jsonEncoder: JSONEncoder = {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return enc
    }()

    private let tokenUsageStore = LLMTokenUsageStore.shared

    init(configuration: ProjectChatConfiguration) {
        self.configuration = configuration
    }

    // MARK: - Streaming (non-tool-use)

    func requestStreaming(
        requestLabel: String,
        model: String,
        developerInstruction: String,
        inputItems: [ResponseInputMessage],
        credential: ProjectChatService.ProviderCredential,
        projectUsageIdentifier: String?,
        initialReasoningEffort: ResponsesReasoning.Effort,
        executionOptions: ProjectChatService.ModelExecutionOptions,
        responseFormat: ResponsesTextFormat?,
        onStreamedText: (@MainActor (String) -> Void)?,
        onUsage: ((Int?, Int?) -> Void)?
    ) async throws -> String {
        var activeRequestBody = ResponsesRequest(
            model: model,
            instructions: developerInstruction,
            input: inputItems,
            stream: true,
            store: isChatGPTCodexBackend(url: credential.baseURL) ? false : nil,
            reasoning: ResponsesReasoning(effort: initialReasoningEffort),
            text: responseFormat.map { ResponsesTextConfiguration(format: $0) }
        )
        var didFallbackReasoning = false
        var didFallbackResponseFormat = false

        while true {
            var request = URLRequest(url: credential.baseURL.appendingPathComponent("responses"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            request.setValue("Bearer \(credential.bearerToken)", forHTTPHeaderField: "Authorization")
            request.setValue("responses=experimental", forHTTPHeaderField: "OpenAI-Beta")
            request.setValue("codex_cli_rs", forHTTPHeaderField: "originator")
            let timeoutSeconds = LLMProviderHelpers.timeoutSeconds(
                for: activeRequestBody.reasoning?.effort ?? .high,
                configuration: configuration
            )
            request.timeoutInterval = timeoutSeconds
            if let accountID = credential.chatGPTAccountID?.trimmingCharacters(in: .whitespacesAndNewlines), !accountID.isEmpty {
                request.setValue(accountID, forHTTPHeaderField: "chatgpt-account-id")
            }
            request.httpBody = try jsonEncoder.encode(activeRequestBody)

            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw ProjectChatService.ServiceError.networkFailed("请求失败：无效响应。")
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                let data = try await consumeStreamBytes(bytes: bytes)

                if shouldFallbackReasoningToHigh(
                    currentEffort: activeRequestBody.reasoning?.effort,
                    responseBodyData: data,
                    alreadyFallback: didFallbackReasoning
                ) {
                    didFallbackReasoning = true
                    activeRequestBody.reasoning = ResponsesReasoning(effort: .high)
                    continue
                }

                if shouldFallbackResponseFormat(
                    textConfiguration: activeRequestBody.text,
                    responseBodyData: data,
                    alreadyFallback: didFallbackResponseFormat
                ) {
                    didFallbackResponseFormat = true
                    activeRequestBody.text = nil
                    continue
                }

                LLMProviderHelpers.logFailedResponse(
                    request: request, httpResponse: httpResponse,
                    responseBodyData: data, requestLabel: requestLabel
                )
                let message = LLMProviderHelpers.parseErrorMessage(from: data) ?? HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
                throw ProjectChatService.ServiceError.networkFailed("请求失败：\(message)")
            }

            do {
                let responseResult = try await consumeStreamingResponse(
                    bytes: bytes, request: request, httpResponse: httpResponse,
                    onStreamedText: onStreamedText,
                    timeoutSeconds: timeoutSeconds, requestLabel: requestLabel
                )
                tokenUsageStore.recordUsage(
                    providerID: credential.providerID, providerLabel: credential.providerLabel,
                    model: model,
                    inputTokens: responseResult.usage?.inputTokens,
                    outputTokens: responseResult.usage?.outputTokens,
                    projectIdentifier: projectUsageIdentifier
                )
                onUsage?(responseResult.usage?.inputTokens, responseResult.usage?.outputTokens)
                return responseResult.text
            } catch let serviceError as ProjectChatService.ServiceError {
                guard case let .networkFailed(errorMessage) = serviceError else { throw serviceError }

                if shouldFallbackReasoningToHigh(
                    currentEffort: activeRequestBody.reasoning?.effort,
                    errorMessage: errorMessage,
                    alreadyFallback: didFallbackReasoning
                ) {
                    didFallbackReasoning = true
                    activeRequestBody.reasoning = ResponsesReasoning(effort: .high)
                    continue
                }

                if shouldFallbackResponseFormat(
                    textConfiguration: activeRequestBody.text,
                    errorMessage: errorMessage,
                    alreadyFallback: didFallbackResponseFormat
                ) {
                    didFallbackResponseFormat = true
                    activeRequestBody.text = nil
                    continue
                }

                throw serviceError
            }
        }
    }

    // MARK: - Tool Use

    func requestWithTools(
        systemInstruction: String,
        conversationItems: [AgentConversationItem],
        tools: [AgentToolDefinition],
        credential: ProjectChatService.ProviderCredential,
        projectUsageIdentifier: String?,
        executionOptions: ProjectChatService.ModelExecutionOptions,
        onStreamedText: (@MainActor (String) -> Void)?,
        onUsage: ((Int?, Int?) -> Void)?
    ) async throws -> AgentLLMResponse {
        let model = credential.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let timeoutSeconds = LLMProviderHelpers.timeoutSeconds(for: .high, configuration: configuration)

        let inputItems = buildToolUseInputItems(from: conversationItems)
        let toolDefinitions = tools.map { tool in
            OpenAIToolDefinition(
                name: tool.name,
                description: tool.description,
                parameters: tool.parameters,
                strict: true
            )
        }

        let requestBody = OpenAIToolUseRequest(
            model: model,
            instructions: systemInstruction,
            input: inputItems,
            tools: toolDefinitions,
            stream: false,
            store: isChatGPTCodexBackend(url: credential.baseURL) ? false : nil
        )

        var request = URLRequest(url: credential.baseURL.appendingPathComponent("responses"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(credential.bearerToken)", forHTTPHeaderField: "Authorization")
        request.setValue("responses=experimental", forHTTPHeaderField: "OpenAI-Beta")
        if let accountID = credential.chatGPTAccountID?.trimmingCharacters(in: .whitespacesAndNewlines), !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: "chatgpt-account-id")
        }
        request.httpBody = try jsonEncoder.encode(requestBody)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProjectChatService.ServiceError.networkFailed("Invalid response")
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let message = LLMProviderHelpers.parseErrorMessage(from: data)
                ?? HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
            throw ProjectChatService.ServiceError.networkFailed(message)
        }

        guard let responseObj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let outputItems = responseObj["output"] as? [[String: Any]]
        else {
            throw ProjectChatService.ServiceError.invalidResponse
        }

        // Parse usage
        var usage: ResponsesUsage?
        if let usageData = try? JSONSerialization.data(withJSONObject: responseObj["usage"] ?? [:]),
           let decoded = try? jsonDecoder.decode(ResponsesUsage.self, from: usageData) {
            usage = decoded
        }
        tokenUsageStore.recordUsage(
            providerID: credential.providerID, providerLabel: credential.providerLabel,
            model: model,
            inputTokens: usage?.inputTokens, outputTokens: usage?.outputTokens,
            projectIdentifier: projectUsageIdentifier
        )
        onUsage?(usage?.inputTokens, usage?.outputTokens)

        var textContent = ""
        var toolCalls: [AgentToolCall] = []

        for item in outputItems {
            let type = item["type"] as? String ?? ""
            switch type {
            case "message":
                if let contentBlocks = item["content"] as? [[String: Any]] {
                    for block in contentBlocks {
                        if let text = block["text"] as? String { textContent += text }
                    }
                }
            case "function_call":
                let callID = (item["call_id"] as? String) ?? (item["id"] as? String) ?? UUID().uuidString
                let name = item["name"] as? String ?? ""
                let arguments = item["arguments"] as? String ?? "{}"
                toolCalls.append(AgentToolCall(id: callID, name: name, argumentsJSON: arguments))
            default:
                break
            }
        }

        if let onStreamedText, !textContent.isEmpty {
            await onStreamedText(textContent)
        }

        let stopReason: AgentStopReason = toolCalls.isEmpty ? .endTurn : .toolUse
        return AgentLLMResponse(textContent: textContent, toolCalls: toolCalls, usage: usage, stopReason: stopReason)
    }

    // MARK: - Build Input Items

    private func buildToolUseInputItems(from items: [AgentConversationItem]) -> [OpenAIToolUseInputItem] {
        var result: [OpenAIToolUseInputItem] = []
        for item in items {
            switch item {
            case let .userMessage(text):
                result.append(.message(OpenAIToolUseMessage(
                    role: "user",
                    content: [OpenAIToolUseContent(type: "input_text", text: text)]
                )))
            case let .assistantMessage(text, toolCalls):
                if !text.isEmpty {
                    result.append(.message(OpenAIToolUseMessage(
                        role: "assistant",
                        content: [OpenAIToolUseContent(type: "output_text", text: text)]
                    )))
                }
                for tc in toolCalls {
                    result.append(.functionCall(OpenAIFunctionCallItem(
                        callID: tc.id, name: tc.name, arguments: tc.argumentsJSON
                    )))
                }
            case let .toolResult(callID, _, content, _):
                result.append(.functionCallOutput(OpenAIFunctionCallOutputItem(
                    callID: callID, output: content
                )))
            }
        }
        return result
    }

    // MARK: - SSE Streaming

    private struct StreamingResponseResult {
        let text: String
        let usage: ResponsesUsage?
    }

    private func consumeStreamingResponse(
        bytes: URLSession.AsyncBytes,
        request: URLRequest,
        httpResponse: HTTPURLResponse,
        onStreamedText: (@MainActor (String) -> Void)?,
        timeoutSeconds: TimeInterval,
        requestLabel: String
    ) async throws -> StreamingResponseResult {
        try await withTimeout(seconds: timeoutSeconds + configuration.streamCompletionGraceSeconds) { [self] in
            var streamedText = ""
            var completedResponseText: String?
            var usage: ResponsesUsage?
            var pendingDataLines: [String] = []

            for try await rawLine in bytes.lines {
                let line = rawLine.trimmingCharacters(in: .newlines)
                if line.isEmpty {
                    try await self.processSSEEvent(
                        from: pendingDataLines, streamedText: &streamedText,
                        completedResponseText: &completedResponseText,
                        usage: &usage, onStreamedText: onStreamedText
                    )
                    pendingDataLines.removeAll(keepingCapacity: true)
                    continue
                }
                guard line.hasPrefix("data:") else { continue }
                var dataLine = String(line.dropFirst(5))
                if dataLine.hasPrefix(" ") { dataLine.removeFirst() }
                pendingDataLines.append(dataLine)
            }

            try await self.processSSEEvent(
                from: pendingDataLines, streamedText: &streamedText,
                completedResponseText: &completedResponseText,
                usage: &usage, onStreamedText: onStreamedText
            )

            let normalizedStreamedText = streamedText.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedCompletedText = completedResponseText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            let finalResponseText: String?
            if !normalizedStreamedText.isEmpty {
                finalResponseText = normalizedStreamedText
            } else if !normalizedCompletedText.isEmpty {
                finalResponseText = normalizedCompletedText
            } else {
                finalResponseText = nil
            }

            if let finalResponseText {
                LLMProviderHelpers.logSuccessfulResponse(
                    request: request, httpResponse: httpResponse,
                    finalResponseText: finalResponseText, usage: usage,
                    requestLabel: requestLabel
                )
                return StreamingResponseResult(text: finalResponseText, usage: usage)
            }

            throw ProjectChatService.ServiceError.invalidResponse
        }
    }

    private func processSSEEvent(
        from dataLines: [String],
        streamedText: inout String,
        completedResponseText: inout String?,
        usage: inout ResponsesUsage?,
        onStreamedText: (@MainActor (String) -> Void)?
    ) async throws {
        guard !dataLines.isEmpty else { return }

        let eventPayload = dataLines.joined(separator: "\n")
        if eventPayload == "[DONE]" { return }

        if let (eventObject, eventType) = decodeSSEEvent(from: eventPayload) {
            try await handleSSEEventObject(
                eventObject, eventType: eventType,
                streamedText: &streamedText,
                completedResponseText: &completedResponseText,
                usage: &usage, onStreamedText: onStreamedText
            )
            return
        }

        for line in dataLines {
            let candidate = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !candidate.isEmpty, candidate != "[DONE]" else { continue }
            guard let (eventObject, eventType) = decodeSSEEvent(from: candidate) else { continue }
            try await handleSSEEventObject(
                eventObject, eventType: eventType,
                streamedText: &streamedText,
                completedResponseText: &completedResponseText,
                usage: &usage, onStreamedText: onStreamedText
            )
        }
    }

    private func handleSSEEventObject(
        _ eventObject: [String: Any],
        eventType: String,
        streamedText: inout String,
        completedResponseText: inout String?,
        usage: inout ResponsesUsage?,
        onStreamedText: (@MainActor (String) -> Void)?
    ) async throws {
        switch eventType {
        case "response.output_text.delta":
            guard let delta = eventObject["delta"] as? String, !delta.isEmpty else { return }
            streamedText.append(delta)
            if let onStreamedText { await onStreamedText(streamedText) }

        case "response.output_text.done":
            guard streamedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let text = extractPlainText(from: eventObject["text"]),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return }
            completedResponseText = text
            if let onStreamedText { await onStreamedText(text) }

        case "response.output_item.done", "response.output_item.added":
            guard streamedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let itemObject = eventObject["item"] as? [String: Any],
                  let text = extractText(fromOutputItemObject: itemObject),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return }
            completedResponseText = text
            if let onStreamedText { await onStreamedText(text) }

        case "response.completed":
            guard let responseObject = eventObject["response"] as? [String: Any] else { return }
            if let extractedUsage = extractUsage(fromResponseObject: responseObject) {
                usage = extractedUsage
            }
            if let text = extractText(fromResponseObject: responseObject),
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                completedResponseText = text
                if streamedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let onStreamedText {
                    await onStreamedText(text)
                }
            }
            if let responseData = try? JSONSerialization.data(withJSONObject: responseObject),
               let decodedResponse = try? jsonDecoder.decode(ResponsesResponse.self, from: responseData) {
                if usage == nil, let decodedUsage = decodedResponse.usage { usage = decodedUsage }
                if let text = extractOutputText(from: decodedResponse),
                   !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    if completedResponseText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
                        completedResponseText = text
                    }
                    if streamedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       let onStreamedText, let finalText = completedResponseText {
                        await onStreamedText(finalText)
                    }
                }
            }

        case "error":
            let message = parseStreamingErrorMessage(from: eventObject) ?? "流式响应失败。"
            throw ProjectChatService.ServiceError.networkFailed("请求失败：\(message)")

        case "response.failed":
            let message = parseNestedErrorMessage(from: eventObject["response"]) ?? "响应失败。"
            throw ProjectChatService.ServiceError.networkFailed("请求失败：\(message)")

        case "response.incomplete":
            let message = parseIncompleteReason(from: eventObject["response"]) ?? "响应不完整。"
            throw ProjectChatService.ServiceError.networkFailed("请求失败：\(message)")

        default:
            return
        }
    }

    // MARK: - Helpers

    private func isChatGPTCodexBackend(url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        let path = url.path.lowercased()
        return host == "chatgpt.com" && path.contains("/backend-api/codex")
    }

    private func withTimeout<T>(seconds: TimeInterval, operation: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                let nanoseconds = UInt64(max(1, seconds) * 1_000_000_000)
                try await Task.sleep(nanoseconds: nanoseconds)
                throw ProjectChatService.ServiceError.networkFailed("请求超时，请重试。")
            }
            guard let first = try await group.next() else {
                group.cancelAll()
                throw ProjectChatService.ServiceError.networkFailed("请求失败，请重试。")
            }
            group.cancelAll()
            return first
        }
    }

    private func consumeStreamBytes(bytes: URLSession.AsyncBytes) async throws -> Data {
        var data = Data()
        for try await byte in bytes { data.append(byte) }
        return data
    }

    private func decodeSSEEvent(from payload: String) -> ([String: Any], String)? {
        guard let data = payload.data(using: .utf8),
              let eventObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let eventType = eventObject["type"] as? String
        else { return nil }
        return (eventObject, eventType)
    }

    private func extractPlainText(from value: Any?) -> String? {
        if let text = value as? String { return text }
        if let textObject = value as? [String: Any], let valueText = textObject["value"] as? String { return valueText }
        return nil
    }

    private func extractOutputText(from response: ResponsesResponse) -> String? {
        let segments = (response.output ?? []).compactMap { outputItem -> String? in
            guard outputItem.type == "message" else { return nil }
            let texts = (outputItem.content ?? []).compactMap { contentItem -> String? in
                (contentItem.type == "output_text" || contentItem.type == "text") ? contentItem.text : nil
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
        guard let outputItems = responseObject["output"] as? [[String: Any]] else { return nil }
        let texts = outputItems.compactMap { extractText(fromOutputItemObject: $0) }
        let merged = texts.joined(separator: "\n")
        return merged.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : merged
    }

    private func extractUsage(fromResponseObject responseObject: [String: Any]) -> ResponsesUsage? {
        guard let usageObject = responseObject["usage"] as? [String: Any],
              let usageData = try? JSONSerialization.data(withJSONObject: usageObject),
              let usage = try? jsonDecoder.decode(ResponsesUsage.self, from: usageData)
        else { return nil }
        return usage
    }

    private func extractText(fromOutputItemObject outputItem: [String: Any]) -> String? {
        if let directText = extractPlainText(from: outputItem["text"]),
           !directText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return directText
        }
        guard let contentItems = outputItem["content"] as? [Any] else { return nil }
        let texts = contentItems.compactMap { contentObject -> String? in
            guard let dictionary = contentObject as? [String: Any] else { return nil }
            let contentType = (dictionary["type"] as? String)?.lowercased() ?? ""
            guard contentType == "output_text" || contentType == "text" || contentType == "input_text" else { return nil }
            return extractPlainText(from: dictionary["text"])
        }
        let merged = texts.joined(separator: "\n")
        return merged.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : merged
    }

    private func parseStreamingErrorMessage(from eventObject: [String: Any]) -> String? {
        if let errorObject = eventObject["error"] as? [String: Any],
           let message = errorObject["message"] as? String,
           !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return message
        }
        if let message = eventObject["message"] as? String,
           !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return message
        }
        return nil
    }

    private func parseNestedErrorMessage(from responseObject: Any?) -> String? {
        guard let response = responseObject as? [String: Any],
              let error = response["error"] as? [String: Any],
              let message = error["message"] as? String,
              !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return message
    }

    private func parseIncompleteReason(from responseObject: Any?) -> String? {
        guard let response = responseObject as? [String: Any],
              let details = response["incomplete_details"] as? [String: Any],
              let reason = details["reason"] as? String,
              !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return reason
    }

    // MARK: - Fallback Logic

    private func shouldFallbackReasoningToHigh(
        currentEffort: ResponsesReasoning.Effort?,
        responseBodyData: Data,
        alreadyFallback: Bool
    ) -> Bool {
        let message = LLMProviderHelpers.parseErrorMessage(from: responseBodyData) ?? ""
        return shouldFallbackReasoningToHigh(currentEffort: currentEffort, errorMessage: message, alreadyFallback: alreadyFallback)
    }

    private func shouldFallbackReasoningToHigh(
        currentEffort: ResponsesReasoning.Effort?,
        errorMessage: String,
        alreadyFallback: Bool
    ) -> Bool {
        guard !alreadyFallback, currentEffort == .xhigh else { return false }
        let message = errorMessage.lowercased()
        if message.contains("reasoning") && message.contains("effort") { return true }
        if message.contains("xhigh") && (message.contains("invalid") || message.contains("unsupported")) { return true }
        return false
    }

    private func shouldFallbackResponseFormat(
        textConfiguration: ResponsesTextConfiguration?,
        responseBodyData: Data,
        alreadyFallback: Bool
    ) -> Bool {
        let message = LLMProviderHelpers.parseErrorMessage(from: responseBodyData) ?? ""
        return shouldFallbackResponseFormat(textConfiguration: textConfiguration, errorMessage: message, alreadyFallback: alreadyFallback)
    }

    private func shouldFallbackResponseFormat(
        textConfiguration: ResponsesTextConfiguration?,
        errorMessage: String,
        alreadyFallback: Bool
    ) -> Bool {
        guard !alreadyFallback, textConfiguration != nil else { return false }
        let message = errorMessage.lowercased()
        if message.contains("text.format") { return true }
        if message.contains("json_schema") { return true }
        if message.contains("unsupported") && message.contains("format") { return true }
        if message.contains("schema") && message.contains("invalid") { return true }
        return false
    }
}
