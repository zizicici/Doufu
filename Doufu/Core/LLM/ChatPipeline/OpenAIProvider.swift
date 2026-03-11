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
        enc.outputFormatting = [.sortedKeys]
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
        let sendReasoning = !credential.profile.reasoningEfforts.isEmpty
        var activeRequestBody = ResponsesRequest(
            model: model,
            instructions: developerInstruction,
            input: inputItems,
            stream: true,
            store: isChatGPTCodexBackend(url: credential.baseURL) ? false : nil,
            reasoning: sendReasoning ? ResponsesReasoning(effort: initialReasoningEffort) : nil,
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
                throw ProjectChatService.ServiceError.networkFailed(String(localized: "llm.error.invalid_response"))
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                let data = try await LLMProviderHelpers.consumeStreamBytes(bytes: bytes)

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
                throw ProjectChatService.ServiceError.networkFailed(String(format: String(localized: "llm.error.request_failed_format"), message))
            }

            do {
                let responseResult = try await consumeStreamingResponse(
                    bytes: bytes, request: request, httpResponse: httpResponse,
                    onStreamedText: onStreamedText,
                    timeoutSeconds: timeoutSeconds, requestLabel: requestLabel
                )
                tokenUsageStore.recordUsage(
                    providerID: credential.providerID,
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
        let effort = executionOptions.reasoningEffort
        let timeoutSeconds = LLMProviderHelpers.timeoutSeconds(for: effort, configuration: configuration)

        let inputItems = buildToolUseInputItems(from: conversationItems)
        let isChatGPT = isChatGPTCodexBackend(url: credential.baseURL)
        let useStrict = !isChatGPT && credential.profile.structuredOutputSupported
        let toolDefinitions = tools.map { tool in
            OpenAIToolDefinition(
                name: tool.name,
                description: tool.description,
                parameters: tool.parameters,
                strict: useStrict
            )
        }

        let sendReasoning = !credential.profile.reasoningEfforts.isEmpty
        let requestBody = OpenAIToolUseRequest(
            model: model,
            instructions: systemInstruction,
            input: inputItems,
            tools: toolDefinitions,
            stream: true,
            store: isChatGPT ? false : nil,
            reasoning: sendReasoning ? ResponsesReasoning(effort: effort) : nil
        )

        var request = URLRequest(url: credential.baseURL.appendingPathComponent("responses"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(credential.bearerToken)", forHTTPHeaderField: "Authorization")
        request.setValue("responses=experimental", forHTTPHeaderField: "OpenAI-Beta")
        if let accountID = credential.chatGPTAccountID?.trimmingCharacters(in: .whitespacesAndNewlines), !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: "chatgpt-account-id")
        }
        request.httpBody = try jsonEncoder.encode(requestBody)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProjectChatService.ServiceError.networkFailed(String(localized: "llm.error.invalid_response"))
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let data = try await LLMProviderHelpers.consumeStreamBytes(bytes: bytes)
            let message = LLMProviderHelpers.parseErrorMessage(from: data)
                ?? HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
            throw ProjectChatService.ServiceError.networkFailed(String(format: String(localized: "llm.error.request_failed_format"), message))
        }

        let result = try await consumeToolUseStream(
            bytes: bytes, model: model, credential: credential,
            projectUsageIdentifier: projectUsageIdentifier,
            timeoutSeconds: timeoutSeconds,
            onStreamedText: onStreamedText, onUsage: onUsage
        )
        return result
    }

    // MARK: - Tool Use SSE Stream Consumer

    private func consumeToolUseStream(
        bytes: URLSession.AsyncBytes,
        model: String,
        credential: ProjectChatService.ProviderCredential,
        projectUsageIdentifier: String?,
        timeoutSeconds: TimeInterval,
        onStreamedText: (@MainActor (String) -> Void)?,
        onUsage: ((Int?, Int?) -> Void)?
    ) async throws -> AgentLLMResponse {
        try await LLMProviderHelpers.withStreamTimeout(seconds: timeoutSeconds + configuration.streamCompletionGraceSeconds) { [self] in
            var streamedText = ""
            var toolCalls: [AgentToolCall] = []
            var usage: ResponsesUsage?
            var isIncomplete = false
            // Track in-progress function calls by output_index
            var pendingFuncCalls: [Int: (callID: String, name: String, arguments: String)] = [:]
            var pendingDataLines: [String] = []

            for try await rawLine in bytes.lines {
                let line = rawLine.trimmingCharacters(in: .newlines)
                if line.isEmpty {
                    try await self.processToolUseSSEEvent(
                        from: pendingDataLines,
                        streamedText: &streamedText, toolCalls: &toolCalls,
                        pendingFuncCalls: &pendingFuncCalls, usage: &usage,
                        isIncomplete: &isIncomplete,
                        onStreamedText: onStreamedText
                    )
                    pendingDataLines.removeAll(keepingCapacity: true)
                    continue
                }
                guard line.hasPrefix("data:") else { continue }
                var dataLine = String(line.dropFirst(5))
                if dataLine.hasPrefix(" ") { dataLine.removeFirst() }
                pendingDataLines.append(dataLine)
            }

            // Process any remaining data
            try await self.processToolUseSSEEvent(
                from: pendingDataLines,
                streamedText: &streamedText, toolCalls: &toolCalls,
                pendingFuncCalls: &pendingFuncCalls, usage: &usage,
                isIncomplete: &isIncomplete,
                onStreamedText: onStreamedText
            )

            // When the response was truncated (incomplete), discard any
            // in-progress function calls — their JSON is likely truncated.
            if !isIncomplete {
                for (_, pending) in pendingFuncCalls.sorted(by: { $0.key < $1.key }) {
                    toolCalls.append(AgentToolCall(id: pending.callID, name: pending.name, argumentsJSON: pending.arguments))
                }
            }

            tokenUsageStore.recordUsage(
                providerID: credential.providerID,
                model: model,
                inputTokens: usage?.inputTokens, outputTokens: usage?.outputTokens,
                projectIdentifier: projectUsageIdentifier
            )
            onUsage?(usage?.inputTokens, usage?.outputTokens)

            let stopReason: AgentStopReason
            if isIncomplete {
                stopReason = .maxTokens
            } else {
                stopReason = toolCalls.isEmpty ? .endTurn : .toolUse
            }
            return AgentLLMResponse(
                textContent: streamedText, toolCalls: toolCalls,
                usage: usage, stopReason: stopReason,
                thinkingContent: nil
            )
        }
    }

    private func processToolUseSSEEvent(
        from dataLines: [String],
        streamedText: inout String,
        toolCalls: inout [AgentToolCall],
        pendingFuncCalls: inout [Int: (callID: String, name: String, arguments: String)],
        usage: inout ResponsesUsage?,
        isIncomplete: inout Bool,
        onStreamedText: (@MainActor (String) -> Void)?
    ) async throws {
        guard !dataLines.isEmpty else { return }

        let eventPayload = dataLines.joined(separator: "\n")
        if eventPayload == "[DONE]" { return }

        // Try parsing as single JSON
        if let (obj, eventType) = decodeSSEEvent(from: eventPayload) {
            try await handleToolUseSSEEvent(
                obj, eventType: eventType,
                streamedText: &streamedText, toolCalls: &toolCalls,
                pendingFuncCalls: &pendingFuncCalls, usage: &usage,
                isIncomplete: &isIncomplete,
                onStreamedText: onStreamedText
            )
            return
        }

        // Fallback: try each line individually
        for line in dataLines {
            let candidate = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !candidate.isEmpty, candidate != "[DONE]" else { continue }
            guard let (obj, eventType) = decodeSSEEvent(from: candidate) else { continue }
            try await handleToolUseSSEEvent(
                obj, eventType: eventType,
                streamedText: &streamedText, toolCalls: &toolCalls,
                pendingFuncCalls: &pendingFuncCalls, usage: &usage,
                isIncomplete: &isIncomplete,
                onStreamedText: onStreamedText
            )
        }
    }

    private func handleToolUseSSEEvent(
        _ eventObject: [String: Any],
        eventType: String,
        streamedText: inout String,
        toolCalls: inout [AgentToolCall],
        pendingFuncCalls: inout [Int: (callID: String, name: String, arguments: String)],
        usage: inout ResponsesUsage?,
        isIncomplete: inout Bool,
        onStreamedText: (@MainActor (String) -> Void)?
    ) async throws {
        switch eventType {
        // Text streaming
        case "response.output_text.delta":
            guard let delta = eventObject["delta"] as? String, !delta.isEmpty else { return }
            streamedText.append(delta)
            if let onStreamedText { await onStreamedText(streamedText) }

        // Function call started
        case "response.function_call_arguments.delta":
            let outputIndex = eventObject["output_index"] as? Int ?? 0
            let delta = eventObject["delta"] as? String ?? ""
            if var pending = pendingFuncCalls[outputIndex] {
                pending.arguments += delta
                pendingFuncCalls[outputIndex] = pending
            }

        // Function call item added — capture name and call_id
        case "response.output_item.added":
            guard let item = eventObject["item"] as? [String: Any],
                  (item["type"] as? String) == "function_call"
            else { return }
            let outputIndex = eventObject["output_index"] as? Int ?? 0
            let callID = (item["call_id"] as? String) ?? UUID().uuidString
            let name = item["name"] as? String ?? ""
            pendingFuncCalls[outputIndex] = (callID: callID, name: name, arguments: "")

        // Function call completed
        case "response.output_item.done":
            guard let item = eventObject["item"] as? [String: Any],
                  (item["type"] as? String) == "function_call"
            else { return }
            let outputIndex = eventObject["output_index"] as? Int ?? 0
            if let pending = pendingFuncCalls.removeValue(forKey: outputIndex) {
                // Use the streamed arguments if available, otherwise fall back to the done payload
                let arguments = pending.arguments.isEmpty
                    ? (item["arguments"] as? String ?? "{}")
                    : pending.arguments
                toolCalls.append(AgentToolCall(id: pending.callID, name: pending.name, argumentsJSON: arguments))
            } else {
                // We didn't track it incrementally; parse from the done event
                let callID = (item["call_id"] as? String) ?? UUID().uuidString
                let name = item["name"] as? String ?? ""
                let arguments = item["arguments"] as? String ?? "{}"
                toolCalls.append(AgentToolCall(id: callID, name: name, argumentsJSON: arguments))
            }

        // Response completed — extract usage and any final data
        case "response.completed":
            guard let responseObject = eventObject["response"] as? [String: Any] else { return }
            if let extractedUsage = extractUsage(fromResponseObject: responseObject) {
                usage = extractedUsage
            }
            // Extract any text from the completed response if we missed it during streaming
            if streamedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let text = extractText(fromResponseObject: responseObject),
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                streamedText = text
                if let onStreamedText { await onStreamedText(text) }
            }
            // Extract any function calls from the completed response if we missed them
            if toolCalls.isEmpty, let outputItems = responseObject["output"] as? [[String: Any]] {
                for item in outputItems where (item["type"] as? String) == "function_call" {
                    let callID = (item["call_id"] as? String) ?? UUID().uuidString
                    let name = item["name"] as? String ?? ""
                    let arguments = item["arguments"] as? String ?? "{}"
                    toolCalls.append(AgentToolCall(id: callID, name: name, argumentsJSON: arguments))
                }
            }

        case "error":
            let message = parseStreamingErrorMessage(from: eventObject) ?? String(localized: "llm.error.stream_failed")
            throw ProjectChatService.ServiceError.networkFailed(String(format: String(localized: "llm.error.request_failed_format"), message))

        case "response.failed":
            let message = parseNestedErrorMessage(from: eventObject["response"]) ?? String(localized: "llm.error.response_failed")
            throw ProjectChatService.ServiceError.networkFailed(String(format: String(localized: "llm.error.request_failed_format"), message))

        case "response.incomplete":
            // Mark as truncated so the caller returns .maxTokens instead of
            // throwing — this lets the orchestrator auto-continue.
            isIncomplete = true
            LLMProviderHelpers.debugLog("[Doufu OpenAI] response.incomplete: \(parseIncompleteReason(from: eventObject["response"]) ?? "unknown")")

        default:
            return
        }
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
        try await LLMProviderHelpers.withStreamTimeout(seconds: timeoutSeconds + configuration.streamCompletionGraceSeconds) { [self] in
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
            let message = parseStreamingErrorMessage(from: eventObject) ?? String(localized: "llm.error.stream_failed")
            throw ProjectChatService.ServiceError.networkFailed(String(format: String(localized: "llm.error.request_failed_format"), message))

        case "response.failed":
            let message = parseNestedErrorMessage(from: eventObject["response"]) ?? String(localized: "llm.error.response_failed")
            throw ProjectChatService.ServiceError.networkFailed(String(format: String(localized: "llm.error.request_failed_format"), message))

        case "response.incomplete":
            let message = parseIncompleteReason(from: eventObject["response"]) ?? String(localized: "llm.error.response_incomplete")
            throw ProjectChatService.ServiceError.networkFailed(String(format: String(localized: "llm.error.request_failed_format"), message))

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
