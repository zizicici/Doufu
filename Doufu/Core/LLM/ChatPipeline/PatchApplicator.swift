//
//  PatchApplicator.swift
//  Doufu
//
//  Created by Codex on 2026/03/05.
//

import Foundation

struct PatchOperationResult {
    enum Status {
        case success
        case searchNotFound(search: String, path: String)
        case fileNotFound(path: String)
    }

    let status: Status
    let path: String
}

struct PatchApplicationResult {
    let changedPaths: [String]
    let operationResults: [PatchOperationResult]

    var hasFailures: Bool {
        operationResults.contains { if case .success = $0.status { return false } else { return true } }
    }

    var failureSummary: String {
        let failures = operationResults.filter {
            if case .success = $0.status { return false } else { return true }
        }
        guard !failures.isEmpty else { return "" }

        var lines: [String] = []
        for failure in failures {
            switch failure.status {
            case .success:
                break
            case let .searchNotFound(search, path):
                let truncatedSearch = search.count > 120 ? String(search.prefix(120)) + "..." : search
                lines.append("- File \"\(path)\": search text not found: \"\(truncatedSearch)\"")
            case let .fileNotFound(path):
                lines.append("- File \"\(path)\": file does not exist")
            }
        }
        return lines.joined(separator: "\n")
    }
}

final class PatchApplicator {
    func applyPatchPayload(_ payload: PatchPayload, to projectURL: URL) throws -> PatchApplicationResult {
        var changedPaths: [String] = []
        var allResults: [PatchOperationResult] = []

        let (changePaths, changeResults) = try applyChanges(payload.changes, to: projectURL)
        appendUniquePaths(changePaths, into: &changedPaths)
        allResults.append(contentsOf: changeResults)

        let (srPaths, srResults) = applySearchReplaceChanges(payload.searchReplaceChanges, to: projectURL)
        appendUniquePaths(srPaths, into: &changedPaths)
        allResults.append(contentsOf: srResults)

        return PatchApplicationResult(changedPaths: changedPaths, operationResults: allResults)
    }

    private func applyChanges(
        _ changes: [PatchChange],
        to projectURL: URL
    ) throws -> ([String], [PatchOperationResult]) {
        var changedPaths: [String] = []
        var results: [PatchOperationResult] = []

        for change in changes {
            let resolved = try resolveSafeDestination(path: change.path, projectURL: projectURL)
            let directoryURL = resolved.destinationURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            try change.content.write(to: resolved.destinationURL, atomically: true, encoding: .utf8)
            changedPaths.append(resolved.normalizedPath)
            results.append(PatchOperationResult(status: .success, path: resolved.normalizedPath))
        }

        return (changedPaths, results)
    }

    private func applySearchReplaceChanges(
        _ searchReplaceChanges: [SearchReplaceFileChange],
        to projectURL: URL
    ) -> ([String], [PatchOperationResult]) {
        var changedPaths: [String] = []
        var results: [PatchOperationResult] = []

        for fileChange in searchReplaceChanges {
            guard let resolved = try? resolveSafeDestination(path: fileChange.path, projectURL: projectURL) else {
                results.append(PatchOperationResult(
                    status: .fileNotFound(path: fileChange.path),
                    path: fileChange.path
                ))
                continue
            }

            guard FileManager.default.fileExists(atPath: resolved.destinationURL.path) else {
                results.append(PatchOperationResult(
                    status: .fileNotFound(path: resolved.normalizedPath),
                    path: resolved.normalizedPath
                ))
                continue
            }

            guard var currentContent = try? String(contentsOf: resolved.destinationURL, encoding: .utf8) else {
                results.append(PatchOperationResult(
                    status: .fileNotFound(path: resolved.normalizedPath),
                    path: resolved.normalizedPath
                ))
                continue
            }

            let originalContent = currentContent
            var fileHasFailure = false

            for operation in fileChange.operations {
                let search = operation.search
                guard !search.isEmpty else {
                    continue
                }

                let options: String.CompareOptions = operation.ignoreCase ? [.caseInsensitive] : []
                if operation.replaceAll {
                    guard currentContent.range(of: search, options: options) != nil else {
                        results.append(PatchOperationResult(
                            status: .searchNotFound(search: search, path: resolved.normalizedPath),
                            path: resolved.normalizedPath
                        ))
                        fileHasFailure = true
                        continue
                    }
                    currentContent = currentContent.replacingOccurrences(
                        of: search,
                        with: operation.replace,
                        options: options,
                        range: nil
                    )
                    results.append(PatchOperationResult(status: .success, path: resolved.normalizedPath))
                } else {
                    guard let range = currentContent.range(of: search, options: options) else {
                        results.append(PatchOperationResult(
                            status: .searchNotFound(search: search, path: resolved.normalizedPath),
                            path: resolved.normalizedPath
                        ))
                        fileHasFailure = true
                        continue
                    }
                    currentContent.replaceSubrange(range, with: operation.replace)
                    results.append(PatchOperationResult(status: .success, path: resolved.normalizedPath))
                }
            }

            if currentContent != originalContent {
                try? currentContent.write(to: resolved.destinationURL, atomically: true, encoding: .utf8)
                changedPaths.append(resolved.normalizedPath)
            }
        }

        return (changedPaths, results)
    }

    private func resolveSafeDestination(path: String, projectURL: URL) throws -> (normalizedPath: String, destinationURL: URL) {
        try ProjectPathResolver.resolveSafeDestination(path: path, projectURL: projectURL)
    }

    private func appendUniquePaths(_ paths: [String], into target: inout [String]) {
        ProjectPathResolver.mergeChangedPaths(paths, into: &target)
    }
}
