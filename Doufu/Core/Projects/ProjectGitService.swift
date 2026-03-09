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

    /// List recent checkpoint commits across all branches,
    /// deduplicated and sorted by date (newest first).
    func listCheckpoints(projectURL: URL, limit: Int = 50) throws -> [CheckpointRecord] {
        let repo = try openRepository(at: projectURL)
        let branches = try repo.branch.list(.local)

        var seen = Set<String>()
        var records: [CheckpointRecord] = []

        for branch in branches {
            guard let branchCommit = branch.target as? Commit else { continue }
            let commits = repo.log(from: branchCommit)

            for commit in commits {
                let hex = commit.id.hex
                guard !seen.contains(hex) else { continue }
                seen.insert(hex)

                let message = commit.message.trimmingCharacters(in: .whitespacesAndNewlines)
                guard message.hasPrefix(checkpointPrefix) else { continue }

                // Skip auto-save commits from restore operations
                let body = String(message.dropFirst(checkpointPrefix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if body == "Auto-save before restore" { continue }

                records.append(CheckpointRecord(
                    id: hex,
                    message: message,
                    userMessage: body,
                    date: commit.date
                ))
            }
        }

        records.sort { $0.date > $1.date }
        return Array(records.prefix(limit))
    }

    /// Restore to a specific checkpoint by its commit ID string.
    /// Auto-commits any uncommitted changes first, then creates a new branch
    /// from the target commit and switches to it. The old branch is preserved
    /// so no history is ever lost.
    func restore(projectURL: URL, checkpointID: String) throws {
        let repo = try openRepository(at: projectURL)

        // 1. Auto-commit any dirty changes on the current branch.
        try addAll(repo: repo, projectURL: projectURL)
        if hasChangesToCommit(repo: repo) {
            try repo.commit(message: "\(checkpointPrefix) Auto-save before restore")
        }

        // 2. Find the target commit.
        let targetCommit = try findCommitAcrossBranches(repo: repo, commitID: checkpointID)

        // 3. Create a new branch from the target commit and switch to it.
        let branchName = "doufu-\(Int(Date().timeIntervalSince1970))"
        let branch = try repo.branch.create(named: branchName, target: targetCommit)
        try repo.switch(to: branch)
    }

    /// Returns the commit ID of the most recent checkpoint reachable from HEAD.
    /// This tells the user which checkpoint they are currently "on".
    func currentCheckpointID(projectURL: URL) -> String? {
        guard let repo = try? openRepository(at: projectURL) else { return nil }
        guard let commits = try? repo.log() else { return nil }
        for commit in commits {
            let message = commit.message.trimmingCharacters(in: .whitespacesAndNewlines)
            if message.hasPrefix(checkpointPrefix) {
                let body = String(message.dropFirst(checkpointPrefix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if body == "Auto-save before restore" { continue }
                return commit.id.hex
            }
        }
        return nil
    }

    // MARK: - Diff

    /// Get a list of files changed since the last checkpoint.
    func changedFilesSinceCheckpoint(projectURL: URL) throws -> [String] {
        let repo = try openRepository(at: projectURL)
        let entries = try repo.status()
        return entries.compactMap { entryPath(for: $0) }
    }

    /// Generate a unified diff of a single file: working tree vs HEAD.
    /// Returns nil if the file is unchanged or not tracked.
    func diffFileAgainstHEAD(projectURL: URL, relativePath: String) throws -> String? {
        let repo = try openRepository(at: projectURL)

        // Read the current working tree version
        let fileURL = projectURL.appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let currentContent = try? String(contentsOf: fileURL, encoding: .utf8)
        else {
            return nil
        }

        // Read the HEAD version (may not exist for new files)
        let headContent = try? fileContentAtHEAD(repo: repo, relativePath: relativePath)

        if headContent == currentContent { return nil }

        // Build a simple unified diff
        let oldLines = (headContent ?? "").components(separatedBy: "\n")
        let newLines = currentContent.components(separatedBy: "\n")
        return buildUnifiedDiff(
            oldLines: oldLines, newLines: newLines,
            oldLabel: "a/\(relativePath)", newLabel: "b/\(relativePath)",
            isNewFile: headContent == nil
        )
    }

    /// Minimal unified-diff generator (no external dependencies).
    private func buildUnifiedDiff(
        oldLines: [String], newLines: [String],
        oldLabel: String, newLabel: String,
        isNewFile: Bool
    ) -> String {
        // Myers diff is overkill here — use a simple LCS-based approach
        // that produces readable (if not perfectly minimal) output.
        let lcs = longestCommonSubsequence(oldLines, newLines)

        var result = "--- \(oldLabel)\n+++ \(newLabel)\n"
        if isNewFile { result = "--- /dev/null\n+++ \(newLabel)\n" }

        var oldIdx = 0, newIdx = 0, lcsIdx = 0
        // Accumulate hunks
        var hunkLines: [String] = []
        var hunkOldStart = 1, hunkNewStart = 1
        var hunkOldCount = 0, hunkNewCount = 0

        func flushHunk() {
            guard !hunkLines.isEmpty else { return }
            result += "@@ -\(hunkOldStart),\(hunkOldCount) +\(hunkNewStart),\(hunkNewCount) @@\n"
            result += hunkLines.joined(separator: "\n") + "\n"
            hunkLines.removeAll()
            hunkOldCount = 0
            hunkNewCount = 0
        }

        while oldIdx < oldLines.count || newIdx < newLines.count {
            if lcsIdx < lcs.count,
               oldIdx < oldLines.count, newIdx < newLines.count,
               oldLines[oldIdx] == lcs[lcsIdx], newLines[newIdx] == lcs[lcsIdx] {
                // Context line
                if hunkLines.isEmpty {
                    hunkOldStart = oldIdx + 1
                    hunkNewStart = newIdx + 1
                }
                hunkLines.append(" \(lcs[lcsIdx])")
                hunkOldCount += 1
                hunkNewCount += 1
                oldIdx += 1; newIdx += 1; lcsIdx += 1
            } else {
                if hunkLines.isEmpty {
                    hunkOldStart = oldIdx + 1
                    hunkNewStart = newIdx + 1
                }
                // Removed lines
                while oldIdx < oldLines.count &&
                      (lcsIdx >= lcs.count || oldLines[oldIdx] != lcs[lcsIdx]) {
                    hunkLines.append("-\(oldLines[oldIdx])")
                    hunkOldCount += 1
                    oldIdx += 1
                }
                // Added lines
                while newIdx < newLines.count &&
                      (lcsIdx >= lcs.count || newLines[newIdx] != lcs[lcsIdx]) {
                    hunkLines.append("+\(newLines[newIdx])")
                    hunkNewCount += 1
                    newIdx += 1
                }
            }
        }
        flushHunk()
        return result
    }

    private func longestCommonSubsequence(_ a: [String], _ b: [String]) -> [String] {
        let m = a.count, n = b.count
        guard m > 0, n > 0 else { return [] }
        // Space-optimised: only keep two rows
        var prev = [Int](repeating: 0, count: n + 1)
        var curr = [Int](repeating: 0, count: n + 1)
        // First pass: compute lengths
        var dp = [[Int]](repeating: [Int](repeating: 0, count: n + 1), count: m + 1)
        for i in 1...m {
            for j in 1...n {
                if a[i - 1] == b[j - 1] {
                    dp[i][j] = dp[i - 1][j - 1] + 1
                } else {
                    dp[i][j] = max(dp[i - 1][j], dp[i][j - 1])
                }
            }
        }
        // Backtrack
        var result: [String] = []
        var i = m, j = n
        while i > 0 && j > 0 {
            if a[i - 1] == b[j - 1] {
                result.append(a[i - 1])
                i -= 1; j -= 1
            } else if dp[i - 1][j] > dp[i][j - 1] {
                i -= 1
            } else {
                j -= 1
            }
        }
        return result.reversed()
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

    /// Search for a commit by ID across all local branches.
    private func findCommitAcrossBranches(repo: Repository, commitID: String) throws -> Commit {
        let branches = try repo.branch.list(.local)
        for branch in branches {
            guard let branchCommit = branch.target as? Commit else { continue }
            let commits = repo.log(from: branchCommit)
            for commit in commits {
                if commit.id.hex == commitID {
                    return commit
                }
            }
        }
        throw GitServiceError.checkpointNotFound
    }

    private let defaultGitignore = """
    .DS_Store
    .doufu_snapshots/
    """
}
