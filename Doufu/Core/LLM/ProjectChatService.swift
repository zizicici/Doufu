//
//  ProjectChatService.swift
//  Doufu
//
//  Created by Codex on 2026/03/05.
//

import Foundation

final class ProjectChatService {

    struct ProviderCredential {
        let providerID: String
        let providerLabel: String
        let providerKind: LLMProviderRecord.Kind
        let authMode: LLMProviderRecord.AuthMode
        let modelID: String
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

    enum ReasoningEffort: String, CaseIterable {
        case low
        case medium
        case high
        case xhigh

        var displayName: String {
            switch self {
            case .low:
                return String(localized: "chat.reasoning.low")
            case .medium:
                return String(localized: "chat.reasoning.medium")
            case .high:
                return String(localized: "chat.reasoning.high")
            case .xhigh:
                return String(localized: "chat.reasoning.xhigh")
            }
        }
    }

    struct ModelExecutionOptions {
        let reasoningEffort: ReasoningEffort
        let anthropicThinkingEnabled: Bool
        let geminiThinkingEnabled: Bool

        static let `default` = ModelExecutionOptions(
            reasoningEffort: .high,
            anthropicThinkingEnabled: true,
            geminiThinkingEnabled: true
        )
    }

    struct ThreadContext {
        let threadID: String
        let version: Int
        let memoryFilePath: String
        let memoryContent: String
    }

    struct ThreadMemoryUpdate {
        let contentMarkdown: String
        let shouldRollOver: Bool
        let nextVersionSummary: String?
        let nextVersionContentMarkdown: String?
    }

    struct RequestTokenUsage: Codable, Equatable, Hashable {
        let inputTokens: Int64
        let outputTokens: Int64

        var totalTokens: Int64 {
            inputTokens + outputTokens
        }
    }

    struct ResultPayload {
        let assistantMessage: String
        let changedPaths: [String]
        let updatedMemory: SessionMemory
        let threadMemoryUpdate: ThreadMemoryUpdate?
        let requestTokenUsage: RequestTokenUsage?
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
                return String(localized: "chat_service.error.no_project_files")
            case .invalidResponse:
                return String(localized: "chat_service.error.invalid_response")
            case .invalidPatchJSON:
                return String(localized: "chat_service.error.invalid_patch_json")
            case let .invalidPath(path):
                return String(format: String(localized: "chat_service.error.invalid_path_format"), path)
            case let .networkFailed(message):
                return message
            }
        }
    }

    private let orchestrator: ProjectChatOrchestrator

    init(configuration: ProjectChatConfiguration = .default) {
        orchestrator = ProjectChatOrchestrator(configuration: configuration)
    }

    func sendAndApply(
        userMessage: String,
        history: [ChatTurn],
        projectURL: URL,
        credential: ProviderCredential,
        memory: SessionMemory? = nil,
        threadContext: ThreadContext?,
        executionOptions: ModelExecutionOptions,
        onStreamedText: (@MainActor (String) -> Void)? = nil,
        onProgress: (@MainActor (String) -> Void)? = nil
    ) async throws -> ResultPayload {
        try await orchestrator.sendAndApply(
            userMessage: userMessage,
            history: history,
            projectURL: projectURL,
            credential: credential,
            memory: memory,
            threadContext: threadContext,
            executionOptions: executionOptions,
            onStreamedText: onStreamedText,
            onProgress: onProgress
        )
    }
}
