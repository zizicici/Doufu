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

    private let orchestrator: CodexChatOrchestrator

    init(configuration: CodexChatConfiguration = .default) {
        orchestrator = CodexChatOrchestrator(configuration: configuration)
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
        try await orchestrator.sendAndApply(
            userMessage: userMessage,
            history: history,
            projectURL: projectURL,
            credential: credential,
            memory: memory,
            onStreamedText: onStreamedText,
            onProgress: onProgress
        )
    }
}
