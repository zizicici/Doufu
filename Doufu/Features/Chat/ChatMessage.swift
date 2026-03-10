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
    }

    let id = UUID()
    let role: Role
    var text: String
    let createdAt: Date
    let startedAt: Date
    var finishedAt: Date?
    let isProgress: Bool
    var requestTokenUsage: ProjectChatService.RequestTokenUsage?
    var toolSummary: String?

    // MARK: - Custom Hashable (identity = id only)

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: ChatMessage, rhs: ChatMessage) -> Bool { lhs.id == rhs.id }

}
