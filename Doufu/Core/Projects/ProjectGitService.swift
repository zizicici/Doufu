//
//  ProjectGitService.swift
//  Doufu
//
//  Created by Claude on 2026/03/08.
//

import Foundation
import SwiftGitX

final class ProjectGitService {
    static let shared = ProjectGitService()

    private let checkpointPrefix = "[doufu-checkpoint]"

    // MARK: - Repository Lifecycle

    /// Initialize a git repository in a project directory. Called when a project is created.
    /// If the repo already exists, this is a no-op.
    func initializeRepository(at projectURL: URL) throws {
        let gitDir = projectURL.appendingPathComponent(".git")
        guard !FileManager.default.fileExists(atPath: gitDir.path) else { return }

        let repo = try Repository(at: projectURL)
        try configureDefaults(repo: repo)
        try addAll(repo: repo, projectURL: projectURL)
        try repo.commit(message: "Project created")
    }

    /// Ensure a project has a git repo. If not, initialize and create initial commit.
    /// Safe to call repeatedly.
    func ensureRepository(at projectURL: URL) throws {
        try initializeRepository(at: projectURL)
    }

    // MARK: - Checkpoint (Claude Code alignment)

    /// Create a checkpoint commit before an agent loop begins.
    /// Stages all current changes and commits with a checkpoint prefix.
    /// Returns the checkpoint commit message, or nil if there was nothing to commit.
    @discardableResult
    func createCheckpoint(projectURL: URL, userMessage: String) throws -> String? {
        let repo = try openRepository(at: projectURL)

        try addAll(repo: repo, projectURL: projectURL)

        // Only commit if there are staged changes
        guard hasChangesToCommit(repo: repo) else { return nil }

        let truncatedMessage = String(userMessage.prefix(120))
        let commitMessage = "\(checkpointPrefix) \(truncatedMessage)"
        try repo.commit(message: commitMessage)
        return commitMessage
    }

    // MARK: - Undo

    /// Undo: reset to the most recent checkpoint commit.
    /// Returns true if undo was performed, false if no checkpoint found.
    func undo(projectURL: URL) throws -> Bool {
        let repo = try openRepository(at: projectURL)

        guard let checkpointCommit = try findLatestCheckpointCommit(repo: repo) else {
            return false
        }

        try repo.reset(to: checkpointCommit, mode: .hard)
        return true
    }

    /// Check whether there is a checkpoint available to undo to.
    func hasCheckpoint(projectURL: URL) -> Bool {
        guard let repo = try? openRepository(at: projectURL) else { return false }
        return (try? findLatestCheckpointCommit(repo: repo)) != nil
    }

    // MARK: - History

    struct CheckpointRecord {
        let id: String
        let message: String
        let userMessage: String
        let date: Date
    }

    /// List recent checkpoint commits.
    func listCheckpoints(projectURL: URL, limit: Int = 20) throws -> [CheckpointRecord] {
        let repo = try openRepository(at: projectURL)
        let commits = try repo.log()

        var records: [CheckpointRecord] = []
        for commit in commits {
            guard records.count < limit else { break }

            let message = commit.message.trimmingCharacters(in: .whitespacesAndNewlines)
            guard message.hasPrefix(checkpointPrefix) else { continue }

            let userMessage = String(message.dropFirst(checkpointPrefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)

            records.append(CheckpointRecord(
                id: commit.id.hex,
                message: message,
                userMessage: userMessage,
                date: commit.date
            ))
        }
        return records
    }

    /// Restore to a specific checkpoint by its commit ID string.
    func restore(projectURL: URL, checkpointID: String) throws {
        let repo = try openRepository(at: projectURL)
        let commits = try repo.log()

        for commit in commits {
            if commit.id.hex == checkpointID {
                try repo.reset(to: commit, mode: .hard)
                return
            }
        }

        throw GitServiceError.checkpointNotFound
    }

    // MARK: - Diff

    /// Get a list of files changed since the last checkpoint.
    func changedFilesSinceCheckpoint(projectURL: URL) throws -> [String] {
        let repo = try openRepository(at: projectURL)
        let entries = try repo.status()
        return entries.compactMap { entryPath(for: $0) }
    }

    // MARK: - Errors

    enum GitServiceError: LocalizedError {
        case repositoryNotFound
        case checkpointNotFound
        case commitFailed

        var errorDescription: String? {
            switch self {
            case .repositoryNotFound:
                return "Git repository not found"
            case .checkpointNotFound:
                return "Checkpoint not found"
            case .commitFailed:
                return "Failed to create commit"
            }
        }
    }

    // MARK: - File-Level Revert

    /// Open a repository for revert operations (exposed for AgentTools).
    func openRepositoryForRevert(at projectURL: URL) throws -> Repository {
        try openRepository(at: projectURL)
    }

    /// Read a file's content from the HEAD commit.
    /// Returns nil if the file doesn't exist in HEAD.
    func fileContentAtHEAD(repo: Repository, relativePath: String) throws -> String? {
        let head = try repo.HEAD
        guard let commit = head.target as? Commit else {
            return nil
        }
        let tree = commit.tree

        // Navigate the tree to find the file
        let components = relativePath.components(separatedBy: "/").filter { !$0.isEmpty }
        var currentTree = tree

        for (index, component) in components.enumerated() {
            let isLast = index == components.count - 1

            guard let entry = currentTree.entries.first(where: { $0.name == component }) else {
                return nil
            }

            if isLast {
                // This should be a blob (file)
                guard let blob: Blob = try? repo.show(id: entry.id) else {
                    return nil
                }
                return String(data: blob.content, encoding: .utf8)
            } else {
                // Navigate into subdirectory
                guard let subTree: Tree = try? repo.show(id: entry.id) else {
                    return nil
                }
                currentTree = subTree
            }
        }

        return nil
    }

    // MARK: - Private

    private func openRepository(at projectURL: URL) throws -> Repository {
        do {
            return try Repository.open(at: projectURL)
        } catch {
            throw GitServiceError.repositoryNotFound
        }
    }

    private func configureDefaults(repo: Repository) throws {
        try repo.config.set("user.name", to: "Doufu")
        try repo.config.set("user.email", to: "doufu@local")
    }

    private func addAll(repo: Repository, projectURL: URL) throws {
        // Ensure .gitignore exists
        let gitignoreURL = projectURL.appendingPathComponent(".gitignore")
        if !FileManager.default.fileExists(atPath: gitignoreURL.path) {
            try defaultGitignore.write(to: gitignoreURL, atomically: true, encoding: .utf8)
        }

        // Stage all files
        let entries = try repo.status()
        var pathsToAdd: [String] = []
        for entry in entries {
            guard let path = entryPath(for: entry) else { continue }
            // Skip .git directory itself (should never appear, but be safe)
            if path == ".git" || path.hasPrefix(".git/") { continue }
            pathsToAdd.append(path)
        }
        if !pathsToAdd.isEmpty {
            try repo.add(paths: pathsToAdd)
        }
    }

    private func hasChangesToCommit(repo: Repository) -> Bool {
        guard let entries = try? repo.status() else { return false }
        return entries.contains { entry in
            let statuses = entry.status
            return statuses.contains(.indexNew) ||
                   statuses.contains(.indexModified) ||
                   statuses.contains(.indexDeleted) ||
                   statuses.contains(.indexRenamed) ||
                   statuses.contains(.indexTypeChange)
        }
    }

    private func entryPath(for entry: StatusEntry) -> String? {
        entry.index?.newFile.path ?? entry.index?.oldFile.path
            ?? entry.workingTree?.newFile.path ?? entry.workingTree?.oldFile.path
    }

    private func findLatestCheckpointCommit(repo: Repository) throws -> Commit? {
        let commits = try repo.log()
        for commit in commits {
            let message = commit.message.trimmingCharacters(in: .whitespacesAndNewlines)
            if message.hasPrefix(checkpointPrefix) {
                return commit
            }
        }
        return nil
    }

    private let defaultGitignore = """
    .DS_Store
    .doufu_snapshots/
    """
}
