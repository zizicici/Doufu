//
//  ProjectPathResolver.swift
//  Doufu
//
//  Created by Codex on 2026/03/08.
//

import Foundation

enum ProjectPathResolver {

    // MARK: - Path Validation

    static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty else { return false }
        if path.hasPrefix("/") || path.hasPrefix("~") { return false }

        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty else { return false }
        for component in components {
            if component.isEmpty || component == "." || component == ".." { return false }
        }
        return true
    }

    static func isSubpath(_ candidate: URL, of root: URL) -> Bool {
        let rootComponents = root.standardizedFileURL.pathComponents
        let candidateComponents = candidate.standardizedFileURL.pathComponents
        guard candidateComponents.count >= rootComponents.count else { return false }
        for (index, component) in rootComponents.enumerated() {
            if candidateComponents[index] != component { return false }
        }
        return true
    }

    // MARK: - Path Normalization

    static func normalizeRelativePath(_ path: String) -> String {
        path.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")
    }

    static func normalizedRelativePath(fileURL: URL, rootURL: URL) -> String {
        let rootPath = rootURL.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        var relative = filePath
        if relative.hasPrefix(prefix) {
            relative.removeFirst(prefix.count)
        }
        return relative.replacingOccurrences(of: "\\", with: "/")
    }

    // MARK: - Safe Resolution

    static func resolveSafePath(_ path: String, in projectURL: URL) -> URL? {
        let normalized = normalizeRelativePath(path)
        guard isSafeRelativePath(normalized) else { return nil }

        let rootURL = projectURL.standardizedFileURL.resolvingSymlinksInPath()
        let destinationURL = rootURL.appendingPathComponent(normalized).standardizedFileURL.resolvingSymlinksInPath()

        guard isSubpath(destinationURL, of: rootURL) else { return nil }
        return destinationURL
    }

    static func resolveSafeDestination(
        path: String,
        projectURL: URL
    ) throws -> (normalizedPath: String, destinationURL: URL) {
        let rawPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPath = rawPath.replacingOccurrences(of: "\\", with: "/")
        guard isSafeRelativePath(normalizedPath) else {
            throw ProjectChatService.ServiceError.invalidPath(path)
        }

        let rootURL = projectURL.standardizedFileURL.resolvingSymlinksInPath()
        let destinationURL = rootURL.appendingPathComponent(normalizedPath).standardizedFileURL.resolvingSymlinksInPath()
        guard isSubpath(destinationURL, of: rootURL) else {
            throw ProjectChatService.ServiceError.invalidPath(path)
        }
        return (normalizedPath, destinationURL)
    }

    // MARK: - File Type Detection

    static func isTextFile(_ relativePath: String) -> Bool {
        let ext = URL(fileURLWithPath: relativePath).pathExtension.lowercased()

        // Known binary extensions — skip these
        let binaryExtensions: Set<String> = [
            // Images
            "png", "jpg", "jpeg", "gif", "bmp", "ico", "webp", "tiff", "tif", "avif", "heic", "heif",
            // Audio/Video
            "mp3", "mp4", "wav", "ogg", "webm", "avi", "mov", "flac", "aac", "m4a", "m4v",
            // Fonts
            "woff", "woff2", "ttf", "otf", "eot",
            // Archives
            "zip", "gz", "tar", "rar", "7z", "bz2", "xz",
            // Compiled / binary
            "o", "a", "dylib", "so", "dll", "exe", "class", "pyc", "pyo",
            "wasm", "map",
            // Data
            "sqlite", "db", "pdf", "psd", "ai", "sketch",
        ]
        if binaryExtensions.contains(ext) { return false }

        // Files starting with . (hidden) with no extension
        let fileName = URL(fileURLWithPath: relativePath).lastPathComponent
        if fileName.hasPrefix(".") && ext.isEmpty { return false }

        // No extension — check known filenames
        if ext.isEmpty {
            let knownNames: Set<String> = [
                "Makefile", "Dockerfile", "Procfile", "Gemfile", "Rakefile",
                "LICENSE", "CHANGELOG", "AUTHORS", "CODEOWNERS",
            ]
            return knownNames.contains(fileName)
        }

        // Everything else is treated as text
        return true
    }

    // MARK: - Merge Helpers

    static func mergeChangedPaths(_ paths: [String], into target: inout [String]) {
        var seen = Set(target)
        for path in paths {
            let normalized = normalizeRelativePath(path)
            guard !normalized.isEmpty, isSafeRelativePath(normalized),
                  seen.insert(normalized).inserted
            else { continue }
            target.append(normalized)
        }
    }
}
