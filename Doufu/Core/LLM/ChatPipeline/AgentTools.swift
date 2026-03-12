//
//  AgentTools.swift
//  Doufu
//
//  Created by Codex on 2026/03/08.
//

import Foundation

// MARK: - Tool Permission Model

/// User-facing permission mode controlling how much autonomy the AI has.
enum ToolPermissionMode: String, CaseIterable {
    /// Default: prompt for mutating operations on first use, always prompt for destructive ones.
    case standard
    /// Auto-approve all operations except destructive ones (delete, web).
    case autoApproveNonDestructive
    /// Auto-approve everything — no confirmation prompts at all.
    case fullAutoApprove
}

/// Permission tier for tool execution.
enum ToolPermissionTier {
    /// Read-only operations — never prompt the user.
    case autoAllow
    /// Mutating but recoverable operations (write, edit, move).
    /// Prompts on first use of each tool name in the session, then auto-allows.
    case confirmOnce
    /// Destructive or external operations (delete, web requests).
    /// Always prompts the user.
    case alwaysConfirm
}

/// Structured progress event emitted during tool execution.
enum ToolProgressEvent {
    /// A simple text description (fallback / thinking phase).
    case text(String)
    /// About to read a file.
    case readingFile(path: String)
    /// File read completed — includes a content preview.
    case fileRead(path: String, lineCount: Int, preview: String)
    /// About to write/create a file.
    case writingFile(path: String, isNew: Bool)
    /// File write completed.
    case fileWritten(path: String, characterCount: Int)
    /// About to apply edits to a file.
    case editingFile(path: String, editCount: Int)
    /// Edit completed — includes a diff-like summary.
    case fileEdited(path: String, appliedCount: Int, totalCount: Int, diffPreview: String)
    /// About to delete a file.
    case deletingFile(path: String)
    /// Listing a directory.
    case listingDirectory(path: String)
    /// Running a search/grep — includes result count when done.
    case searching(description: String)
    case searchCompleted(description: String, resultCount: Int)
    /// Web operations.
    case webActivity(description: String)
    /// Parallel batch of read-only operations.
    case parallelBatch(count: Int, descriptions: [String])
    /// Validating code in a hidden WebView.
    case validatingCode(path: String)
    /// Code validation completed.
    case codeValidated(path: String, errorCount: Int)
    /// Extended thinking content from the model (e.g. Claude thinking blocks).
    case thinking(content: String)
}

extension ToolProgressEvent {
    var displayText: String {
        switch self {
        case let .text(s):                            return s
        case let .readingFile(path):                  return String(format: String(localized: "tool.progress.reading_file"), path)
        case let .fileRead(path, lines, _):           return String(format: String(localized: "tool.progress.file_read"), path, lines)
        case let .writingFile(path, isNew):            return String(format: String(localized: isNew ? "tool.progress.creating_file" : "tool.progress.writing_file"), path)
        case let .fileWritten(path, chars):           return String(format: String(localized: "tool.progress.file_written"), path, chars)
        case let .editingFile(path, count):           return String(format: String(localized: "tool.progress.editing_file"), path, count)
        case let .fileEdited(path, applied, total, _): return String(format: String(localized: "tool.progress.file_edited"), path, applied, total)
        case let .deletingFile(path):                 return String(format: String(localized: "tool.progress.deleting_file"), path)
        case let .listingDirectory(path):             return String(format: String(localized: "tool.progress.listing_directory"), path)
        case let .searching(desc):                    return desc
        case let .searchCompleted(desc, count):       return String(format: String(localized: "tool.progress.search_completed"), desc, count)
        case let .webActivity(desc):                  return desc
        case let .validatingCode(path):               return String(format: String(localized: "tool.progress.validating_code"), path)
        case let .codeValidated(path, count):         return count == 0
            ? String(format: String(localized: "tool.progress.validation_passed"), path)
            : String(format: String(localized: "tool.progress.validation_failed"), count, path)
        case let .parallelBatch(count, _):            return String(format: String(localized: "tool.progress.parallel_batch"), count)
        case .thinking:                               return String(localized: "tool.progress.thinking")
        }
    }
}

protocol ToolConfirmationHandler: AnyObject {
    /// Ask the user to confirm a tool action.  `tier` indicates the severity.
    @MainActor func confirmToolAction(
        toolName: String,
        tier: ToolPermissionTier,
        description: String
    ) async -> Bool
}

enum ToolConfirmationDecision {
    case approved
    case denied
    case deferred
}

protocol ToolConfirmationPresenter: AnyObject {
    /// Present a user-facing confirmation UI for a tool action.
    @MainActor func presentToolConfirmation(
        toolName: String,
        tier: ToolPermissionTier,
        description: String
    ) async -> ToolConfirmationDecision

    /// Dismiss any in-flight confirmation UI and defer it back to the session.
    @MainActor func cancelPendingToolConfirmationPresentation()
}

final class AgentToolProvider {
    private let workspaceURL: URL
    private let configuration: ProjectChatConfiguration
    weak var confirmationHandler: ToolConfirmationHandler?
    var permissionMode: ToolPermissionMode = .standard
    var codeValidator: CodeValidator?
    var validationServerBaseURL: URL?
    var validationBridge: DoufuBridge?

    /// Tools the user has already approved in this session (for `.confirmOnce` tier).
    private var approvedOnceTools: Set<String> = []

    init(workspaceURL: URL, configuration: ProjectChatConfiguration = .default) {
        self.workspaceURL = workspaceURL
        self.configuration = configuration
    }

    // MARK: - Permission Tier Mapping

    static func permissionTier(for toolName: String) -> ToolPermissionTier {
        switch toolName {
        case "read_file", "list_directory", "search_files", "grep_files", "glob_files", "validate_code",
             "diff_file", "changed_files":
            return .autoAllow
        case "write_file", "edit_file", "revert_file":
            return .confirmOnce
        case "delete_file", "move_file", "web_search", "web_fetch":
            return .alwaysConfirm
        default:
            return .alwaysConfirm
        }
    }

    /// Check permission for a tool action.  Returns `true` if the action is allowed.
    private func checkPermission(toolName: String, description: String) async -> Bool {
        let tier = Self.permissionTier(for: toolName)

        // Apply permission mode overrides
        switch permissionMode {
        case .fullAutoApprove:
            return true
        case .autoApproveNonDestructive:
            if tier != .alwaysConfirm { return true }
            // Fall through to prompt for destructive operations
        case .standard:
            break
        }

        switch tier {
        case .autoAllow:
            return true
        case .confirmOnce:
            if approvedOnceTools.contains(toolName) { return true }
            guard let handler = confirmationHandler else { return false }
            let approved = await handler.confirmToolAction(
                toolName: toolName, tier: tier, description: description
            )
            if approved { approvedOnceTools.insert(toolName) }
            return approved
        case .alwaysConfirm:
            guard let handler = confirmationHandler else { return false }
            return await handler.confirmToolAction(
                toolName: toolName, tier: tier, description: description
            )
        }
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
            revertFileTool(),
            diffFileTool(),
            changedFilesTool(),
            listDirectoryTool(),
            searchFilesTool(),
            grepFilesTool(),
            globFilesTool(),
            webSearchTool(),
            webFetchTool(),
            validateCodeTool(),
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
            description: "Make targeted edits to an existing file using search and replace. Edits are applied sequentially — earlier edits change the file content before later edits run, so plan accordingly. The tool uses multi-level fuzzy matching: if an exact match isn't found, it automatically tries indentation normalization, whitespace normalization, and line-trimmed matching. You don't need to match whitespace perfectly, but provide enough unique context (a few surrounding lines) to avoid ambiguous matches. Always read the file first before editing.",
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
                                    "description": .string("The text to find in the file. Include enough surrounding lines for a unique match. Whitespace and indentation differences are tolerated automatically.")
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

    private func revertFileTool() -> AgentToolDefinition {
        AgentToolDefinition(
            name: "revert_file",
            description: "Revert a single file to its state at the last git checkpoint (before the current agent loop started). Use this when your edits to a file caused problems and you want to start over with that file. Does not affect other files.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object([
                        "type": .string("string"),
                        "description": .string("File path relative to project root to revert")
                    ])
                ]),
                "required": .array([.string("path")]),
                "additionalProperties": .bool(false)
            ])
        )
    }

    private func diffFileTool() -> AgentToolDefinition {
        AgentToolDefinition(
            name: "diff_file",
            description: "Show a unified diff of a file comparing the current content to its state at the start of this session (the last checkpoint). Useful for reviewing what you changed before responding to the user. Returns nothing if the file is unchanged.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object([
                        "type": .string("string"),
                        "description": .string("File path relative to project root")
                    ])
                ]),
                "required": .array([.string("path")]),
                "additionalProperties": .bool(false)
            ])
        )
    }

    private func changedFilesTool() -> AgentToolDefinition {
        AgentToolDefinition(
            name: "changed_files",
            description: "List all files that have been modified, added, or deleted since the start of this session (the last checkpoint). Useful for reviewing the overall scope of changes you have made.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([:]),
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
                    ]),
                    "include": .object([
                        "type": .string("string"),
                        "description": .string("Optional glob pattern to filter by file name (not path), e.g. '*.js', '*.{html,css}'. Only files whose name matches will be searched.")
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
                    "include": .object([
                        "type": .string("string"),
                        "description": .string("Optional glob pattern to filter by file name (not path), e.g. '*.js', '*.{html,css}'. Only files whose name matches will be searched.")
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
            description: "Fetch the content of a web page. By default returns extracted text with HTML stripped. Set raw to true to get the original HTML, useful when you need to parse the page structure (tables, lists, specific tags). Only supports http/https URLs.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "url": .object([
                        "type": .string("string"),
                        "description": .string("The full URL to fetch (must start with http:// or https://)")
                    ]),
                    "raw": .object([
                        "type": .string("boolean"),
                        "description": .string("When true, return the original HTML instead of extracted text. Defaults to false.")
                    ])
                ]),
                "required": .array([.string("url")]),
                "additionalProperties": .bool(false)
            ])
        )
    }

    private func validateCodeTool() -> AgentToolDefinition {
        AgentToolDefinition(
            name: "validate_code",
            description: "Validate HTML/JS code by loading it in a hidden browser and checking for JavaScript errors. Use this after writing or editing HTML/JS files to catch syntax errors, runtime errors, and missing references before the user sees them. If errors are found, fix them with edit_file and validate again.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object([
                        "type": .string("string"),
                        "description": .string("Path to the HTML entry file to validate, relative to project root (e.g. 'index.html')")
                    ])
                ]),
                "required": .array([.string("path")]),
                "additionalProperties": .bool(false)
            ])
        )
    }

    // MARK: - Tool Result Metadata

    /// Structured metadata attached to a tool execution result.
    /// Enables the UI layer to render rich information (diffs, file stats, etc.).
    enum ToolResultMetadata {
        /// File read — includes line count and byte size.
        case fileRead(path: String, lineCount: Int, sizeBytes: Int64)
        /// File written or created.
        case fileWritten(path: String, isNew: Bool, sizeBytes: Int64)
        /// File edited with a unified-diff-style preview.
        case fileEdited(path: String, editCount: Int, diffPreview: String)
        /// File deleted.
        case fileDeleted(path: String, sizeBytes: Int64)
        /// File moved / renamed.
        case fileMoved(source: String, destination: String)
        /// File reverted to its original content.
        case fileReverted(path: String)
        /// Directory listing.
        case directoryListed(path: String, entryCount: Int, directories: Int, files: Int)
        /// Search / grep / glob results.
        case searchResult(query: String, matchCount: Int, matchedFiles: [String])
        /// Web search or fetch.
        case webResult(url: String?, statusCode: Int?)
        /// Code validation result.
        case codeValidation(path: String, errorCount: Int, passed: Bool)
    }

    // MARK: - Tool Execution

    struct ToolExecutionResult {
        let output: String
        let isError: Bool
        let changedPaths: [String]
        /// Structured metadata for UI rendering (diff preview, file stats, etc.).
        var metadata: ToolResultMetadata?
        /// Structured progress event emitted after execution completes.
        var completionEvent: ToolProgressEvent?
        /// Brief summary of what changed (e.g. "wrote 45 lines", "edited 2 regions").
        /// Used to enrich `changedFiles` in session memory.
        var changeSummary: String?
    }

    func execute(
        toolCall: AgentToolCall,
        onProgress: (@MainActor (ToolProgressEvent) -> Void)? = nil
    ) async -> ToolExecutionResult {
        if Task.isCancelled {
            return ToolExecutionResult(output: "Operation cancelled.", isError: true, changedPaths: [])
        }

        // Detect malformed tool call JSON early — give the LLM a clear signal
        // to retry instead of a confusing "Missing required parameter" error.
        let args: [String: Any]
        if let decoded = toolCall.decodedArguments() {
            args = decoded
        } else {
            let raw = toolCall.argumentsJSON.trimmingCharacters(in: .whitespacesAndNewlines)
            if !raw.isEmpty && raw != "{}" {
                let preview = String(raw.prefix(200))
                return ToolExecutionResult(
                    output: "Tool call failed: the arguments JSON is malformed and could not be parsed. Raw JSON: \(preview). Please retry with valid JSON.",
                    isError: true,
                    changedPaths: []
                )
            }
            args = [:]
        }

        switch toolCall.name {
        case "read_file":
            let path = (args["path"] as? String) ?? "?"
            if let onProgress { await onProgress(.readingFile(path: path)) }
            return executeReadFile(args: args)
        case "write_file":
            let path = (args["path"] as? String) ?? "?"
            let isNew = !FileManager.default.fileExists(
                atPath: resolveSafePath(path)?.path ?? ""
            )
            if let onProgress { await onProgress(.writingFile(path: path, isNew: isNew)) }
            return await executeWriteFile(args: args)
        case "edit_file":
            let path = (args["path"] as? String) ?? "?"
            let editCount = (args["edits"] as? [Any])?.count ?? 0
            if let onProgress { await onProgress(.editingFile(path: path, editCount: editCount)) }
            return await executeEditFile(args: args)
        case "delete_file":
            let path = (args["path"] as? String) ?? "?"
            if let onProgress { await onProgress(.deletingFile(path: path)) }
            return await executeDeleteFile(args: args)
        case "move_file":
            return await executeMoveFile(args: args)
        case "revert_file":
            return await executeRevertFile(args: args)
        case "diff_file":
            return executeDiffFile(args: args)
        case "changed_files":
            return executeChangedFiles()
        case "list_directory":
            let path = (args["path"] as? String) ?? "."
            if let onProgress { await onProgress(.listingDirectory(path: path)) }
            return executeListDirectory(args: args)
        case "search_files":
            let query = (args["query"] as? String) ?? "?"
            if let onProgress { await onProgress(.searching(description: String(format: String(localized: "tool.progress.search_files"), query))) }
            return executeSearchFiles(args: args)
        case "grep_files":
            let pattern = (args["pattern"] as? String) ?? "?"
            if let onProgress { await onProgress(.searching(description: String(format: String(localized: "tool.progress.grep_files"), pattern))) }
            return executeGrepFiles(args: args)
        case "glob_files":
            let pattern = (args["pattern"] as? String) ?? "?"
            if let onProgress { await onProgress(.searching(description: String(format: String(localized: "tool.progress.glob_files"), pattern))) }
            return executeGlobFiles(args: args)
        case "web_search":
            let query = (args["query"] as? String) ?? "?"
            if let onProgress { await onProgress(.webActivity(description: String(format: String(localized: "tool.progress.web_search"), query))) }
            return await executeWebSearch(args: args)
        case "web_fetch":
            let url = (args["url"] as? String) ?? "?"
            if let onProgress { await onProgress(.webActivity(description: String(format: String(localized: "tool.progress.web_fetch"), url))) }
            return await executeWebFetch(args: args)
        case "validate_code":
            let path = (args["path"] as? String) ?? "?"
            if let onProgress { await onProgress(.validatingCode(path: path)) }
            return await executeValidateCode(args: args, onProgress: onProgress)
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

        let isTruncated = data.count > configuration.maxBytesPerContextFile
        let lineCount = content.components(separatedBy: .newlines).count

        let truncationNote = isTruncated
            ? "\n\n[Note: File truncated at \(configuration.maxBytesPerContextFile) bytes. Total size: \(data.count) bytes]"
            : ""

        let previewLines = content.components(separatedBy: .newlines).prefix(5)
        let preview = previewLines.joined(separator: "\n")

        return ToolExecutionResult(
            output: content + truncationNote,
            isError: false,
            changedPaths: [],
            metadata: .fileRead(path: normalizeRelativePath(path), lineCount: lineCount, sizeBytes: Int64(data.count)),
            completionEvent: .fileRead(path: path, lineCount: lineCount, preview: preview)
        )
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

        // Permission check (confirmOnce for write_file; overwriting existing files mentioned in description)
        let description = fileExists
            ? String(format: String(localized: "tool.confirm.overwrite_file"), normalizedPath)
            : String(format: String(localized: "tool.confirm.create_file"), normalizedPath)
        let approved = await checkPermission(toolName: "write_file", description: description)
        if !approved {
            return ToolExecutionResult(
                output: "User denied writing \(normalizedPath)",
                isError: true,
                changedPaths: []
            )
        }

        do {
            let directoryURL = resolved.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            try content.write(to: resolved, atomically: true, encoding: .utf8)
            let writtenSize = (try? Data(contentsOf: resolved).count) ?? content.utf8.count
            let lineCount = content.components(separatedBy: .newlines).count
            let verb = fileExists ? "overwrote" : "created"
            return ToolExecutionResult(
                output: "Successfully wrote \(content.count) characters to \(normalizedPath)",
                isError: false,
                changedPaths: [normalizedPath],
                metadata: .fileWritten(path: normalizedPath, isNew: !fileExists, sizeBytes: Int64(writtenSize)),
                completionEvent: .fileWritten(path: normalizedPath, characterCount: content.count),
                changeSummary: "\(verb) \(lineCount) lines"
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

    private func executeEditFile(args: [String: Any]) async -> ToolExecutionResult {
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

        // Permission check
        let description = String(
            format: String(localized: "tool.confirm.edit_file"),
            normalizedPath, edits.count
        )
        let approved = await checkPermission(toolName: "edit_file", description: description)
        if !approved {
            return ToolExecutionResult(
                output: "User denied editing \(normalizedPath)",
                isError: true,
                changedPaths: []
            )
        }

        guard FileManager.default.fileExists(atPath: resolved.path) else {
            return ToolExecutionResult(output: "File not found: \(normalizedPath)", isError: true, changedPaths: [])
        }

        guard var content = try? String(contentsOf: resolved, encoding: .utf8) else {
            return ToolExecutionResult(output: "Could not read file: \(normalizedPath)", isError: true, changedPaths: [])
        }

        var successCount = 0
        var failures: [String] = []
        var editDetails: [String] = []

        for (index, edit) in edits.enumerated() {
            guard let oldText = edit["old_text"] as? String, !oldText.isEmpty else {
                failures.append("Edit \(index + 1): missing or empty old_text")
                continue
            }
            guard let newText = edit["new_text"] as? String else {
                failures.append("Edit \(index + 1): missing new_text")
                continue
            }

            let matchResult = findEditMatch(oldText: oldText, in: content)
            switch matchResult {
            case let .exact(range):
                let lineNumber = content[..<range.lowerBound].components(separatedBy: .newlines).count
                content.replaceSubrange(range, with: newText)
                successCount += 1
                editDetails.append("Edit \(index + 1): replaced at line \(lineNumber)")
            case let .fuzzy(range, strategy):
                let lineNumber = content[..<range.lowerBound].components(separatedBy: .newlines).count
                content.replaceSubrange(range, with: newText)
                successCount += 1
                editDetails.append("Edit \(index + 1): applied with \(strategy) at line \(lineNumber)")
            case .ambiguous:
                let preview = oldText.count > 80 ? String(oldText.prefix(80)) + "..." : oldText
                failures.append("Edit \(index + 1): old_text matches multiple locations. Please provide more surrounding context to ensure a unique match: \"\(preview)\"")
            case let .notFound(hint):
                let preview = oldText.count > 80 ? String(oldText.prefix(80)) + "..." : oldText
                var message = "Edit \(index + 1): old_text not found: \"\(preview)\""
                if let hint { message += "\n  Hint: \(hint)" }
                failures.append(message)
            }
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
            resultLines.append(contentsOf: editDetails)
        }
        if !failures.isEmpty {
            resultLines.append(contentsOf: failures)
        }

        let diffPreview = editDetails.joined(separator: "\n")
        let editSummary: String? = successCount > 0
            ? "edited \(successCount) region\(successCount == 1 ? "" : "s")"
            : nil

        return ToolExecutionResult(
            output: resultLines.joined(separator: "\n"),
            isError: successCount == 0,
            changedPaths: successCount > 0 ? [normalizedPath] : [],
            metadata: successCount > 0
                ? .fileEdited(path: normalizedPath, editCount: successCount, diffPreview: diffPreview)
                : nil,
            completionEvent: .fileEdited(
                path: normalizedPath,
                appliedCount: successCount,
                totalCount: edits.count,
                diffPreview: diffPreview
            ),
            changeSummary: editSummary
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

        let fileSizeBytes = Int64((try? FileManager.default.attributesOfItem(atPath: resolved.path)[.size] as? Int) ?? 0)

        // Always confirm file deletion (alwaysConfirm tier)
        let description = String(format: String(localized: "tool.confirm.delete_file"), normalizedPath)
        let approved = await checkPermission(toolName: "delete_file", description: description)
        if !approved {
            return ToolExecutionResult(
                output: "User denied deleting \(normalizedPath)",
                isError: true,
                changedPaths: []
            )
        }

        do {
            try FileManager.default.removeItem(at: resolved)
            return ToolExecutionResult(
                output: "Successfully deleted \(normalizedPath)",
                isError: false,
                changedPaths: [normalizedPath],
                metadata: .fileDeleted(path: normalizedPath, sizeBytes: fileSizeBytes)
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

    private func executeMoveFile(args: [String: Any]) async -> ToolExecutionResult {
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

        let description = String(
            format: String(localized: "tool.confirm.move_file"),
            normalizedSource, normalizedDest
        )
        let approved = await checkPermission(toolName: "move_file", description: description)
        if !approved {
            return ToolExecutionResult(
                output: "User denied moving \(normalizedSource) to \(normalizedDest)",
                isError: true,
                changedPaths: []
            )
        }

        do {
            let destDir = resolvedDest.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: resolvedSource, to: resolvedDest)
            return ToolExecutionResult(
                output: "Successfully moved \(normalizedSource) to \(normalizedDest)",
                isError: false,
                changedPaths: [normalizedSource, normalizedDest],
                metadata: .fileMoved(source: normalizedSource, destination: normalizedDest)
            )
        } catch {
            return ToolExecutionResult(
                output: "Failed to move \(normalizedSource) to \(normalizedDest): \(error.localizedDescription)",
                isError: true,
                changedPaths: []
            )
        }
    }

    // MARK: - Revert File

    private func executeRevertFile(args: [String: Any]) async -> ToolExecutionResult {
        guard let path = args["path"] as? String else {
            return ToolExecutionResult(output: "Missing required parameter: path", isError: true, changedPaths: [])
        }

        guard let resolved = resolveSafePath(path) else {
            return ToolExecutionResult(output: "Invalid path: \(path)", isError: true, changedPaths: [])
        }

        let normalizedPath = normalizeRelativePath(path)

        let description = String(format: String(localized: "tool.confirm.revert_file"), normalizedPath)
        let approved = await checkPermission(toolName: "revert_file", description: description)
        if !approved {
            return ToolExecutionResult(output: "User denied reverting \(normalizedPath)", isError: true, changedPaths: [])
        }

        do {
            let repo = try ProjectGitService.shared.openRepositoryForRevert(at: workspaceURL)

            // Get the file content from HEAD (the checkpoint commit)
            let headContent = try ProjectGitService.shared.fileContentAtHEAD(
                repo: repo,
                relativePath: normalizedPath
            )

            if let headContent {
                // File exists in checkpoint — restore its content
                try headContent.write(to: resolved, atomically: true, encoding: .utf8)
            } else if FileManager.default.fileExists(atPath: resolved.path) {
                // File doesn't exist in checkpoint but exists on disk — delete it
                try FileManager.default.removeItem(at: resolved)
            } else {
                return ToolExecutionResult(
                    output: "File \(normalizedPath) not found in the last checkpoint and does not exist on disk.",
                    isError: true,
                    changedPaths: []
                )
            }

            return ToolExecutionResult(
                output: headContent != nil
                    ? "Successfully reverted \(normalizedPath) to its checkpoint state."
                    : "Successfully deleted \(normalizedPath) (file did not exist at checkpoint).",
                isError: false,
                changedPaths: [normalizedPath],
                metadata: .fileReverted(path: normalizedPath)
            )
        } catch {
            return ToolExecutionResult(
                output: "Failed to revert \(normalizedPath): \(error.localizedDescription)",
                isError: true,
                changedPaths: []
            )
        }
    }

    // MARK: - Diff File

    private func executeDiffFile(args: [String: Any]) -> ToolExecutionResult {
        guard let path = args["path"] as? String else {
            return ToolExecutionResult(output: "Missing required parameter: path", isError: true, changedPaths: [])
        }

        // Validate path stays within workspace sandbox
        guard resolveSafePath(path) != nil else {
            return ToolExecutionResult(output: "Invalid path: \(path)", isError: true, changedPaths: [])
        }

        let normalizedPath = normalizeRelativePath(path)
        do {
            guard let diff = try ProjectGitService.shared.diffFileAgainstHEAD(
                repositoryURL: workspaceURL,
                relativePath: normalizedPath
            ) else {
                return ToolExecutionResult(
                    output: "No changes to \(normalizedPath) since the start of this session.",
                    isError: false,
                    changedPaths: []
                )
            }
            return ToolExecutionResult(output: diff, isError: false, changedPaths: [])
        } catch {
            return ToolExecutionResult(
                output: "Failed to diff \(normalizedPath): \(error.localizedDescription)",
                isError: true,
                changedPaths: []
            )
        }
    }

    // MARK: - Changed Files

    private func executeChangedFiles() -> ToolExecutionResult {
        do {
            let paths = try ProjectGitService.shared.changedFilesSinceCheckpoint(repositoryURL: workspaceURL)
            if paths.isEmpty {
                return ToolExecutionResult(
                    output: "No files have been changed since the start of this session.",
                    isError: false,
                    changedPaths: []
                )
            }
            let listing = paths.sorted().joined(separator: "\n")
            return ToolExecutionResult(
                output: "\(paths.count) file(s) changed:\n\(listing)",
                isError: false,
                changedPaths: []
            )
        } catch {
            return ToolExecutionResult(
                output: "Failed to list changed files: \(error.localizedDescription)",
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
            targetURL = workspaceURL
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
        let dirCount = sorted.prefix(200).filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }.count
        let fileCount = sorted.prefix(200).count - dirCount
        let displayPath = path.isEmpty ? "." : path
        return ToolExecutionResult(
            output: header + "\n" + lines.joined(separator: "\n"),
            isError: false,
            changedPaths: [],
            metadata: .directoryListed(path: displayPath, entryCount: sorted.count, directories: dirCount, files: fileCount)
        )
    }

    // MARK: - Search Files

    private func executeSearchFiles(args: [String: Any]) -> ToolExecutionResult {
        guard let query = args["query"] as? String, !query.isEmpty else {
            return ToolExecutionResult(output: "Missing required parameter: query", isError: true, changedPaths: [])
        }

        let searchPath = args["path"] as? String
        let includePattern = args["include"] as? String
        let searchRoot: URL
        if let searchPath, !searchPath.isEmpty, searchPath != "." {
            guard let resolved = resolveSafePath(searchPath) else {
                return ToolExecutionResult(output: "Invalid path: \(searchPath)", isError: true, changedPaths: [])
            }
            searchRoot = resolved
        } else {
            searchRoot = workspaceURL
        }

        let includeRegex = includePattern.flatMap { buildIncludeRegex($0) }

        guard let enumerator = FileManager.default.enumerator(
            at: searchRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return ToolExecutionResult(output: "Could not search directory", isError: true, changedPaths: [])
        }

        let loweredQuery = query.lowercased()
        var results: [String] = []
        var matchedFileCount = 0
        var filesSearched = 0
        let maxMatchedFiles = 50
        let maxFilesToSearch = 500

        for case let fileURL as URL in enumerator {
            guard filesSearched < maxFilesToSearch else { break }
            guard matchedFileCount < maxMatchedFiles else { break }

            let values = try? fileURL.resourceValues(forKeys: [.isDirectoryKey])
            if values?.isDirectory == true { continue }

            let relativePath = normalizedRelativePath(fileURL: fileURL, rootURL: workspaceURL)
            guard isTextFile(relativePath) else { continue }

            // Apply include filter if specified
            if let includeRegex {
                let fileName = fileURL.lastPathComponent
                let range = NSRange(fileName.startIndex..., in: fileName)
                guard includeRegex.firstMatch(in: fileName, range: range) != nil else { continue }
            }

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
                matchedFileCount += 1
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
                changedPaths: [],
                metadata: .searchResult(query: query, matchCount: 0, matchedFiles: []),
                completionEvent: .searchCompleted(description: String(format: String(localized: "tool.progress.search_files"), query), resultCount: 0)
            )
        }

        let matchedFiles = results.filter { !$0.hasPrefix("  ") }
        let matchingFileCount = matchedFiles.count
        return ToolExecutionResult(
            output: "Search results for \"\(query)\":\n" + results.joined(separator: "\n"),
            isError: false,
            changedPaths: [],
            metadata: .searchResult(query: query, matchCount: matchingFileCount, matchedFiles: matchedFiles),
            completionEvent: .searchCompleted(description: String(format: String(localized: "tool.progress.search_files"), query), resultCount: matchingFileCount)
        )
    }

    // MARK: - Grep Files

    private func executeGrepFiles(args: [String: Any]) -> ToolExecutionResult {
        guard let pattern = args["pattern"] as? String, !pattern.isEmpty else {
            return ToolExecutionResult(output: "Missing required parameter: pattern", isError: true, changedPaths: [])
        }

        let caseSensitive = args["case_sensitive"] as? Bool ?? false
        let includePattern = args["include"] as? String
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
        let includeRegex = includePattern.flatMap { buildIncludeRegex($0) }
        let searchRoot: URL
        if let searchPath, !searchPath.isEmpty, searchPath != "." {
            guard let resolved = resolveSafePath(searchPath) else {
                return ToolExecutionResult(output: "Invalid path: \(searchPath)", isError: true, changedPaths: [])
            }
            searchRoot = resolved
        } else {
            searchRoot = workspaceURL
        }

        guard let enumerator = FileManager.default.enumerator(
            at: searchRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return ToolExecutionResult(output: "Could not search directory", isError: true, changedPaths: [])
        }

        var results: [String] = []
        var matchedFileCount = 0
        var filesSearched = 0
        let maxMatchedFiles = 80
        let maxFilesToSearch = 500
        let maxMatchesPerFile = 8

        for case let fileURL as URL in enumerator {
            guard filesSearched < maxFilesToSearch else { break }
            guard matchedFileCount < maxMatchedFiles else { break }

            let values = try? fileURL.resourceValues(forKeys: [.isDirectoryKey])
            if values?.isDirectory == true { continue }

            let relativePath = normalizedRelativePath(fileURL: fileURL, rootURL: workspaceURL)
            guard isTextFile(relativePath) else { continue }

            // Apply include filter if specified
            if let includeRegex {
                let fileName = fileURL.lastPathComponent
                let range = NSRange(fileName.startIndex..., in: fileName)
                guard includeRegex.firstMatch(in: fileName, range: range) != nil else { continue }
            }

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
                matchedFileCount += 1
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
                changedPaths: [],
                metadata: .searchResult(query: "/\(pattern)/", matchCount: 0, matchedFiles: []),
                completionEvent: .searchCompleted(description: String(format: String(localized: "tool.progress.grep_files"), pattern), resultCount: 0)
            )
        }

        let matchedFiles = results.filter { !$0.hasPrefix("  ") }
        let matchingFileCount = matchedFiles.count
        return ToolExecutionResult(
            output: "Grep results for /\(pattern)/:\n" + results.joined(separator: "\n"),
            isError: false,
            changedPaths: [],
            metadata: .searchResult(query: "/\(pattern)/", matchCount: matchingFileCount, matchedFiles: matchedFiles),
            completionEvent: .searchCompleted(description: String(format: String(localized: "tool.progress.grep_files"), pattern), resultCount: matchingFileCount)
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
            searchRoot = workspaceURL
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

            let relativePath = ProjectPathResolver.normalizedRelativePath(fileURL: fileURL, rootURL: workspaceURL)
            let range = NSRange(relativePath.startIndex..., in: relativePath)
            if globRegex.firstMatch(in: relativePath, range: range) != nil {
                matches.append(relativePath)
            }
        }

        if matches.isEmpty {
            return ToolExecutionResult(
                output: "No files matching \"\(pattern)\" found.",
                isError: false,
                changedPaths: [],
                metadata: .searchResult(query: pattern, matchCount: 0, matchedFiles: [])
            )
        }

        let sorted = matches.sorted()
        var output = "Found \(sorted.count) file(s) matching \"\(pattern)\":\n"
        output += sorted.joined(separator: "\n")
        if matches.count >= maxResults {
            output += "\n... (results limited to \(maxResults))"
        }

        return ToolExecutionResult(
            output: output,
            isError: false,
            changedPaths: [],
            metadata: .searchResult(query: pattern, matchCount: sorted.count, matchedFiles: sorted),
            completionEvent: .searchCompleted(description: String(format: String(localized: "tool.progress.glob_files"), pattern), resultCount: sorted.count)
        )
    }

    private func globPatternToRegex(_ pattern: String) -> NSRegularExpression {
        // Expand brace groups: "**/*.{html,css}" → ["**/*.html", "**/*.css"]
        var alternatives: [String] = []
        if let braceOpen = pattern.range(of: "{"),
           let braceClose = pattern.range(of: "}", range: braceOpen.upperBound..<pattern.endIndex) {
            let prefix = String(pattern[pattern.startIndex..<braceOpen.lowerBound])
            let suffix = String(pattern[braceClose.upperBound..<pattern.endIndex])
            let inner = String(pattern[braceOpen.upperBound..<braceClose.lowerBound])
            for part in inner.components(separatedBy: ",") {
                alternatives.append(prefix + part.trimmingCharacters(in: .whitespaces) + suffix)
            }
        } else {
            alternatives = [pattern]
        }

        let regexParts = alternatives.map { alt -> String in
            var regex = "^"
            var i = alt.startIndex

            while i < alt.endIndex {
                let ch = alt[i]
                switch ch {
                case "*":
                    let next = alt.index(after: i)
                    if next < alt.endIndex && alt[next] == "*" {
                        // ** — match any path (including separators)
                        let afterStars = alt.index(after: next)
                        if afterStars < alt.endIndex && alt[afterStars] == "/" {
                            regex += "(.+/)?"
                            i = alt.index(after: afterStars)
                            continue
                        } else {
                            regex += ".*"
                            i = alt.index(after: next)
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
                case "(", ")", "+", "^", "$", "|", "[", "]":
                    regex += "\\\(ch)"
                default:
                    regex += String(ch)
                }
                i = alt.index(after: i)
            }

            regex += "$"
            return regex
        }

        let combined = regexParts.count == 1 ? regexParts[0] : "(\(regexParts.joined(separator: "|")))"

        return (try? NSRegularExpression(pattern: combined, options: [.caseInsensitive])) ??
            // Fallback: match nothing
            (try! NSRegularExpression(pattern: "^$", options: []))
    }

    // MARK: - Web Search

    private func executeWebSearch(args: [String: Any]) async -> ToolExecutionResult {
        guard let query = args["query"] as? String,
              !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ToolExecutionResult(output: "Missing required parameter: query", isError: true, changedPaths: [])
        }

        let description = String(format: String(localized: "tool.confirm.web_search"), query)
        let approved = await checkPermission(toolName: "web_search", description: description)
        if !approved {
            return ToolExecutionResult(output: "User denied web search for \"\(query)\"", isError: true, changedPaths: [])
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
                changedPaths: [],
                metadata: .webResult(url: nil, statusCode: nil)
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

        let description = String(format: String(localized: "tool.confirm.web_fetch"), urlString)
        let approved = await checkPermission(toolName: "web_fetch", description: description)
        if !approved {
            return ToolExecutionResult(output: "User denied fetching \(urlString)", isError: true, changedPaths: [])
        }

        let raw = args["raw"] as? Bool ?? false
        let result = await webToolProvider.webFetch(urlString: urlString, raw: raw)
        switch result {
        case let .success(fetchResult):
            return ToolExecutionResult(
                output: "Content from \(urlString):\n\n\(fetchResult.content)",
                isError: false,
                changedPaths: [],
                metadata: .webResult(url: urlString, statusCode: fetchResult.statusCode)
            )
        case let .failure(error):
            return ToolExecutionResult(output: "Web fetch failed: \(error.message)", isError: true, changedPaths: [])
        }
    }

    // MARK: - Validate Code

    private func executeValidateCode(
        args: [String: Any],
        onProgress: (@MainActor (ToolProgressEvent) -> Void)?
    ) async -> ToolExecutionResult {
        guard let path = args["path"] as? String else {
            return ToolExecutionResult(output: "Missing required parameter: path", isError: true, changedPaths: [])
        }

        guard let resolved = resolveSafePath(path) else {
            return ToolExecutionResult(output: "Invalid path: \(path)", isError: true, changedPaths: [])
        }

        guard FileManager.default.fileExists(atPath: resolved.path) else {
            return ToolExecutionResult(output: "File not found: \(path)", isError: true, changedPaths: [])
        }

        guard let validator = codeValidator else {
            return ToolExecutionResult(
                output: "Code validator is not available in this context.",
                isError: true,
                changedPaths: []
            )
        }

        let normalizedPath = normalizeRelativePath(path)
        let result: CodeValidator.ValidationResult
        if let serverBase = validationServerBaseURL {
            result = await validator.validate(
                relativePath: normalizedPath,
                serverBaseURL: serverBase,
                bridge: validationBridge
            )
        } else {
            result = await validator.validate(
                entryFileURL: resolved,
                allowingReadAccessTo: workspaceURL
            )
        }

        let totalErrorCount = result.errors.count + result.resourceErrors.count
        if let onProgress {
            await onProgress(.codeValidated(path: normalizedPath, errorCount: totalErrorCount))
        }

        return ToolExecutionResult(
            output: result.summary,
            isError: false,
            changedPaths: [],
            metadata: .codeValidation(path: normalizedPath, errorCount: totalErrorCount, passed: result.passed)
        )
    }

    // MARK: - Path Helpers (delegates to ProjectPathResolver)

    private func resolveSafePath(_ path: String) -> URL? {
        ProjectPathResolver.resolveSafePath(path, in: workspaceURL)
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

    /// Convert an include glob pattern (e.g. "*.js", "*.{html,css}") into a regex
    /// that matches against file names (not full paths).
    private func buildIncludeRegex(_ pattern: String) -> NSRegularExpression? {
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Expand brace groups: "*.{html,css}" → "*.html|*.css"
        var alternatives: [String] = []
        if let braceOpen = trimmed.range(of: "{"),
           let braceClose = trimmed.range(of: "}", range: braceOpen.upperBound..<trimmed.endIndex) {
            let prefix = String(trimmed[trimmed.startIndex..<braceOpen.lowerBound])
            let suffix = String(trimmed[braceClose.upperBound..<trimmed.endIndex])
            let inner = String(trimmed[braceOpen.upperBound..<braceClose.lowerBound])
            for part in inner.components(separatedBy: ",") {
                alternatives.append(prefix + part.trimmingCharacters(in: .whitespaces) + suffix)
            }
        } else {
            alternatives = [trimmed]
        }

        // Convert each alternative from glob to regex
        let regexParts = alternatives.map { alt -> String in
            var regex = "^"
            for ch in alt {
                switch ch {
                case "*": regex += ".*"
                case "?": regex += "."
                case ".": regex += "\\."
                case "(", ")", "+", "^", "$", "|", "[", "]":
                    regex += "\\\(ch)"
                default:
                    regex += String(ch)
                }
            }
            regex += "$"
            return regex
        }

        let combined = regexParts.joined(separator: "|")
        return try? NSRegularExpression(pattern: combined, options: [.caseInsensitive])
    }

    // MARK: - Multi-Level Edit Matching

    private enum EditMatchResult {
        case exact(Range<String.Index>)
        case fuzzy(Range<String.Index>, strategy: String)
        case ambiguous
        case notFound(hint: String?)
    }

    /// Attempt to match `oldText` in `content` using a series of increasingly
    /// tolerant strategies. Returns a categorized result.
    private func findEditMatch(oldText: String, in content: String) -> EditMatchResult {
        // Level 0: Exact match
        let exactRanges = content.ranges(of: oldText)
        if exactRanges.count == 1 {
            return .exact(exactRanges[0])
        }
        if exactRanges.count > 1 {
            return .ambiguous
        }

        // Level 1: Line-based indentation-normalized match
        // Handles tab-vs-spaces and different indentation depths
        if let result = lineBasedIndentMatch(oldText: oldText, in: content) {
            switch result.count {
            case 1: return .fuzzy(result[0], strategy: "indentation normalization")
            default: return .ambiguous
            }
        }

        // Level 2: Whitespace-normalized match (collapses all runs of spaces/tabs)
        if let result = whitespaceNormalizedMatch(oldText: oldText, in: content) {
            switch result.count {
            case 1: return .fuzzy(result[0], strategy: "whitespace normalization")
            default: return .ambiguous
            }
        }

        // Level 3: Trimmed-line match (trim each line then compare)
        if let result = trimmedLineMatch(oldText: oldText, in: content) {
            switch result.count {
            case 1: return .fuzzy(result[0], strategy: "line-trimmed matching")
            default: return .ambiguous
            }
        }

        // Level 4: Line-level similarity match
        // Slides a window over content lines, scoring each position by how many
        // trimmed lines match. Accepts ≥80% match if the best position is unique.
        if let result = lineSimilarityMatch(oldText: oldText, in: content) {
            return result
        }

        // All strategies failed — produce a helpful hint
        let hint = findNearestMatchHint(oldText: oldText, in: content)
        return .notFound(hint: hint)
    }

    /// Normalize each line's leading whitespace to a canonical form, then match.
    /// This catches indentation differences (2 spaces vs 4 spaces, tabs vs spaces).
    private func lineBasedIndentMatch(oldText: String, in content: String) -> [Range<String.Index>]? {
        let normalizeIndent: (String) -> String = { text in
            text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
                let stripped = line.drop(while: { $0 == " " || $0 == "\t" })
                // Normalize: every 1+ whitespace chars at start → that many single spaces
                // But collapse tab = 4 spaces equivalent
                let tabExpanded = line.prefix(while: { $0 == " " || $0 == "\t" })
                    .reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
                return String(repeating: " ", count: tabExpanded) + stripped
            }.joined(separator: "\n")
        }

        let normalizedOld = normalizeIndent(oldText)
        let normalizedContent = normalizeIndent(content)

        let ranges = normalizedContent.ranges(of: normalizedOld)
        guard !ranges.isEmpty else { return nil }

        // Map ranges back to original content via line offsets
        return mapNormalizedRanges(ranges, normalizedContent: normalizedContent, originalContent: content)
    }

    /// Collapse all runs of spaces/tabs to single space, then match.
    private func whitespaceNormalizedMatch(oldText: String, in content: String) -> [Range<String.Index>]? {
        let normalizeWS: (String) -> String = { text in
            text.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        }

        let normalizedOld = normalizeWS(oldText)
        let normalizedContent = normalizeWS(content)

        let ranges = normalizedContent.ranges(of: normalizedOld)
        guard !ranges.isEmpty else { return nil }

        return mapNormalizedRanges(ranges, normalizedContent: normalizedContent, originalContent: content)
    }

    /// Trim each line, then match. Most aggressive whitespace strategy.
    private func trimmedLineMatch(oldText: String, in content: String) -> [Range<String.Index>]? {
        let trimLines: (String) -> String = { text in
            text.split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .joined(separator: "\n")
        }

        let normalizedOld = trimLines(oldText)
        let normalizedContent = trimLines(content)

        let ranges = normalizedContent.ranges(of: normalizedOld)
        guard !ranges.isEmpty else { return nil }

        return mapNormalizedRanges(ranges, normalizedContent: normalizedContent, originalContent: content)
    }

    /// Map ranges found in normalized content back to the original content using
    /// line-level mapping. All normalization strategies preserve line count, so we
    /// find which lines the normalized range spans and return the corresponding
    /// whole-line range in the original content.
    private func mapNormalizedRanges(
        _ ranges: [Range<String.Index>],
        normalizedContent: String,
        originalContent: String
    ) -> [Range<String.Index>] {
        let normLines = normalizedContent.split(separator: "\n", omittingEmptySubsequences: false)
        let origLines = originalContent.split(separator: "\n", omittingEmptySubsequences: false)
        guard normLines.count == origLines.count else { return [] }

        // Build character offset → line number map for normalized content
        var normLineStarts: [Int] = []
        var offset = 0
        for line in normLines {
            normLineStarts.append(offset)
            offset += line.count + 1  // +1 for \n
        }

        // Build character offsets for original content lines
        var origLineStarts: [Int] = []
        offset = 0
        for line in origLines {
            origLineStarts.append(offset)
            offset += line.count + 1
        }

        var result: [Range<String.Index>] = []
        for range in ranges {
            let normStartOffset = normalizedContent.distance(from: normalizedContent.startIndex, to: range.lowerBound)
            let normEndOffset = normalizedContent.distance(from: normalizedContent.startIndex, to: range.upperBound)

            // Find which lines the match spans
            let startLine = normLineStarts.lastIndex(where: { $0 <= normStartOffset }) ?? 0
            let endLine = normLineStarts.lastIndex(where: { $0 <= max(normStartOffset, normEndOffset - 1) }) ?? (normLines.count - 1)

            // Map to original: take the full span of these lines in the original
            let origStart = origLineStarts[startLine]
            let origEnd: Int
            if endLine + 1 < origLineStarts.count {
                // End at the end of endLine (not including the trailing \n if the
                // normalized match didn't include it)
                let normMatchIncludesTrailingNewline = normEndOffset > normLineStarts[endLine] + normLines[endLine].count
                if normMatchIncludesTrailingNewline {
                    origEnd = origLineStarts[endLine] + origLines[endLine].count + 1
                } else {
                    origEnd = origLineStarts[endLine] + origLines[endLine].count
                }
            } else {
                origEnd = originalContent.count
            }

            guard origStart < origEnd, origEnd <= originalContent.count else { continue }

            let origStartIndex = originalContent.index(originalContent.startIndex, offsetBy: origStart)
            let origEndIndex = originalContent.index(originalContent.startIndex, offsetBy: min(origEnd, originalContent.count))
            result.append(origStartIndex..<origEndIndex)
        }

        return result
    }

    /// Level 4: Line-level similarity matching.
    /// Slides a window of `oldLines.count` over the content lines, scoring each
    /// position by how many trimmed lines match exactly. Returns a fuzzy match
    /// if the best score is ≥80% and uniquely the highest.
    private func lineSimilarityMatch(oldText: String, in content: String) -> EditMatchResult? {
        let oldLines = oldText.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard oldLines.count >= 3 else { return nil } // too few lines for meaningful similarity

        let contentLines = content.split(separator: "\n", omittingEmptySubsequences: false)
        guard contentLines.count >= oldLines.count else { return nil }

        let threshold = Int(ceil(Double(oldLines.count) * 0.8))
        var bestScore = 0
        var bestPositions: [Int] = []

        let windowSize = oldLines.count
        for start in 0 ... (contentLines.count - windowSize) {
            var score = 0
            for j in 0..<windowSize {
                if contentLines[start + j].trimmingCharacters(in: .whitespaces) == oldLines[j] {
                    score += 1
                }
            }
            if score > bestScore {
                bestScore = score
                bestPositions = [start]
            } else if score == bestScore && score >= threshold {
                bestPositions.append(start)
            }
        }

        guard bestScore >= threshold, bestPositions.count == 1 else { return nil }

        let matchStart = bestPositions[0]
        let matchEnd = matchStart + windowSize

        // Build the range in the original content covering these lines
        let origLines = content.split(separator: "\n", omittingEmptySubsequences: false)
        var charOffset = 0
        var startOffset = 0
        var endOffset = content.count
        for (i, line) in origLines.enumerated() {
            if i == matchStart { startOffset = charOffset }
            charOffset += line.count + 1 // +1 for \n
            if i == matchEnd - 1 {
                // Don't include trailing \n if it would go past content
                endOffset = min(charOffset, content.count)
                break
            }
        }

        guard startOffset < endOffset, endOffset <= content.count else { return nil }

        let startIndex = content.index(content.startIndex, offsetBy: startOffset)
        let endIndex = content.index(content.startIndex, offsetBy: endOffset)
        let percent = bestScore * 100 / oldLines.count

        return .fuzzy(startIndex..<endIndex, strategy: "line similarity matching (\(percent)% match)")
    }

    /// When all matching strategies fail, find the most similar region in the content
    /// and return a hint string like "Most similar text found at line 42".
    private func findNearestMatchHint(oldText: String, in content: String) -> String? {
        let oldLines = oldText.split(separator: "\n", omittingEmptySubsequences: false)
        guard let firstLine = oldLines.first else { return nil }

        let trimmedFirst = firstLine.trimmingCharacters(in: .whitespaces)
        guard trimmedFirst.count >= 5 else { return nil }  // too short to search meaningfully

        let contentLines = content.components(separatedBy: .newlines)

        // Search for the first line of oldText in the content (trimmed comparison)
        var bestLine: Int?
        var bestScore = 0

        for (lineNum, contentLine) in contentLines.enumerated() {
            let trimmedContent = contentLine.trimmingCharacters(in: .whitespaces)
            if trimmedContent == trimmedFirst {
                // Exact line match — check how many subsequent lines also match
                var matchCount = 1
                for j in 1..<oldLines.count {
                    let oldTrimmed = oldLines[j].trimmingCharacters(in: .whitespaces)
                    let contentIdx = lineNum + j
                    guard contentIdx < contentLines.count else { break }
                    let contentTrimmed = contentLines[contentIdx].trimmingCharacters(in: .whitespaces)
                    if oldTrimmed == contentTrimmed {
                        matchCount += 1
                    } else {
                        break
                    }
                }
                if matchCount > bestScore {
                    bestScore = matchCount
                    bestLine = lineNum + 1  // 1-based
                }
            } else if trimmedContent.contains(trimmedFirst) || trimmedFirst.contains(trimmedContent) {
                // Partial match
                if bestScore == 0 {
                    bestLine = lineNum + 1
                }
            }
        }

        guard let line = bestLine else { return nil }

        if bestScore > 0 && bestScore < oldLines.count {
            let mismatchLine = line + bestScore
            let mismatchLineContent = mismatchLine <= contentLines.count
                ? contentLines[mismatchLine - 1].trimmingCharacters(in: .whitespaces) : "?"
            let preview = mismatchLineContent.count > 60
                ? String(mismatchLineContent.prefix(60)) + "..." : mismatchLineContent
            return "First \(bestScore)/\(oldLines.count) lines match starting at line \(line). Mismatch at line \(mismatchLine): \"\(preview)\""
        }

        return "Most similar text found near line \(line). Please use read_file to check the current content."
    }

    private func formattedByteCount(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1_048_576 { return "\(bytes / 1024) KB" }
        return String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }
}

// MARK: - String Ranges Extension

private extension String {
    /// Find all non-overlapping ranges of `substring` in this string.
    func ranges(of substring: String) -> [Range<String.Index>] {
        var result: [Range<String.Index>] = []
        var searchStart = startIndex
        while searchStart < endIndex,
              let range = self.range(of: substring, range: searchStart..<endIndex) {
            result.append(range)
            searchStart = range.upperBound
        }
        return result
    }
}
