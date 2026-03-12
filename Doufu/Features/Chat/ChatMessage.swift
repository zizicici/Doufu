//
//  ChatMessage.swift
//  Doufu
//

import Foundation

nonisolated struct ChatMessage: Hashable, Sendable {
    nonisolated enum Role: String, Hashable, Sendable {
        case user
        case assistant
        case system
        case tool
    }

    let id = UUID()
    let role: Role
    var content: String
    let createdAt: Date
    let startedAt: Date
    var finishedAt: Date?
    let isProgress: Bool
    var requestTokenUsage: ProjectChatService.RequestTokenUsage?
    var summary: String?

    // MARK: - Custom Hashable (identity = id only)

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: ChatMessage, rhs: ChatMessage) -> Bool { lhs.id == rhs.id }

}
