//
//  LLMProviderProtocol.swift
//  Doufu
//
//  Created by Codex on 2026/03/08.
//

import Foundation

protocol LLMProviderAdapter {
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
    ) async throws -> String

    func requestWithTools(
        systemInstruction: String,
        conversationItems: [AgentConversationItem],
        tools: [AgentToolDefinition],
        credential: ProjectChatService.ProviderCredential,
        projectUsageIdentifier: String?,
        executionOptions: ProjectChatService.ModelExecutionOptions,
        onStreamedText: (@MainActor (String) -> Void)?,
        onUsage: ((Int?, Int?) -> Void)?
    ) async throws -> AgentLLMResponse
}

// MARK: - Shared Helpers

struct LLMProviderHelpers {
    static func parseErrorMessage(from data: Data) -> String? {
        guard !data.isEmpty else { return nil }

        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = json["error"] as? [String: Any],
           let message = error["message"] as? String,
           !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return message
        }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let message = json["message"] as? String,
           !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return message
        }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let detail = json["detail"] as? String,
           !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return detail
        }
        if let rawText = String(data: data, encoding: .utf8) {
            let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    static func normalizedConversationMessages(
        from inputItems: [ResponseInputMessage],
        assistantRole: String,
        userRole: String
    ) -> [(role: String, text: String)] {
        inputItems.compactMap { input in
            let normalizedRole = input.role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let role: String
            switch normalizedRole {
            case "assistant": role = assistantRole
            case "user": role = userRole
            default: return nil
            }
            let text = input.content.map(\.text).joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return (role: role, text: text)
        }
    }

    static func timeoutSeconds(
        for effort: ResponsesReasoning.Effort,
        configuration: ProjectChatConfiguration
    ) -> TimeInterval {
        switch effort {
        case .low: return configuration.lowReasoningTimeoutSeconds
        case .medium: return configuration.mediumReasoningTimeoutSeconds
        case .high: return configuration.highReasoningTimeoutSeconds
        case .xhigh: return configuration.xhighReasoningTimeoutSeconds
        }
    }

    static func shouldFallbackThinkingConfiguration(responseBodyData: Data) -> Bool {
        let message = parseErrorMessage(from: responseBodyData)?.lowercased() ?? ""
        guard !message.isEmpty else { return false }
        return message.contains("thinking") || message.contains("budget")
    }

    static func parseJSONToJSONValue(_ jsonString: String) -> JSONValue {
        guard let data = jsonString.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .object([:]) }
        return jsonObjectToJSONValue(obj)
    }

    static func jsonObjectToJSONValue(_ obj: [String: Any]) -> JSONValue {
        var result: [String: JSONValue] = [:]
        for (key, value) in obj {
            if let str = value as? String { result[key] = .string(str) }
            else if let num = value as? Int { result[key] = .integer(num) }
            else if let num = value as? Double { result[key] = .number(num) }
            else if let bool = value as? Bool { result[key] = .bool(bool) }
            else if let arr = value as? [Any] { result[key] = jsonArrayToJSONValue(arr) }
            else if let dict = value as? [String: Any] { result[key] = jsonObjectToJSONValue(dict) }
            else { result[key] = .null }
        }
        return .object(result)
    }

    static func jsonArrayToJSONValue(_ arr: [Any]) -> JSONValue {
        .array(arr.map { element in
            if let str = element as? String { return .string(str) }
            else if let num = element as? Int { return .integer(num) }
            else if let num = element as? Double { return .number(num) }
            else if let bool = element as? Bool { return .bool(bool) }
            else if let dict = element as? [String: Any] { return jsonObjectToJSONValue(dict) }
            else if let arr = element as? [Any] { return jsonArrayToJSONValue(arr) }
            else { return .null }
        })
    }

    static func debugLog(_ message: @autoclosure () -> String) {
#if DEBUG
        print(message())
#endif
    }

    /// Shared stream-with-timeout wrapper used by both Anthropic and OpenAI providers.
    static func withStreamTimeout<T>(seconds: TimeInterval, operation: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                let nanoseconds = UInt64(max(1, seconds) * 1_000_000_000)
                try await Task.sleep(nanoseconds: nanoseconds)
                throw ProjectChatService.ServiceError.networkFailed(String(localized: "llm.error.request_timeout"))
            }
            guard let first = try await group.next() else {
                group.cancelAll()
                throw ProjectChatService.ServiceError.networkFailed(String(localized: "llm.error.request_failed"))
            }
            group.cancelAll()
            return first
        }
    }

    /// Consume all remaining bytes from an async stream into Data (for error responses).
    static func consumeStreamBytes(bytes: URLSession.AsyncBytes) async throws -> Data {
        var data = Data()
        for try await byte in bytes { data.append(byte) }
        return data
    }

    static func logFailedResponse(
        request: URLRequest,
        httpResponse: HTTPURLResponse,
        responseBodyData: Data,
        requestLabel: String
    ) {
        print("========== [Doufu] HTTP 请求失败 ==========")
        print("[Doufu] Request Label: \(requestLabel)")
        print("[Doufu] URL: \(request.url?.absoluteString ?? "nil")")
        print("[Doufu] Status: \(httpResponse.statusCode)")
        if let responseText = String(data: responseBodyData, encoding: .utf8) {
            print("[Doufu] Response Body: \(responseText.prefix(4000))")
        }
        print("========== [Doufu] 结束 ==========")
    }

    static func logSuccessfulResponse(
        request: URLRequest,
        httpResponse: HTTPURLResponse,
        finalResponseText: String,
        usage: ResponsesUsage?,
        requestLabel: String
    ) {
#if DEBUG
        print("========== [Doufu Debug] HTTP 请求成功 ==========")
        print("Request Label: \(requestLabel)")
        print("URL: \(request.url?.absoluteString ?? "nil")")
        print("Status: \(httpResponse.statusCode)")
        print("Final Response Text: \(finalResponseText.prefix(2000))")
        if let usage {
            print("Usage: input=\(usage.inputTokens ?? 0), output=\(usage.outputTokens ?? 0)")
        }
        print("========== [Doufu Debug] 结束 ==========")
#endif
    }
}
