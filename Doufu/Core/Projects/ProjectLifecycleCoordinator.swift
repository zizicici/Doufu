//
//  ProjectLifecycleCoordinator.swift
//  Doufu
//

import Foundation

/// Unified entry point for all project lifecycle operations (create, delete,
/// close, rename). Ensures ChatSession state stays consistent with project
/// mutations.
@MainActor
final class ProjectLifecycleCoordinator {

    static let shared = ProjectLifecycleCoordinator()

    private let projectStore = AppProjectStore.shared
    private let sessionManager = ChatSessionManager.shared

    private init() {}

    // MARK: - Execution State

    func isExecuting(projectID: String) -> Bool {
        sessionManager.existingSession(projectID: projectID)?.isExecuting ?? false
    }

    func existingSession(projectID: String) -> ChatSession? {
        sessionManager.existingSession(projectID: projectID)
    }

    func session(for project: AppProjectRecord) -> ChatSession {
        sessionManager.session(for: project)
    }

    // MARK: - Create

    @discardableResult
    func createProject(name: String? = nil) async throws -> AppProjectRecord {
        try await projectStore.createBlankProject(name: name)
    }

    // MARK: - Delete

    /// Cancels any in-flight execution, waits for it to finish, flushes
    /// persistence, deletes the project, then cleans up the session.
    /// The session is only removed **after** a successful delete so that a
    /// failure leaves it intact.
    func deleteProject(projectID: String, projectURL: URL) async throws {
        if let session = sessionManager.existingSession(projectID: projectID) {
            if session.isExecuting {
                // Prevent coordinatorDidFinishExecution from self-cleaning the
                // session — the coordinator must retain it until we know
                // whether the disk delete succeeds.
                session.suppressAutoEndSession = true
                await session.cancelAndAwaitCompletion()
            }
            session.flushPendingPersistence()
        }

        do {
            try projectStore.deleteProject(projectURL: projectURL)
        } catch {
            // Delete failed — restore the session to normal self-clean
            // behaviour so it doesn't leak if the workspace is later closed.
            sessionManager.existingSession(projectID: projectID)?.suppressAutoEndSession = false
            throw error
        }

        // Success: clean up the session.
        sessionManager.endSession(projectID: projectID)
        ProjectActivityStore.shared.clear(projectID: projectID)
    }

    // MARK: - Close

    /// Called when the workspace is dismissed. Ends the session unless an LLM
    /// task is still running (in which case the session self-cleans via
    /// ``ChatSession/coordinatorDidFinishExecution()``).
    func closeProject(projectID: String) {
        guard let session = sessionManager.existingSession(projectID: projectID) else { return }
        if !session.isExecuting {
            sessionManager.endSession(projectID: projectID)
        }
    }

    // MARK: - Rename

    /// Persists the new name to the database and synchronises the in-memory
    /// ``ChatSession`` (if one exists) so that subsequent LLM requests use the
    /// updated project name in their context.
    func renameProject(projectURL: URL, newName: String) throws {
        try projectStore.updateProjectName(projectURL: projectURL, name: newName)

        let projectID = projectURL.lastPathComponent
        if let session = sessionManager.existingSession(projectID: projectID) {
            let updatedProject = AppProjectRecord(
                id: session.project.id,
                name: newName,
                projectURL: session.project.projectURL,
                createdAt: session.project.createdAt,
                updatedAt: Date()
            )
            session.updateProject(updatedProject)
        }

        ProjectChangeCenter.shared.notifyProjectRenamed(projectID: projectID)
    }
}
