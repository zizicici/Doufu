//
//  LLMStreamingClient.swift
//  Doufu
//
//  Created by Codex on 2026/03/05.
//

import Foundation

final class LLMStreamingClient {
    private let configuration: CodexChatConfiguration
    private let jsonDecoder = JSONDecoder()
    private let jsonEncoder = JSONEncoder()

    init(configuration: CodexChatConfiguration) {
        self.configuration = configuration
        jsonEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    func requestModelResponseStreaming(
        requestLabel: String,
        model: String,
        developerInstruction: String,
        inputItems: [ResponseInputMessage],
        credential: CodexProjectChatService.ProviderCredential,
        initialReasoningEffort: ResponsesReasoning.Effort,
        responseFormat: ResponsesTextFormat?,
        onStreamedText: (@MainActor (String) -> Void)?
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
            let timeoutSeconds: TimeInterval
            switch activeRequestBody.reasoning?.effort ?? .high {
            case .low:
                timeoutSeconds = configuration.lowReasoningTimeoutSeconds
            case .medium:
                timeoutSeconds = configuration.mediumReasoningTimeoutSeconds
            case .high:
                timeoutSeconds = configuration.highReasoningTimeoutSeconds
            case .xhigh:
                timeoutSeconds = configuration.xhighReasoningTimeoutSeconds
            }
            request.timeoutInterval = timeoutSeconds
            if let accountID = credential.chatGPTAccountID?.trimmingCharacters(in: .whitespacesAndNewlines), !accountID.isEmpty {
                request.setValue(accountID, forHTTPHeaderField: "chatgpt-account-id")
            }
            request.httpBody = try jsonEncoder.encode(activeRequestBody)

            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw CodexProjectChatService.ServiceError.networkFailed("请求失败：无效响应。")
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
                    debugLog("[DoufuCodexChat Debug] reasoning xhigh was rejected by backend; retrying with high. stage=\(requestLabel)")
                    continue
                }

                if shouldFallbackResponseFormat(
                    textConfiguration: activeRequestBody.text,
                    responseBodyData: data,
                    alreadyFallback: didFallbackResponseFormat
                ) {
                    didFallbackResponseFormat = true
                    activeRequestBody.text = nil
                    debugLog("[DoufuCodexChat Debug] text.format json_schema was rejected by backend; retrying without response_format. stage=\(requestLabel)")
                    continue
                }

                logFailedResponseDebug(
                    request: request,
                    httpResponse: httpResponse,
                    responseBodyData: data,
                    requestLabel: requestLabel
                )
                let message = parseErrorMessage(from: data) ?? HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
                throw CodexProjectChatService.ServiceError.networkFailed("请求失败：\(message)")
            }

            do {
                return try await consumeStreamingResponse(
                    bytes: bytes,
                    request: request,
                    httpResponse: httpResponse,
                    onStreamedText: onStreamedText,
                    timeoutSeconds: timeoutSeconds,
                    requestLabel: requestLabel
                )
            } catch let serviceError as CodexProjectChatService.ServiceError {
                guard case let .networkFailed(errorMessage) = serviceError else {
                    throw serviceError
                }

                if shouldFallbackReasoningToHigh(
                    currentEffort: activeRequestBody.reasoning?.effort,
                    errorMessage: errorMessage,
                    alreadyFallback: didFallbackReasoning
                ) {
                    didFallbackReasoning = true
                    activeRequestBody.reasoning = ResponsesReasoning(effort: .high)
                    debugLog("[DoufuCodexChat Debug] reasoning xhigh was rejected during streaming; retrying with high. stage=\(requestLabel)")
                    continue
                }

                if shouldFallbackResponseFormat(
                    textConfiguration: activeRequestBody.text,
                    errorMessage: errorMessage,
                    alreadyFallback: didFallbackResponseFormat
                ) {
                    didFallbackResponseFormat = true
                    activeRequestBody.text = nil
                    debugLog("[DoufuCodexChat Debug] text.format json_schema was rejected during streaming; retrying without response_format. stage=\(requestLabel)")
                    continue
                }

                throw serviceError
            }
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
        return try await withTimeout(seconds: timeoutSeconds + configuration.streamCompletionGraceSeconds) { [self] in
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
            throw CodexProjectChatService.ServiceError.invalidResponse
        }
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
            group.addTask {
                let nanoseconds = UInt64(max(1, seconds) * 1_000_000_000)
                try await Task.sleep(nanoseconds: nanoseconds)
                throw CodexProjectChatService.ServiceError.networkFailed("请求超时，请重试。")
            }

            guard let first = try await group.next() else {
                group.cancelAll()
                throw CodexProjectChatService.ServiceError.networkFailed("请求失败，请重试。")
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
            throw CodexProjectChatService.ServiceError.networkFailed("请求失败：\(message)")

        case "response.failed":
            let message = parseNestedErrorMessage(from: eventObject["response"]) ?? "响应失败。"
            throw CodexProjectChatService.ServiceError.networkFailed("请求失败：\(message)")

        case "response.incomplete":
            let message = parseIncompleteReason(from: eventObject["response"]) ?? "响应不完整。"
            throw CodexProjectChatService.ServiceError.networkFailed("请求失败：\(message)")

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

    private func shouldFallbackReasoningToHigh(
        currentEffort: ResponsesReasoning.Effort?,
        responseBodyData: Data,
        alreadyFallback: Bool
    ) -> Bool {
        let message = parseErrorMessage(from: responseBodyData) ?? ""
        return shouldFallbackReasoningToHigh(
            currentEffort: currentEffort,
            errorMessage: message,
            alreadyFallback: alreadyFallback
        )
    }

    private func shouldFallbackReasoningToHigh(
        currentEffort: ResponsesReasoning.Effort?,
        errorMessage: String,
        alreadyFallback: Bool
    ) -> Bool {
        guard !alreadyFallback else {
            return false
        }
        guard currentEffort == .xhigh else {
            return false
        }

        let message = errorMessage.lowercased()
        if message.contains("reasoning") && message.contains("effort") {
            return true
        }
        if message.contains("xhigh") && (message.contains("invalid") || message.contains("unsupported")) {
            return true
        }
        return false
    }

    private func shouldFallbackResponseFormat(
        textConfiguration: ResponsesTextConfiguration?,
        responseBodyData: Data,
        alreadyFallback: Bool
    ) -> Bool {
        let message = parseErrorMessage(from: responseBodyData) ?? ""
        return shouldFallbackResponseFormat(
            textConfiguration: textConfiguration,
            errorMessage: message,
            alreadyFallback: alreadyFallback
        )
    }

    private func shouldFallbackResponseFormat(
        textConfiguration: ResponsesTextConfiguration?,
        errorMessage: String,
        alreadyFallback: Bool
    ) -> Bool {
        guard !alreadyFallback else {
            return false
        }
        guard textConfiguration != nil else {
            return false
        }

        let message = errorMessage.lowercased()
        if message.contains("text.format") {
            return true
        }
        if message.contains("json_schema") {
            return true
        }
        if message.contains("unsupported") && message.contains("format") {
            return true
        }
        if message.contains("schema") && message.contains("invalid") {
            return true
        }
        return false
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

    private func debugLog(_ message: @autoclosure () -> String) {
#if DEBUG
        print(message())
#endif
    }

    private func truncatedDebugText(_ value: String) -> String {
        guard value.count > configuration.maxDebugTextCharacters else {
            return value
        }
        return String(value.prefix(configuration.maxDebugTextCharacters)) + "...(truncated)"
    }

    private func logSuccessfulResponseDebug(
        request: URLRequest,
        httpResponse: HTTPURLResponse,
        finalResponseText: String,
        rawSSEEventPayloads: [String],
        requestLabel: String
    ) {
#if DEBUG
        print("========== [DoufuCodexChat Debug] HTTP 请求成功 ==========")
        print("Request Label: \(requestLabel)")
        print("URL: \(request.url?.absoluteString ?? "nil")")
        print("Status: \(httpResponse.statusCode)")
        print("Response Headers: \(httpResponse.allHeaderFields)")
        print("Request Body: <redacted>")
        print("Final Response Text: \(truncatedDebugText(finalResponseText))")
        print("SSE Event Count: \(rawSSEEventPayloads.count)")
        if rawSSEEventPayloads.isEmpty {
            print("SSE Events: <none>")
        } else {
            for (index, payload) in rawSSEEventPayloads.enumerated() {
                print("----- SSE[\(index)] -----")
                print(truncatedDebugText(payload))
            }
        }
        print("========== [DoufuCodexChat Debug] 结束 ==========")
#endif
    }

    private func logFailedResponseDebug(
        request: URLRequest,
        httpResponse: HTTPURLResponse,
        responseBodyData: Data,
        requestLabel: String
    ) {
#if DEBUG
        print("========== [DoufuCodexChat Debug] HTTP 请求失败 ==========")
        print("Request Label: \(requestLabel)")
        print("URL: \(request.url?.absoluteString ?? "nil")")
        print("Status: \(httpResponse.statusCode)")
        print("Response Headers: \(httpResponse.allHeaderFields)")
        print("Request Body: <redacted>")
        if let responseText = String(data: responseBodyData, encoding: .utf8) {
            print("Response Body: \(truncatedDebugText(responseText))")
        } else {
            print("Response Body (base64): \(responseBodyData.base64EncodedString())")
        }
        print("========== [DoufuCodexChat Debug] 结束 ==========")
#endif
    }

    private func logInvalidResponseDebug(
        request: URLRequest,
        httpResponse: HTTPURLResponse,
        streamedText: String,
        completedResponseText: String?,
        rawSSEEventPayloads: [String],
        requestLabel: String
    ) {
#if DEBUG
        print("========== [DoufuCodexChat Debug] invalidResponse ==========")
        print("Request Label: \(requestLabel)")
        print("URL: \(request.url?.absoluteString ?? "nil")")
        print("Status: \(httpResponse.statusCode)")
        print("Response Headers: \(httpResponse.allHeaderFields)")
        print("Request Body: <redacted>")

        let normalizedStreamed = streamedText.trimmingCharacters(in: .whitespacesAndNewlines)
        print("streamedText(empty? \(normalizedStreamed.isEmpty)): \(truncatedDebugText(streamedText))")
        print("completedResponseText: \(truncatedDebugText(completedResponseText ?? "<nil>"))")

        print("SSE Event Count: \(rawSSEEventPayloads.count)")
        if rawSSEEventPayloads.isEmpty {
            print("SSE Events: <none>")
        } else {
            for (index, payload) in rawSSEEventPayloads.enumerated() {
                print("----- SSE[\(index)] -----")
                print(truncatedDebugText(payload))
            }
        }
        print("========== [DoufuCodexChat Debug] 结束 ==========")
#endif
    }

    private func isChatGPTCodexBackend(url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        let path = url.path.lowercased()
        return host == "chatgpt.com" && path.contains("/backend-api/codex")
    }
}
