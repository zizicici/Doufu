//
//  AgentTools.swift
//  Doufu
//
//  Created by Codex on 2026/03/08.
//

import Foundation

protocol ToolConfirmationHandler: AnyObject {
    @MainActor func confirmDestructiveAction(description: String) async -> Bool
}

final class AgentToolProvider {
    private let projectURL: URL
    private let configuration: ProjectChatConfiguration
    weak var confirmationHandler: ToolConfirmationHandler?

    init(projectURL: URL, configuration: ProjectChatConfiguration = .default) {
        self.projectURL = projectURL
        self.configuration = configuration
    }

    // MARK: - Tool Definitions

    private lazy var webToolProvider = WebToolProvider(configuration: configuration)

    func toolDefinitions() -> [AgentToolDefinition] {
        [
            readFileTool(),
            writeFileTool(),
            editFileTool(),
            deleteFileTool(),
            moveFileTool(),
            listDirectoryTool(),
            searchFilesTool(),
            grepFilesTool(),
            globFilesTool(),
            webSearchTool(),
            webFetchTool(),
        ]
    }

    private func readFileTool() -> AgentToolDefinition {
        AgentToolDefinition(
            name: "read_file",
            description: "Read the contents of a file in the project. Use this to understand existing code before making changes.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object([
                        "type": .string("string"),
                        "description": .string("File path relative to project root, e.g. index.html or src/main.js")
                    ])
                ]),
                "required": .array([.string("path")]),
                "additionalProperties": .bool(false)
            ])
        )
    }

    private func writeFileTool() -> AgentToolDefinition {
        AgentToolDefinition(
            name: "write_file",
            description: "Create a new file or completely overwrite an existing file. Use this for new files or when the entire content needs to change. For small modifications to existing files, prefer edit_file instead.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object([
                        "type": .string("string"),
                        "description": .string("File path relative to project root")
                    ]),
                    "content": .object([
                        "type": .string("string"),
                        "description": .string("The complete file content to write")
                    ])
                ]),
                "required": .array([.string("path"), .string("content")]),
                "additionalProperties": .bool(false)
            ])
        )
    }

    private func editFileTool() -> AgentToolDefinition {
        AgentToolDefinition(
            name: "edit_file",
            description: "Make targeted edits to an existing file using search and replace. Each edit replaces an exact string match. Always read the file first to see the current content before editing.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object([
                        "type": .string("string"),
                        "description": .string("File path relative to project root")
                    ]),
                    "edits": .object([
                        "type": .string("array"),
                        "description": .string("List of search/replace operations to apply sequentially"),
                        "items": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "old_text": .object([
                                    "type": .string("string"),
                                    "description": .string("The exact text to find in the file. Must match exactly including whitespace and indentation.")
                                ]),
                                "new_text": .object([
                                    "type": .string("string"),
                                    "description": .string("The replacement text")
                                ])
                            ]),
                            "required": .array([.string("old_text"), .string("new_text")]),
                            "additionalProperties": .bool(false)
                        ])
                    ])
                ]),
                "required": .array([.string("path"), .string("edits")]),
                "additionalProperties": .bool(false)
            ])
        )
    }

    private func deleteFileTool() -> AgentToolDefinition {
        AgentToolDefinition(
            name: "delete_file",
            description: "Delete a file from the project. Use this when refactoring or cleaning up unused files.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object([
                        "type": .string("string"),
                        "description": .string("File path relative to project root to delete")
                    ])
                ]),
                "required": .array([.string("path")]),
                "additionalProperties": .bool(false)
            ])
        )
    }

    private func moveFileTool() -> AgentToolDefinition {
        AgentToolDefinition(
            name: "move_file",
            description: "Move or rename a file within the project. The source file is moved to the destination path.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "source": .object([
                        "type": .string("string"),
                        "description": .string("Current file path relative to project root")
                    ]),
                    "destination": .object([
                        "type": .string("string"),
                        "description": .string("New file path relative to project root")
                    ])
                ]),
                "required": .array([.string("source"), .string("destination")]),
                "additionalProperties": .bool(false)
            ])
        )
    }

    private func listDirectoryTool() -> AgentToolDefinition {
        AgentToolDefinition(
            name: "list_directory",
            description: "List files and directories at the given path. Returns file names, sizes, and types. Use this to explore the project structure.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object([
                        "type": .string("string"),
                        "description": .string("Directory path relative to project root. Use empty string or '.' for the project root.")
                    ])
                ]),
                "required": .array([.string("path")]),
                "additionalProperties": .bool(false)
            ])
        )
    }

    private func searchFilesTool() -> AgentToolDefinition {
        AgentToolDefinition(
            name: "search_files",
            description: "Search for a text pattern across project files. Returns matching file paths and the lines containing the match. Useful for finding where something is defined or used.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "query": .object([
                        "type": .string("string"),
                        "description": .string("The text pattern to search for (case-insensitive substring match)")
                    ]),
                    "path": .object([
                        "type": .string("string"),
                        "description": .string("Optional directory to limit the search to, relative to project root")
                    ])
                ]),
                "required": .array([.string("query")]),
                "additionalProperties": .bool(false)
            ])
        )
    }

    private func grepFilesTool() -> AgentToolDefinition {
        AgentToolDefinition(
            name: "grep_files",
            description: "Search for a regular expression pattern across project files. More powerful than search_files — supports full regex syntax (e.g. \"function\\s+\\w+\", \"class\\s+Foo\"). Returns matching file paths with line numbers and content.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "pattern": .object([
                        "type": .string("string"),
                        "description": .string("Regular expression pattern to search for. Uses ICU regex syntax.")
                    ]),
                    "path": .object([
                        "type": .string("string"),
                        "description": .string("Optional directory to limit the search to, relative to project root")
                    ]),
                    "case_sensitive": .object([
                        "type": .string("boolean"),
                        "description": .string("Whether the search is case-sensitive. Defaults to false.")
                    ])
                ]),
                "required": .array([.string("pattern")]),
                "additionalProperties": .bool(false)
            ])
        )
    }

    private func globFilesTool() -> AgentToolDefinition {
        AgentToolDefinition(
            name: "glob_files",
            description: "Find files matching a glob pattern. Returns a list of file paths. Use this to find files by name or extension (e.g. \"**/*.css\", \"src/**/*.js\", \"*.html\").",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "pattern": .object([
                        "type": .string("string"),
                        "description": .string("Glob pattern to match against file paths relative to project root. Supports * (any segment), ** (recursive), ? (single char). Examples: \"**/*.css\", \"src/*.js\", \"index.html\"")
                    ]),
                    "path": .object([
                        "type": .string("string"),
                        "description": .string("Optional directory to search in, relative to project root. Defaults to project root.")
                    ])
                ]),
                "required": .array([.string("pattern")]),
                "additionalProperties": .bool(false)
            ])
        )
    }

    private func webSearchTool() -> AgentToolDefinition {
        AgentToolDefinition(
            name: "web_search",
            description: "Search the web for information. Returns a list of results with titles, URLs, and descriptions. Use this to find documentation, API references, code examples, or any information not available in the project files.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "query": .object([
                        "type": .string("string"),
                        "description": .string("The search query string")
                    ])
                ]),
                "required": .array([.string("query")]),
                "additionalProperties": .bool(false)
            ])
        )
    }

    private func webFetchTool() -> AgentToolDefinition {
        AgentToolDefinition(
            name: "web_fetch",
            description: "Fetch the content of a web page. Returns the page text with HTML stripped. Use this to read documentation, API references, or any web page. Only supports http/https URLs.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "url": .object([
                        "type": .string("string"),
                        "description": .string("The full URL to fetch (must start with http:// or https://)")
                    ])
                ]),
                "required": .array([.string("url")]),
                "additionalProperties": .bool(false)
            ])
        )
    }

    // MARK: - Tool Execution

    struct ToolExecutionResult {
        let output: String
        let isError: Bool
        let changedPaths: [String]
    }

    func execute(toolCall: AgentToolCall) async -> ToolExecutionResult {
        let args = toolCall.decodedArguments() ?? [:]

        switch toolCall.name {
        case "read_file":
            return executeReadFile(args: args)
        case "write_file":
            return await executeWriteFile(args: args)
        case "edit_file":
            return executeEditFile(args: args)
        case "delete_file":
            return await executeDeleteFile(args: args)
        case "move_file":
            return executeMoveFile(args: args)
        case "list_directory":
            return executeListDirectory(args: args)
        case "search_files":
            return executeSearchFiles(args: args)
        case "grep_files":
            return executeGrepFiles(args: args)
        case "glob_files":
            return executeGlobFiles(args: args)
        case "web_search":
            return await executeWebSearch(args: args)
        case "web_fetch":
            return await executeWebFetch(args: args)
        default:
            return ToolExecutionResult(
                output: "Unknown tool: \(toolCall.name)",
                isError: true,
                changedPaths: []
            )
        }
    }

    // MARK: - Read File

    private func executeReadFile(args: [String: Any]) -> ToolExecutionResult {
        guard let path = args["path"] as? String else {
            return ToolExecutionResult(output: "Missing required parameter: path", isError: true, changedPaths: [])
        }

        guard let resolved = resolveSafePath(path) else {
            return ToolExecutionResult(output: "Invalid path: \(path)", isError: true, changedPaths: [])
        }

        guard FileManager.default.fileExists(atPath: resolved.path) else {
            return ToolExecutionResult(output: "File not found: \(path)", isError: true, changedPaths: [])
        }

        guard let data = try? Data(contentsOf: resolved), !data.isEmpty else {
            return ToolExecutionResult(output: "Could not read file: \(path)", isError: true, changedPaths: [])
        }

        let truncatedData = data.prefix(configuration.maxBytesPerContextFile)
        guard let content = String(data: truncatedData, encoding: .utf8) else {
            return ToolExecutionResult(output: "File is not valid UTF-8 text: \(path)", isError: true, changedPaths: [])
        }

        let truncationNote = data.count > configuration.maxBytesPerContextFile
            ? "\n\n[Note: File truncated at \(configuration.maxBytesPerContextFile) bytes. Total size: \(data.count) bytes]"
            : ""

        return ToolExecutionResult(output: content + truncationNote, isError: false, changedPaths: [])
    }

    // MARK: - Write File

    private func executeWriteFile(args: [String: Any]) async -> ToolExecutionResult {
        guard let path = args["path"] as? String else {
            return ToolExecutionResult(output: "Missing required parameter: path", isError: true, changedPaths: [])
        }
        guard let content = args["content"] as? String else {
            return ToolExecutionResult(output: "Missing required parameter: content", isError: true, changedPaths: [])
        }

        guard let resolved = resolveSafePath(path) else {
            return ToolExecutionResult(output: "Invalid path: \(path)", isError: true, changedPaths: [])
        }

        let normalizedPath = normalizeRelativePath(path)
        let fileExists = FileManager.default.fileExists(atPath: resolved.path)

        // Confirm overwrite of existing files
        if fileExists, let handler = confirmationHandler {
            let approved = await handler.confirmDestructiveAction(
                description: String(
                    format: String(localized: "tool.confirm.overwrite_file"),
                    normalizedPath
                )
            )
            if !approved {
                return ToolExecutionResult(
                    output: "User denied overwriting \(normalizedPath)",
                    isError: true,
                    changedPaths: []
                )
            }
        }

        do {
            let directoryURL = resolved.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            try content.write(to: resolved, atomically: true, encoding: .utf8)
            return ToolExecutionResult(
                output: "Successfully wrote \(content.count) characters to \(normalizedPath)",
                isError: false,
                changedPaths: [normalizedPath]
            )
        } catch {
            return ToolExecutionResult(
                output: "Failed to write file \(normalizedPath): \(error.localizedDescription)",
                isError: true,
                changedPaths: []
            )
        }
    }

    // MARK: - Edit File

    private func executeEditFile(args: [String: Any]) -> ToolExecutionResult {
        guard let path = args["path"] as? String else {
            return ToolExecutionResult(output: "Missing required parameter: path", isError: true, changedPaths: [])
        }
        guard let edits = args["edits"] as? [[String: Any]], !edits.isEmpty else {
            return ToolExecutionResult(output: "Missing or empty edits array", isError: true, changedPaths: [])
        }

        guard let resolved = resolveSafePath(path) else {
            return ToolExecutionResult(output: "Invalid path: \(path)", isError: true, changedPaths: [])
        }

        let normalizedPath = normalizeRelativePath(path)

        guard FileManager.default.fileExists(atPath: resolved.path) else {
            return ToolExecutionResult(output: "File not found: \(normalizedPath)", isError: true, changedPaths: [])
        }

        guard var content = try? String(contentsOf: resolved, encoding: .utf8) else {
            return ToolExecutionResult(output: "Could not read file: \(normalizedPath)", isError: true, changedPaths: [])
        }

        var successCount = 0
        var failures: [String] = []

        for (index, edit) in edits.enumerated() {
            guard let oldText = edit["old_text"] as? String, !oldText.isEmpty else {
                failures.append("Edit \(index + 1): missing or empty old_text")
                continue
            }
            guard let newText = edit["new_text"] as? String else {
                failures.append("Edit \(index + 1): missing new_text")
                continue
            }

            guard let range = content.range(of: oldText) else {
                let preview = oldText.count > 80 ? String(oldText.prefix(80)) + "..." : oldText
                failures.append("Edit \(index + 1): old_text not found: \"\(preview)\"")
                continue
            }

            content.replaceSubrange(range, with: newText)
            successCount += 1
        }

        if successCount > 0 {
            do {
                try content.write(to: resolved, atomically: true, encoding: .utf8)
            } catch {
                return ToolExecutionResult(
                    output: "Failed to save file after edits: \(error.localizedDescription)",
                    isError: true,
                    changedPaths: []
                )
            }
        }

        var resultLines: [String] = []
        if successCount > 0 {
            resultLines.append("Applied \(successCount)/\(edits.count) edits to \(normalizedPath)")
        }
        if !failures.isEmpty {
            resultLines.append(contentsOf: failures)
        }

        return ToolExecutionResult(
            output: resultLines.joined(separator: "\n"),
            isError: successCount == 0,
            changedPaths: successCount > 0 ? [normalizedPath] : []
        )
    }

    // MARK: - Delete File

    private func executeDeleteFile(args: [String: Any]) async -> ToolExecutionResult {
        guard let path = args["path"] as? String else {
            return ToolExecutionResult(output: "Missing required parameter: path", isError: true, changedPaths: [])
        }

        guard let resolved = resolveSafePath(path) else {
            return ToolExecutionResult(output: "Invalid path: \(path)", isError: true, changedPaths: [])
        }

        let normalizedPath = normalizeRelativePath(path)

        guard FileManager.default.fileExists(atPath: resolved.path) else {
            return ToolExecutionResult(output: "File not found: \(normalizedPath)", isError: true, changedPaths: [])
        }

        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory)
        if isDirectory.boolValue {
            return ToolExecutionResult(output: "Cannot delete directories, only files: \(normalizedPath)", isError: true, changedPaths: [])
        }

        // Always confirm file deletion
        if let handler = confirmationHandler {
            let approved = await handler.confirmDestructiveAction(
                description: String(
                    format: String(localized: "tool.confirm.delete_file"),
                    normalizedPath
                )
            )
            if !approved {
                return ToolExecutionResult(
                    output: "User denied deleting \(normalizedPath)",
                    isError: true,
                    changedPaths: []
                )
            }
        }

        do {
            try FileManager.default.removeItem(at: resolved)
            return ToolExecutionResult(
                output: "Successfully deleted \(normalizedPath)",
                isError: false,
                changedPaths: [normalizedPath]
            )
        } catch {
            return ToolExecutionResult(
                output: "Failed to delete \(normalizedPath): \(error.localizedDescription)",
                isError: true,
                changedPaths: []
            )
        }
    }

    // MARK: - Move File

    private func executeMoveFile(args: [String: Any]) -> ToolExecutionResult {
        guard let source = args["source"] as? String else {
            return ToolExecutionResult(output: "Missing required parameter: source", isError: true, changedPaths: [])
        }
        guard let destination = args["destination"] as? String else {
            return ToolExecutionResult(output: "Missing required parameter: destination", isError: true, changedPaths: [])
        }

        guard let resolvedSource = resolveSafePath(source) else {
            return ToolExecutionResult(output: "Invalid source path: \(source)", isError: true, changedPaths: [])
        }
        guard let resolvedDest = resolveSafePath(destination) else {
            return ToolExecutionResult(output: "Invalid destination path: \(destination)", isError: true, changedPaths: [])
        }

        let normalizedSource = normalizeRelativePath(source)
        let normalizedDest = normalizeRelativePath(destination)

        guard FileManager.default.fileExists(atPath: resolvedSource.path) else {
            return ToolExecutionResult(output: "Source file not found: \(normalizedSource)", isError: true, changedPaths: [])
        }

        if FileManager.default.fileExists(atPath: resolvedDest.path) {
            return ToolExecutionResult(output: "Destination already exists: \(normalizedDest)", isError: true, changedPaths: [])
        }

        do {
            let destDir = resolvedDest.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: resolvedSource, to: resolvedDest)
            return ToolExecutionResult(
                output: "Successfully moved \(normalizedSource) to \(normalizedDest)",
                isError: false,
                changedPaths: [normalizedSource, normalizedDest]
            )
        } catch {
            return ToolExecutionResult(
                output: "Failed to move \(normalizedSource) to \(normalizedDest): \(error.localizedDescription)",
                isError: true,
                changedPaths: []
            )
        }
    }

    // MARK: - List Directory

    private func executeListDirectory(args: [String: Any]) -> ToolExecutionResult {
        let rawPath = (args["path"] as? String) ?? "."
        let path = rawPath.isEmpty || rawPath == "." ? "" : rawPath

        let targetURL: URL
        if path.isEmpty {
            targetURL = projectURL
        } else {
            guard let resolved = resolveSafePath(path) else {
                return ToolExecutionResult(output: "Invalid path: \(path)", isError: true, changedPaths: [])
            }
            targetURL = resolved
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: targetURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            return ToolExecutionResult(output: "Not a directory: \(path.isEmpty ? "." : path)", isError: true, changedPaths: [])
        }

        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: targetURL,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return ToolExecutionResult(output: "Could not list directory: \(path.isEmpty ? "." : path)", isError: true, changedPaths: [])
        }

        let sorted = contents.sorted { $0.lastPathComponent < $1.lastPathComponent }
        var lines: [String] = []

        for fileURL in sorted.prefix(200) {
            let name = fileURL.lastPathComponent
            let values = try? fileURL.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            let isDir = values?.isDirectory ?? false
            if isDir {
                lines.append("\(name)/")
            } else {
                let size = values?.fileSize ?? 0
                lines.append("\(name)  (\(formattedByteCount(size)))")
            }
        }

        if sorted.count > 200 {
            lines.append("... and \(sorted.count - 200) more items")
        }

        let header = path.isEmpty ? "Project root:" : "\(path)/:"
        return ToolExecutionResult(
            output: header + "\n" + lines.joined(separator: "\n"),
            isError: false,
            changedPaths: []
        )
    }

    // MARK: - Search Files

    private func executeSearchFiles(args: [String: Any]) -> ToolExecutionResult {
        guard let query = args["query"] as? String, !query.isEmpty else {
            return ToolExecutionResult(output: "Missing required parameter: query", isError: true, changedPaths: [])
        }

        let searchPath = args["path"] as? String
        let searchRoot: URL
        if let searchPath, !searchPath.isEmpty, searchPath != "." {
            guard let resolved = resolveSafePath(searchPath) else {
                return ToolExecutionResult(output: "Invalid path: \(searchPath)", isError: true, changedPaths: [])
            }
            searchRoot = resolved
        } else {
            searchRoot = projectURL
        }

        guard let enumerator = FileManager.default.enumerator(
            at: searchRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return ToolExecutionResult(output: "Could not search directory", isError: true, changedPaths: [])
        }

        let loweredQuery = query.lowercased()
        var results: [String] = []
        var filesSearched = 0
        let maxResults = 50
        let maxFilesToSearch = 500

        for case let fileURL as URL in enumerator {
            guard filesSearched < maxFilesToSearch else { break }
            guard results.count < maxResults else { break }

            let values = try? fileURL.resourceValues(forKeys: [.isDirectoryKey])
            if values?.isDirectory == true { continue }

            let relativePath = normalizedRelativePath(fileURL: fileURL, rootURL: projectURL)
            guard isTextFile(relativePath) else { continue }

            guard let data = try? Data(contentsOf: fileURL),
                  data.count < configuration.maxBytesPerCatalogFile,
                  let content = String(data: data, encoding: .utf8)
            else { continue }

            filesSearched += 1
            let lines = content.components(separatedBy: .newlines)
            var fileMatches: [(lineNumber: Int, text: String)] = []

            for (index, line) in lines.enumerated() {
                guard fileMatches.count < 5 else { break }
                if line.lowercased().contains(loweredQuery) {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    let preview = trimmed.count > 120 ? String(trimmed.prefix(120)) + "..." : trimmed
                    fileMatches.append((lineNumber: index + 1, text: preview))
                }
            }

            if !fileMatches.isEmpty {
                results.append(relativePath)
                for match in fileMatches {
                    results.append("  L\(match.lineNumber): \(match.text)")
                }
            }
        }

        if results.isEmpty {
            return ToolExecutionResult(
                output: "No matches found for \"\(query)\" in \(filesSearched) files searched.",
                isError: false,
                changedPaths: []
            )
        }

        return ToolExecutionResult(
            output: "Search results for \"\(query)\":\n" + results.joined(separator: "\n"),
            isError: false,
            changedPaths: []
        )
    }

    // MARK: - Grep Files

    private func executeGrepFiles(args: [String: Any]) -> ToolExecutionResult {
        guard let pattern = args["pattern"] as? String, !pattern.isEmpty else {
            return ToolExecutionResult(output: "Missing required parameter: pattern", isError: true, changedPaths: [])
        }

        let caseSensitive = args["case_sensitive"] as? Bool ?? false
        let regexOptions: NSRegularExpression.Options = caseSensitive ? [] : [.caseInsensitive]

        let regex: NSRegularExpression
        do {
            regex = try NSRegularExpression(pattern: pattern, options: regexOptions)
        } catch {
            return ToolExecutionResult(
                output: "Invalid regex pattern: \(error.localizedDescription)",
                isError: true,
                changedPaths: []
            )
        }

        let searchPath = args["path"] as? String
        let searchRoot: URL
        if let searchPath, !searchPath.isEmpty, searchPath != "." {
            guard let resolved = resolveSafePath(searchPath) else {
                return ToolExecutionResult(output: "Invalid path: \(searchPath)", isError: true, changedPaths: [])
            }
            searchRoot = resolved
        } else {
            searchRoot = projectURL
        }

        guard let enumerator = FileManager.default.enumerator(
            at: searchRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return ToolExecutionResult(output: "Could not search directory", isError: true, changedPaths: [])
        }

        var results: [String] = []
        var filesSearched = 0
        let maxResults = 80
        let maxFilesToSearch = 500
        let maxMatchesPerFile = 8

        for case let fileURL as URL in enumerator {
            guard filesSearched < maxFilesToSearch else { break }
            guard results.count < maxResults else { break }

            let values = try? fileURL.resourceValues(forKeys: [.isDirectoryKey])
            if values?.isDirectory == true { continue }

            let relativePath = normalizedRelativePath(fileURL: fileURL, rootURL: projectURL)
            guard isTextFile(relativePath) else { continue }

            guard let data = try? Data(contentsOf: fileURL),
                  data.count < configuration.maxBytesPerCatalogFile,
                  let content = String(data: data, encoding: .utf8)
            else { continue }

            filesSearched += 1
            let lines = content.components(separatedBy: .newlines)
            var fileMatches: [(lineNumber: Int, text: String)] = []

            for (index, line) in lines.enumerated() {
                guard fileMatches.count < maxMatchesPerFile else { break }
                let range = NSRange(line.startIndex..., in: line)
                if regex.firstMatch(in: line, range: range) != nil {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    let preview = trimmed.count > 120 ? String(trimmed.prefix(120)) + "..." : trimmed
                    fileMatches.append((lineNumber: index + 1, text: preview))
                }
            }

            if !fileMatches.isEmpty {
                results.append(relativePath)
                for match in fileMatches {
                    results.append("  L\(match.lineNumber): \(match.text)")
                }
            }
        }

        if results.isEmpty {
            return ToolExecutionResult(
                output: "No matches found for /\(pattern)/ in \(filesSearched) files searched.",
                isError: false,
                changedPaths: []
            )
        }

        return ToolExecutionResult(
            output: "Grep results for /\(pattern)/:\n" + results.joined(separator: "\n"),
            isError: false,
            changedPaths: []
        )
    }

    // MARK: - Glob Files

    private func executeGlobFiles(args: [String: Any]) -> ToolExecutionResult {
        guard let pattern = args["pattern"] as? String, !pattern.isEmpty else {
            return ToolExecutionResult(output: "Missing required parameter: pattern", isError: true, changedPaths: [])
        }

        let searchPath = args["path"] as? String
        let searchRoot: URL
        if let searchPath, !searchPath.isEmpty, searchPath != "." {
            guard let resolved = resolveSafePath(searchPath) else {
                return ToolExecutionResult(output: "Invalid path: \(searchPath)", isError: true, changedPaths: [])
            }
            searchRoot = resolved
        } else {
            searchRoot = projectURL
        }

        guard let enumerator = FileManager.default.enumerator(
            at: searchRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return ToolExecutionResult(output: "Could not search directory", isError: true, changedPaths: [])
        }

        let globRegex = globPatternToRegex(pattern)

        var matches: [String] = []
        let maxResults = 200

        for case let fileURL as URL in enumerator {
            guard matches.count < maxResults else { break }

            let values = try? fileURL.resourceValues(forKeys: [.isDirectoryKey])
            if values?.isDirectory == true { continue }

            let relativePath = ProjectPathResolver.normalizedRelativePath(fileURL: fileURL, rootURL: projectURL)
            let range = NSRange(relativePath.startIndex..., in: relativePath)
            if globRegex.firstMatch(in: relativePath, range: range) != nil {
                matches.append(relativePath)
            }
        }

        if matches.isEmpty {
            return ToolExecutionResult(
                output: "No files matching \"\(pattern)\" found.",
                isError: false,
                changedPaths: []
            )
        }

        let sorted = matches.sorted()
        var output = "Found \(sorted.count) file(s) matching \"\(pattern)\":\n"
        output += sorted.joined(separator: "\n")
        if matches.count >= maxResults {
            output += "\n... (results limited to \(maxResults))"
        }

        return ToolExecutionResult(output: output, isError: false, changedPaths: [])
    }

    private func globPatternToRegex(_ pattern: String) -> NSRegularExpression {
        var regex = "^"
        var i = pattern.startIndex

        while i < pattern.endIndex {
            let ch = pattern[i]
            switch ch {
            case "*":
                let next = pattern.index(after: i)
                if next < pattern.endIndex && pattern[next] == "*" {
                    // ** — match any path (including separators)
                    let afterStars = pattern.index(after: next)
                    if afterStars < pattern.endIndex && pattern[afterStars] == "/" {
                        regex += "(.+/)?"
                        i = pattern.index(after: afterStars)
                        continue
                    } else {
                        regex += ".*"
                        i = pattern.index(after: next)
                        continue
                    }
                } else {
                    // * — match anything except /
                    regex += "[^/]*"
                }
            case "?":
                regex += "[^/]"
            case ".":
                regex += "\\."
            case "(", ")", "+", "^", "$", "|", "{", "}":
                regex += "\\\(ch)"
            default:
                regex += String(ch)
            }
            i = pattern.index(after: i)
        }

        regex += "$"

        return (try? NSRegularExpression(pattern: regex, options: [.caseInsensitive])) ??
            // Fallback: match nothing
            (try! NSRegularExpression(pattern: "^$", options: []))
    }

    // MARK: - Web Search

    private func executeWebSearch(args: [String: Any]) async -> ToolExecutionResult {
        guard let query = args["query"] as? String,
              !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ToolExecutionResult(output: "Missing required parameter: query", isError: true, changedPaths: [])
        }

        let result = await webToolProvider.webSearch(query: query)
        switch result {
        case let .success(searchResults):
            if searchResults.isEmpty {
                return ToolExecutionResult(
                    output: "No results found for \"\(query)\".",
                    isError: false,
                    changedPaths: []
                )
            }
            var lines: [String] = ["Search results for \"\(query)\":", ""]
            for (index, item) in searchResults.enumerated() {
                lines.append("[\(index + 1)] \(item.title)")
                lines.append("    URL: \(item.url)")
                if !item.description.isEmpty {
                    lines.append("    \(item.description)")
                }
                lines.append("")
            }
            return ToolExecutionResult(
                output: lines.joined(separator: "\n"),
                isError: false,
                changedPaths: []
            )
        case let .failure(error):
            return ToolExecutionResult(output: "Web search failed: \(error.message)", isError: true, changedPaths: [])
        }
    }

    // MARK: - Web Fetch

    private func executeWebFetch(args: [String: Any]) async -> ToolExecutionResult {
        guard let urlString = args["url"] as? String,
              !urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ToolExecutionResult(output: "Missing required parameter: url", isError: true, changedPaths: [])
        }

        let result = await webToolProvider.webFetch(urlString: urlString)
        switch result {
        case let .success(content):
            return ToolExecutionResult(
                output: "Content from \(urlString):\n\n\(content)",
                isError: false,
                changedPaths: []
            )
        case let .failure(error):
            return ToolExecutionResult(output: "Web fetch failed: \(error.message)", isError: true, changedPaths: [])
        }
    }

    // MARK: - Path Helpers (delegates to ProjectPathResolver)

    private func resolveSafePath(_ path: String) -> URL? {
        ProjectPathResolver.resolveSafePath(path, in: projectURL)
    }

    private func normalizeRelativePath(_ path: String) -> String {
        ProjectPathResolver.normalizeRelativePath(path)
    }

    private func normalizedRelativePath(fileURL: URL, rootURL: URL) -> String {
        ProjectPathResolver.normalizedRelativePath(fileURL: fileURL, rootURL: rootURL)
    }

    private func isTextFile(_ relativePath: String) -> Bool {
        ProjectPathResolver.isTextFile(relativePath)
    }

    private func formattedByteCount(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1_048_576 { return "\(bytes / 1024) KB" }
        return String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }
}
