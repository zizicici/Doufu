//
//  PatchApplicator.swift
//  Doufu
//
//  Created by Codex on 2026/03/05.
//

import Foundation

final class PatchApplicator {
    func applyPatchPayload(_ payload: PatchPayload, to projectURL: URL) throws -> [String] {
        var changedPaths: [String] = []
        appendUniquePaths(try applyChanges(payload.changes, to: projectURL), into: &changedPaths)
        appendUniquePaths(try applySearchReplaceChanges(payload.searchReplaceChanges, to: projectURL), into: &changedPaths)
        return changedPaths
    }

    private func applyChanges(_ changes: [PatchChange], to projectURL: URL) throws -> [String] {
        var changedPaths: [String] = []

        for change in changes {
            let resolved = try resolveSafeDestination(path: change.path, projectURL: projectURL)
            let directoryURL = resolved.destinationURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            try change.content.write(to: resolved.destinationURL, atomically: true, encoding: .utf8)
            changedPaths.append(resolved.normalizedPath)
        }

        return changedPaths
    }

    private func applySearchReplaceChanges(
        _ searchReplaceChanges: [SearchReplaceFileChange],
        to projectURL: URL
    ) throws -> [String] {
        var changedPaths: [String] = []

        for fileChange in searchReplaceChanges {
            let resolved = try resolveSafeDestination(path: fileChange.path, projectURL: projectURL)
            guard FileManager.default.fileExists(atPath: resolved.destinationURL.path) else {
                throw ProjectChatService.ServiceError.invalidPatchJSON
            }

            var currentContent: String
            do {
                currentContent = try String(contentsOf: resolved.destinationURL, encoding: .utf8)
            } catch {
                throw ProjectChatService.ServiceError.invalidPatchJSON
            }

            let originalContent = currentContent
            for operation in fileChange.operations {
                let search = operation.search
                guard !search.isEmpty else {
                    throw ProjectChatService.ServiceError.invalidPatchJSON
                }

                let options: String.CompareOptions = operation.ignoreCase ? [.caseInsensitive] : []
                if operation.replaceAll {
                    guard currentContent.range(of: search, options: options) != nil else {
                        throw ProjectChatService.ServiceError.invalidPatchJSON
                    }
                    currentContent = currentContent.replacingOccurrences(
                        of: search,
                        with: operation.replace,
                        options: options,
                        range: nil
                    )
                } else {
                    guard let range = currentContent.range(of: search, options: options) else {
                        throw ProjectChatService.ServiceError.invalidPatchJSON
                    }
                    currentContent.replaceSubrange(range, with: operation.replace)
                }
            }

            if currentContent != originalContent {
                try currentContent.write(to: resolved.destinationURL, atomically: true, encoding: .utf8)
                changedPaths.append(resolved.normalizedPath)
            }
        }

        return changedPaths
    }

    private func resolveSafeDestination(path: String, projectURL: URL) throws -> (normalizedPath: String, destinationURL: URL) {
        let rawPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPath = rawPath.replacingOccurrences(of: "\\", with: "/")
        guard isSafeRelativePath(normalizedPath) else {
            debugUnsafePath(rawPath: rawPath, normalizedPath: normalizedPath, reason: "isSafeRelativePath=false")
            throw ProjectChatService.ServiceError.invalidPath(path)
        }

        let rootURL = projectURL.standardizedFileURL.resolvingSymlinksInPath()
        let destinationURL = rootURL.appendingPathComponent(normalizedPath).standardizedFileURL.resolvingSymlinksInPath()
        guard isSubpath(destinationURL, of: rootURL) else {
            debugUnsafePath(
                rawPath: rawPath,
                normalizedPath: normalizedPath,
                reason: "resolved destination escaped root",
                destinationPath: destinationURL.path,
                rootPath: rootURL.path
            )
            throw ProjectChatService.ServiceError.invalidPath(path)
        }
        return (normalizedPath, destinationURL)
    }

    private func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty else {
            return false
        }
        if path.hasPrefix("/") || path.hasPrefix("~") {
            return false
        }

        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty else {
            return false
        }
        for component in components {
            if component.isEmpty || component == "." || component == ".." {
                return false
            }
        }

        return true
    }

    private func isSubpath(_ candidate: URL, of root: URL) -> Bool {
        let rootComponents = root.standardizedFileURL.pathComponents
        let candidateComponents = candidate.standardizedFileURL.pathComponents
        guard candidateComponents.count >= rootComponents.count else {
            return false
        }
        for (index, component) in rootComponents.enumerated() {
            if candidateComponents[index] != component {
                return false
            }
        }
        return true
    }

    private func debugUnsafePath(
        rawPath: String,
        normalizedPath: String,
        reason: String,
        destinationPath: String? = nil,
        rootPath: String? = nil
    ) {
#if DEBUG
        let scalarDump = normalizedPath.unicodeScalars
            .map { String(format: "U+%04X", $0.value) }
            .joined(separator: " ")
        var message = "[DoufuCodexChat Debug] unsafe path rejected reason=\(reason) raw=\(String(reflecting: rawPath)) normalized=\(String(reflecting: normalizedPath)) scalars=[\(scalarDump)]"
        if let destinationPath {
            message += " destination=\(destinationPath)"
        }
        if let rootPath {
            message += " root=\(rootPath)"
        }
        print(message)
#endif
    }

    private func appendUniquePaths(_ paths: [String], into target: inout [String]) {
        var seen = Set(target)
        for path in paths {
            let normalized = path
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\\", with: "/")
            guard isSafeRelativePath(normalized) else {
                continue
            }
            guard seen.insert(normalized).inserted else {
                continue
            }
            target.append(normalized)
        }
    }
}
