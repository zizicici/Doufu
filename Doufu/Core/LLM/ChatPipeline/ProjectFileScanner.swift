//
//  ProjectFileScanner.swift
//  Doufu
//
//  Created by Codex on 2026/03/05.
//

import Foundation

final class ProjectFileScanner {
    private let configuration: CodexChatConfiguration
    private let jsonEncoder = JSONEncoder()

    init(configuration: CodexChatConfiguration) {
        self.configuration = configuration
        jsonEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    func collectProjectFileCandidates(from projectURL: URL) throws -> [ProjectFileCandidate] {
        guard let enumerator = FileManager.default.enumerator(
            at: projectURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw CodexProjectChatService.ServiceError.noProjectFiles
        }

        var candidates: [ProjectFileCandidate] = []

        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.isDirectoryKey])
            if values?.isDirectory == true {
                continue
            }

            let relativePath = normalizedRelativePath(fileURL: fileURL, rootURL: projectURL)
            guard isSupportedTextFile(relativePath) else {
                continue
            }

            guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else {
                continue
            }
            let truncatedData = data.prefix(configuration.maxBytesPerCatalogFile)
            guard let content = String(data: truncatedData, encoding: .utf8) else {
                continue
            }

            let lineCount = max(1, content.split(whereSeparator: \.isNewline).count)
            let byteCount = min(data.count, configuration.maxBytesPerCatalogFile)
            let preview = makePreview(from: content, maxCharacters: configuration.maxPreviewCharactersForCatalog)

            candidates.append(
                ProjectFileCandidate(
                    path: relativePath,
                    content: content,
                    byteCount: byteCount,
                    lineCount: lineCount,
                    preview: preview
                )
            )
            if candidates.count >= configuration.maxFilesForCatalog {
                break
            }
        }

        let sorted = candidates.sorted { $0.path < $1.path }
        guard !sorted.isEmpty else {
            throw CodexProjectChatService.ServiceError.noProjectFiles
        }
        return sorted
    }

    func fallbackSelectionPaths(
        from fileCandidates: [ProjectFileCandidate],
        userMessage: String
    ) -> [String] {
        guard !fileCandidates.isEmpty else {
            return []
        }

        let preferredPaths = ["AGENTS.md", "manifest.json", "index.html", "style.css", "script.js"]
        var ordered: [String] = []
        var seen = Set<String>()
        let availablePaths = Set(fileCandidates.map(\.path))

        for path in preferredPaths where availablePaths.contains(path) {
            ordered.append(path)
            seen.insert(path)
        }

        let messageTokens = Set(
            userMessage
                .lowercased()
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)
                .filter { $0.count >= 2 }
        )

        let scored = fileCandidates.map { candidate -> (path: String, score: Int) in
            let loweredPath = candidate.path.lowercased()
            var score = 0
            if loweredPath == "index.html" { score += 80 }
            if loweredPath.hasSuffix(".css") { score += 35 }
            if loweredPath.hasSuffix(".js") { score += 35 }
            if loweredPath.hasSuffix(".json") { score += 20 }
            if loweredPath.hasSuffix(".md") { score += 12 }
            if loweredPath.contains("manifest") { score += 20 }
            if loweredPath.contains("agent") { score += 25 }

            for token in messageTokens where loweredPath.contains(token) {
                score += 18
            }
            return (path: candidate.path, score: score)
        }
            .sorted { lhs, rhs in
                if lhs.score == rhs.score {
                    return lhs.path < rhs.path
                }
                return lhs.score > rhs.score
            }

        for item in scored where !seen.contains(item.path) {
            ordered.append(item.path)
            seen.insert(item.path)
            if ordered.count >= configuration.maxFilePathsFromSelection {
                break
            }
        }

        if ordered.isEmpty, let first = fileCandidates.first {
            ordered.append(first.path)
        }
        return ordered
    }

    func buildContextSnapshots(
        from fileCandidates: [ProjectFileCandidate],
        selectedPaths: [String],
        maxFiles: Int? = nil
    ) -> [ProjectFileSnapshot] {
        guard !fileCandidates.isEmpty else {
            return []
        }
        let effectiveMaxFiles = max(1, maxFiles ?? configuration.maxFilesForContext)

        let fallbackPaths = fallbackSelectionPaths(from: fileCandidates, userMessage: "")
        var orderedPaths: [String] = []
        var seen = Set<String>()

        for path in selectedPaths + fallbackPaths {
            guard seen.insert(path).inserted else {
                continue
            }
            orderedPaths.append(path)
            if orderedPaths.count >= configuration.maxFilePathsFromSelection {
                break
            }
        }

        let candidateByPath = Dictionary(uniqueKeysWithValues: fileCandidates.map { ($0.path, $0) })
        var snapshots: [ProjectFileSnapshot] = []
        var consumedBytes = 0

        for path in orderedPaths.prefix(effectiveMaxFiles) {
            guard let candidate = candidateByPath[path] else {
                continue
            }

            let remainingBytes = configuration.maxContextBytesTotal - consumedBytes
            if remainingBytes <= 0 {
                break
            }

            let byteBudget = min(configuration.maxBytesPerContextFile, remainingBytes)
            let truncatedContent = truncatedToUTF8ByteCount(candidate.content, maxBytes: byteBudget)
            let normalized = truncatedContent.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else {
                continue
            }

            snapshots.append(ProjectFileSnapshot(path: path, content: truncatedContent))
            consumedBytes += truncatedContent.lengthOfBytes(using: .utf8)
        }

        if snapshots.isEmpty, let first = fileCandidates.first {
            let content = truncatedToUTF8ByteCount(
                first.content,
                maxBytes: min(configuration.maxBytesPerContextFile, configuration.maxContextBytesTotal)
            )
            if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                snapshots = [ProjectFileSnapshot(path: first.path, content: content)]
            }
        }

        return snapshots
    }

    func sanitizeSelectedPaths(
        _ selectedPaths: [String],
        fileCandidates: [ProjectFileCandidate]
    ) -> [String] {
        let validPaths = Set(fileCandidates.map(\.path))
        var results: [String] = []
        var seen = Set<String>()

        for rawPath in selectedPaths {
            let normalized = rawPath
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\\", with: "/")
            guard !normalized.isEmpty else {
                continue
            }
            guard validPaths.contains(normalized) else {
                continue
            }
            guard seen.insert(normalized).inserted else {
                continue
            }

            results.append(normalized)
            if results.count >= configuration.maxFilePathsFromSelection {
                break
            }
        }

        return results
    }

    func encodeFileCatalogToJSONString(_ fileCandidates: [ProjectFileCandidate]) throws -> String {
        let catalog = fileCandidates.map { candidate in
            ProjectFileCatalogEntry(
                path: candidate.path,
                byteCount: candidate.byteCount,
                lineCount: candidate.lineCount,
                preview: candidate.preview
            )
        }
        let data = try jsonEncoder.encode(catalog)
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    func encodeFilePathListToJSONString(_ fileCandidates: [ProjectFileCandidate]) throws -> String {
        let paths = fileCandidates.map(\.path)
        let data = try jsonEncoder.encode(paths)
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    func encodeFileSnapshotsToJSONString(_ snapshots: [ProjectFileSnapshot]) throws -> String {
        let data = try jsonEncoder.encode(snapshots)
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    private func normalizedRelativePath(fileURL: URL, rootURL: URL) -> String {
        let rootPath = rootURL.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        var relative = filePath
        if relative.hasPrefix(prefix) {
            relative.removeFirst(prefix.count)
        }
        return relative.replacingOccurrences(of: "\\", with: "/")
    }

    private func isSupportedTextFile(_ relativePath: String) -> Bool {
        let allowedExtensions: Set<String> = ["html", "css", "js", "json", "txt", "md", "svg"]
        let ext = URL(fileURLWithPath: relativePath).pathExtension.lowercased()
        return allowedExtensions.contains(ext)
    }

    private func makePreview(from content: String, maxCharacters: Int) -> String {
        let normalized = content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > maxCharacters else {
            return normalized
        }
        return String(normalized.prefix(maxCharacters)) + "..."
    }

    private func truncatedToUTF8ByteCount(_ text: String, maxBytes: Int) -> String {
        guard maxBytes > 0 else {
            return ""
        }

        let data = Data(text.utf8)
        guard data.count > maxBytes else {
            return text
        }

        var upperBound = maxBytes
        while upperBound > 0 {
            let prefix = data.prefix(upperBound)
            if let decoded = String(data: prefix, encoding: .utf8) {
                return decoded
            }
            upperBound -= 1
        }
        return ""
    }
}
