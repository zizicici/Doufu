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

    static func debugLog(_ message: @autoclosure () -> String) {
#if DEBUG
        print(message())
#endif
    }

    static func logFailedResponse(
        request: URLRequest,
        httpResponse: HTTPURLResponse,
        responseBodyData: Data,
        requestLabel: String
    ) {
#if DEBUG
        print("========== [Doufu Debug] HTTP 请求失败 ==========")
        print("Request Label: \(requestLabel)")
        print("URL: \(request.url?.absoluteString ?? "nil")")
        print("Status: \(httpResponse.statusCode)")
        print("Response Headers: \(httpResponse.allHeaderFields)")
        if let responseText = String(data: responseBodyData, encoding: .utf8) {
            print("Response Body: \(responseText.prefix(2000))")
        }
        print("========== [Doufu Debug] 结束 ==========")
#endif
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
