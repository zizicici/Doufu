//
//  ChatSessionManager.swift
//  Doufu
//

import Foundation

/// Manages ChatSession instances independently of any UI lifecycle.
/// Sessions are keyed by projectID and survive ViewController dismissal.
@MainActor
final class ChatSessionManager {

    static let shared = ChatSessionManager()

    private var sessions: [String: ChatSession] = [:]

    private init() {}

    /// Returns an existing session or creates a new one for the given project.
    func session(for project: AppProjectRecord) -> ChatSession {
        if let existing = sessions[project.id] {
            return existing
        }
        let session = ChatSession(project: project)
        sessions[project.id] = session
        return session
    }

    /// Removes and releases the session for a project.
    /// Call when the project workspace is fully closed.
    func endSession(projectID: String) {
        sessions.removeValue(forKey: projectID)
    }

    /// Returns the session for a project if one exists, without creating.
    func existingSession(projectID: String) -> ChatSession? {
        sessions[projectID]
    }
}
