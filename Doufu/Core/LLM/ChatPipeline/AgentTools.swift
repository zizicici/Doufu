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

    /// Optional directory for web_fetch temp files. Mapped via `__web_fetch__/` virtual prefix.
    var webFetchTmpURL: URL?

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
             "diff_file", "changed_files", "doufu_api_docs":
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
            doufuAPIDocsTool(),
        ]
    }

    private func readFileTool() -> AgentToolDefinition {
        AgentToolDefinition(
            name: "read_file",
            description: "Read file contents. Use start_line/line_count to read specific sections of large files.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object([
                        "type": .string("string"),
                        "description": .string("File path relative to project root, e.g. index.html or src/main.js")
                    ]),
                    "start_line": .object([
                        "type": .string("integer"),
                        "description": .string("1-based line number to start reading from")
                    ]),
                    "line_count": .object([
                        "type": .string("integer"),
                        "description": .string("Number of lines to read from start_line")
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
            description: "Create a new file or completely overwrite an existing file. Prefer edit_file for partial changes.",
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
            description: "Apply search-and-replace edits to a file. Edits run sequentially. Whitespace is auto-normalized. Read the file first.",
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
            description: "Delete a file from the project.",
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
            description: "Move or rename a file within the project.",
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
            description: "Revert a file to its checkpoint state. Use when edits caused problems.",
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
            description: "Show a unified diff of a file compared to its checkpoint state.",
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
            description: "List all files modified since the last checkpoint.",
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
            description: "List files and directories at a path. Returns names, sizes, and types.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object([
                        "type": .string("string"),
                        "description": .string("Directory path relative to the working directory. Use '.' for the project root. All project files (index.html, style.css, etc.) are directly in the root.")
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
            description: "Search for text across project files. Returns matching lines. Set files_only=true to return only file paths.",
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
                        "description": .string("Optional glob pattern to filter by file name, e.g. '*.js', '*.{html,css}'")
                    ]),
                    "files_only": .object([
                        "type": .string("boolean"),
                        "description": .string("If true, return only matching file paths without line content")
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
            description: "Search for a regex pattern across project files. Set files_only=true to return only file paths.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "pattern": .object([
                        "type": .string("string"),
                        "description": .string("Regular expression pattern to search for (ICU regex syntax)")
                    ]),
                    "path": .object([
                        "type": .string("string"),
                        "description": .string("Optional directory to limit the search to, relative to project root")
                    ]),
                    "include": .object([
                        "type": .string("string"),
                        "description": .string("Optional glob pattern to filter by file name, e.g. '*.js', '*.{html,css}'")
                    ]),
                    "case_sensitive": .object([
                        "type": .string("boolean"),
                        "description": .string("Whether the search is case-sensitive. Defaults to false.")
                    ]),
                    "files_only": .object([
                        "type": .string("boolean"),
                        "description": .string("If true, return only matching file paths without line content")
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
            description: "Find files matching a glob pattern. Returns file paths.",
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
            description: "Search the web. Returns results with titles, URLs, and descriptions.",
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
            description: "Fetch a web page's content. Small pages are returned inline; large pages are saved to __web_fetch__/ and must be read with read_file/grep_files/search_files. Set raw=true for original HTML.",
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
            description: "Validate HTML/JS by loading in a hidden browser. Catches syntax and runtime errors.",
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

    private func doufuAPIDocsTool() -> AgentToolDefinition {
        AgentToolDefinition(
            name: "doufu_api_docs",
            description: "Returns usage documentation for a specific doufu.* native JavaScript API. Standard browser APIs (getUserMedia, geolocation, clipboard) are blocked in Doufu — use this tool to learn the correct doufu.* alternative. Also covers doufu.db for direct SQL storage.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "capability": .object([
                        "type": .string("string"),
                        "description": .string("The capability to look up."),
                        "enum": .array([
                            .string("location"),
                            .string("clipboard"),
                            .string("camera"),
                            .string("microphone"),
                            .string("photos"),
                            .string("db")
                        ])
                    ])
                ]),
                "required": .array([.string("capability")]),
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
            if let onProgress { onProgress(.readingFile(path: path)) }
            return executeReadFile(args: args)
        case "write_file":
            let path = (args["path"] as? String) ?? "?"
            let isNew = !FileManager.default.fileExists(
                atPath: resolveSafePath(path)?.path ?? ""
            )
            if let onProgress { onProgress(.writingFile(path: path, isNew: isNew)) }
            return await executeWriteFile(args: args)
        case "edit_file":
            let path = (args["path"] as? String) ?? "?"
            let editCount = (args["edits"] as? [Any])?.count ?? 0
            if let onProgress { onProgress(.editingFile(path: path, editCount: editCount)) }
            return await executeEditFile(args: args)
        case "delete_file":
            let path = (args["path"] as? String) ?? "?"
            if let onProgress { onProgress(.deletingFile(path: path)) }
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
            if let onProgress { onProgress(.listingDirectory(path: path)) }
            return executeListDirectory(args: args)
        case "search_files":
            let query = (args["query"] as? String) ?? "?"
            if let onProgress { onProgress(.searching(description: String(format: String(localized: "tool.progress.search_files"), query))) }
            return executeSearchFiles(args: args)
        case "grep_files":
            let pattern = (args["pattern"] as? String) ?? "?"
            if let onProgress { onProgress(.searching(description: String(format: String(localized: "tool.progress.grep_files"), pattern))) }
            return executeGrepFiles(args: args)
        case "glob_files":
            let pattern = (args["pattern"] as? String) ?? "?"
            if let onProgress { onProgress(.searching(description: String(format: String(localized: "tool.progress.glob_files"), pattern))) }
            return executeGlobFiles(args: args)
        case "web_search":
            let query = (args["query"] as? String) ?? "?"
            if let onProgress { onProgress(.webActivity(description: String(format: String(localized: "tool.progress.web_search"), query))) }
            return await executeWebSearch(args: args)
        case "web_fetch":
            let url = (args["url"] as? String) ?? "?"
            if let onProgress { onProgress(.webActivity(description: String(format: String(localized: "tool.progress.web_fetch"), url))) }
            return await executeWebFetch(args: args)
        case "validate_code":
            let path = (args["path"] as? String) ?? "?"
            if let onProgress { onProgress(.validatingCode(path: path)) }
            return await executeValidateCode(args: args, onProgress: onProgress)
        case "doufu_api_docs":
            return executeDoufuAPIDocs(args: args)
        default:
            return ToolExecutionResult(
                output: "Unknown tool: \(toolCall.name)",
                isError: true,
                changedPaths: []
            )
        }
    }

    // MARK: - Read File

    /// Upper bound for decoding a file into String.  Files larger than this
    /// are read in a byte-windowed mode so that `start_line` can still seek
    /// into them without loading everything into memory.
    private static let maxFullDecodeBytes = 5_000_000

    private func executeReadFile(args: [String: Any]) -> ToolExecutionResult {
        guard let path = args["path"] as? String else {
            return ToolExecutionResult(output: "Missing required parameter: path", isError: true, changedPaths: [])
        }

        guard let resolved = resolveReadablePath(path) else {
            return ToolExecutionResult(output: "Invalid path: \(path)", isError: true, changedPaths: [])
        }

        guard FileManager.default.fileExists(atPath: resolved.path) else {
            return ToolExecutionResult(output: "File not found: \(path)", isError: true, changedPaths: [])
        }

        guard let data = try? Data(contentsOf: resolved), !data.isEmpty else {
            return ToolExecutionResult(output: "Could not read file: \(path)", isError: true, changedPaths: [])
        }

        let totalBytes = data.count

        // Decode the full file (up to safety cap) so that start_line/line_count
        // can reach ANY position — the byte budget is applied to the OUTPUT, not the read.
        let decodableData = totalBytes > Self.maxFullDecodeBytes ? data.prefix(Self.maxFullDecodeBytes) : data[...]
        guard let fullContent = String(data: decodableData, encoding: .utf8) else {
            return ToolExecutionResult(output: "File is not valid UTF-8 text: \(path)", isError: true, changedPaths: [])
        }

        // Normalize line endings to "\n" for consistent splitting.
        let normalizedContent = fullContent.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        // If the entire file is a single long line (minified), reformat it
        // and save the formatted version back to disk so that subsequent
        // edit_file calls see the same content the model sees.
        let ext = URL(fileURLWithPath: path).pathExtension
        let rawLines = normalizedContent.components(separatedBy: "\n")
        let isSingleLineMinified = rawLines.count <= 2
            && normalizedContent.count > Self.longLineThreshold
            && Self.formattableExtensions.contains(ext.lowercased())

        let readableContent: String
        let wasReformatted: Bool
        if isSingleLineMinified {
            let (formatted, didFormat) = breakLongLines(in: normalizedContent, fileExtension: ext)
            readableContent = formatted
            wasReformatted = didFormat
            if didFormat {
                try? formatted.write(to: resolved, atomically: true, encoding: .utf8)
            }
        } else {
            readableContent = normalizedContent
            wasReformatted = false
        }

        let allLines = readableContent.components(separatedBy: "\n")
        let totalLineCount: Int
        if totalBytes > Self.maxFullDecodeBytes {
            // Estimate remaining lines beyond the decoded portion
            let decodedBytes = decodableData.count
            let avgBytesPerLine = max(1, decodedBytes / max(1, allLines.count))
            totalLineCount = allLines.count + (totalBytes - decodedBytes) / avgBytesPerLine
        } else {
            totalLineCount = allLines.count
        }

        // Apply start_line / line_count range selection on the FULL line array
        let startLine = (args["start_line"] as? Int) ?? 1
        let requestedCount = args["line_count"] as? Int
        let clampedStart = max(1, startLine)
        let startIndex = clampedStart - 1 // 0-based

        let selectedLines: ArraySlice<String>
        let isRangeSelected: Bool
        if startIndex < allLines.count {
            if let count = requestedCount {
                let endIndex = min(startIndex + count, allLines.count)
                selectedLines = allLines[startIndex..<endIndex]
                isRangeSelected = true
            } else if startIndex > 0 {
                selectedLines = allLines[startIndex...]
                isRangeSelected = true
            } else {
                selectedLines = allLines[...]
                isRangeSelected = false
            }
        } else {
            selectedLines = []
            isRangeSelected = true
        }

        // Truncate overly long lines (e.g. minified JS/CSS)
        let maxCharsPerLine = configuration.maxCharsPerLineInReadFile
        let processedLines = selectedLines.map { line -> String in
            if line.count > maxCharsPerLine {
                return String(line.prefix(maxCharsPerLine)) + " [truncated, \(line.count) chars total]"
            }
            return line
        }

        // Apply byte budget on the OUTPUT — this keeps the LLM context bounded
        // while allowing start_line to reach any part of the file.
        let maxOutputBytes = configuration.maxBytesPerContextFile
        var outputLines: [String] = []
        var currentBytes = 0
        var isOutputTruncated = false
        for line in processedLines {
            let lineBytes = line.utf8.count + 1 // +1 for newline separator
            if currentBytes + lineBytes > maxOutputBytes && !outputLines.isEmpty {
                isOutputTruncated = true
                break
            }
            outputLines.append(line)
            currentBytes += lineBytes
        }

        let content = outputLines.joined(separator: "\n")
        let displayedStartLine = clampedStart
        let displayedEndLine = startIndex + outputLines.count

        // Metadata header — always present so the model knows the file's true dimensions
        var headerParts: [String] = [
            "\(totalLineCount) lines",
            "\(totalBytes) bytes",
        ]
        if isRangeSelected || isOutputTruncated {
            headerParts.append("showing lines \(displayedStartLine)-\(displayedEndLine)")
        }
        if isOutputTruncated {
            headerParts.append("output truncated")
        }
        if wasReformatted {
            headerParts.append("auto-formatted from single-line minified")
        }
        let header = "[File: \(path) | \(headerParts.joined(separator: " | "))]"

        let output = header + "\n" + content

        let previewLines = outputLines.prefix(5)
        let preview = previewLines.joined(separator: "\n")
        let reportedLineCount = outputLines.count

        return ToolExecutionResult(
            output: output,
            isError: false,
            changedPaths: [],
            metadata: .fileRead(path: normalizeRelativePath(path), lineCount: reportedLineCount, sizeBytes: Int64(totalBytes)),
            completionEvent: .fileRead(path: path, lineCount: reportedLineCount, preview: preview)
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

        // Validate path stays within workspace or readable sandbox
        guard resolveReadablePath(path) != nil else {
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
        let filesOnly = args["files_only"] as? Bool ?? false
        guard let searchRoot = resolveReadableDirectory(searchPath) else {
            return ToolExecutionResult(output: "Invalid path: \(searchPath ?? "")", isError: true, changedPaths: [])
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
        var matchedFiles: [String] = []
        var filesSearched = 0
        let maxMatchedFiles = 50
        let maxFilesToSearch = 500

        for case let fileURL as URL in enumerator {
            guard filesSearched < maxFilesToSearch else { break }
            guard matchedFiles.count < maxMatchedFiles else { break }

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
            var fileHasMatch = false

            if filesOnly {
                // Only check if any line matches — no need to collect line details
                for line in lines {
                    if line.lowercased().contains(loweredQuery) {
                        fileHasMatch = true
                        break
                    }
                }
                if fileHasMatch {
                    matchedFiles.append(relativePath)
                    results.append(relativePath)
                }
            } else {
                var fileMatches: [(lineNumber: Int, text: String)] = []
                for (index, line) in lines.enumerated() {
                    guard fileMatches.count < 5 else { break }
                    if let matchRange = line.lowercased().range(of: loweredQuery) {
                        let nsRange = NSRange(matchRange, in: line.lowercased())
                        let preview = matchContextPreview(in: line, matchRange: nsRange)
                        fileMatches.append((lineNumber: index + 1, text: preview))
                    }
                }
                if !fileMatches.isEmpty {
                    matchedFiles.append(relativePath)
                    results.append(relativePath)
                    for match in fileMatches {
                        results.append("  L\(match.lineNumber): \(match.text)")
                    }
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

        let matchingFileCount = matchedFiles.count
        let header = filesOnly
            ? "Found \(matchingFileCount) file(s) matching \"\(query)\":\n"
            : "Search results for \"\(query)\":\n"
        return ToolExecutionResult(
            output: header + results.joined(separator: "\n"),
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
        let filesOnly = args["files_only"] as? Bool ?? false
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
        guard let searchRoot = resolveReadableDirectory(searchPath) else {
            return ToolExecutionResult(output: "Invalid path: \(searchPath ?? "")", isError: true, changedPaths: [])
        }

        guard let enumerator = FileManager.default.enumerator(
            at: searchRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return ToolExecutionResult(output: "Could not search directory", isError: true, changedPaths: [])
        }

        var results: [String] = []
        var matchedFiles: [String] = []
        var filesSearched = 0
        let maxMatchedFiles = 80
        let maxFilesToSearch = 500
        let maxMatchesPerFile = 8

        for case let fileURL as URL in enumerator {
            guard filesSearched < maxFilesToSearch else { break }
            guard matchedFiles.count < maxMatchedFiles else { break }

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

            if filesOnly {
                var fileHasMatch = false
                for line in lines {
                    let range = NSRange(line.startIndex..., in: line)
                    if regex.firstMatch(in: line, range: range) != nil {
                        fileHasMatch = true
                        break
                    }
                }
                if fileHasMatch {
                    matchedFiles.append(relativePath)
                    results.append(relativePath)
                }
            } else {
                var fileMatches: [(lineNumber: Int, text: String)] = []
                for (index, line) in lines.enumerated() {
                    guard fileMatches.count < maxMatchesPerFile else { break }
                    let lineRange = NSRange(line.startIndex..., in: line)
                    if let match = regex.firstMatch(in: line, range: lineRange) {
                        let preview = matchContextPreview(in: line, matchRange: match.range)
                        fileMatches.append((lineNumber: index + 1, text: preview))
                    }
                }
                if !fileMatches.isEmpty {
                    matchedFiles.append(relativePath)
                    results.append(relativePath)
                    for match in fileMatches {
                        results.append("  L\(match.lineNumber): \(match.text)")
                    }
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

        let matchingFileCount = matchedFiles.count
        let header = filesOnly
            ? "Found \(matchingFileCount) file(s) matching /\(pattern)/:\n"
            : "Grep results for /\(pattern)/:\n"
        return ToolExecutionResult(
            output: header + results.joined(separator: "\n"),
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
        guard let searchRoot = resolveReadableDirectory(searchPath) else {
            return ToolExecutionResult(output: "Invalid path: \(searchPath ?? "")", isError: true, changedPaths: [])
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

        let result = await webToolProvider.webSearch(query: query, searxngBaseURL: AppProjectStore.shared.searxngBaseURL)
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
        let result = await webToolProvider.webFetch(urlString: urlString, raw: raw, tmpDirectoryURL: webFetchTmpURL)
        switch result {
        case let .success(fetchResult):
            if let savedPath = fetchResult.savedPath {
                let sizeDesc = fetchResult.fileSize.map { formattedByteCount($0) } ?? "unknown size"
                return ToolExecutionResult(
                    output: "Fetched \(urlString) (\(fetchResult.statusCode), \(sizeDesc)). Saved to \(savedPath).\nUse read_file, grep_files, or search_files to explore the content.",
                    isError: false,
                    changedPaths: [],
                    metadata: .webResult(url: urlString, statusCode: fetchResult.statusCode)
                )
            }
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

        guard let serverBase = validationServerBaseURL else {
            return ToolExecutionResult(
                output: "Code validation requires the local project server, but it is unavailable.",
                isError: true,
                changedPaths: []
            )
        }

        let normalizedPath = normalizeRelativePath(path)
        var result = await validator.validate(
            relativePath: normalizedPath,
            serverBaseURL: serverBase,
            bridge: validationBridge
        )
        // Retry once on navigation failure — the local server may be
        // restarting after a transient NWListener state change.
        if !result.errors.isEmpty,
           result.errors.allSatisfy({ $0.source == "navigation" }),
           result.consoleOutput.isEmpty {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            result = await validator.validate(
                relativePath: normalizedPath,
                serverBaseURL: serverBase,
                bridge: validationBridge
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

    // MARK: - Doufu API Docs

    private static let doufuAPIDocs: [String: String] = [
        "location": """
            ## doufu.location

            ```js
            // Get current position (one-shot)
            const pos = await doufu.location.get();
            // pos = {
            //   coords: { latitude, longitude, accuracy, altitude, altitudeAccuracy, heading, speed },
            //   timestamp: 1710000000000
            // }

            // Watch position (continuous updates)
            const watchId = await doufu.location.watch((pos) => {
              console.log(pos.coords.latitude, pos.coords.longitude);
            });

            // Stop watching
            await doufu.location.clearWatch(watchId);
            ```

            Return format matches the Web Geolocation API structure. Requires system location permission.
            Do NOT use navigator.geolocation — it is blocked.
            """,
        "clipboard": """
            ## doufu.clipboard

            ```js
            // Read clipboard text
            const text = await doufu.clipboard.read();   // → string

            // Write text to clipboard
            await doufu.clipboard.write("hello");        // → void (resolves on success)
            ```

            No system permission needed — project-level only.
            Do NOT use navigator.clipboard or document.execCommand('copy'/'paste') — they are blocked.
            """,
        "camera": """
            ## doufu.camera

            ```js
            // Start camera (returns a MediaStream with one video track)
            const stream = await doufu.camera.start({facing: 'user'});
            // facing: 'user' (front camera, default) or 'environment' (back camera)
            // Optional: {facing: 'user', width: 1920, height: 1440, fps: 30}
            // Default is 4:3 (1920×1440) to match native sensor. Use 1920×1080 for 16:9.

            // IMPORTANT: <video> element MUST have the `playsinline` attribute.
            // Without it, iOS will not display the camera feed inline.
            // Example: <video id="cam" playsinline autoplay muted></video>
            const video = document.querySelector('video');
            video.srcObject = stream;
            video.play();

            // Record video using MediaRecorder
            const recorder = new MediaRecorder(stream, { mimeType: 'video/mp4' });
            const chunks = [];
            recorder.ondataavailable = e => { if (e.data.size > 0) chunks.push(e.data); };
            recorder.start(200);
            // ... later:
            recorder.stop();
            recorder.onstop = () => {
              const blob = new Blob(chunks, { type: recorder.mimeType });
              // To save to photo library: convert to data URL and call doufu.photos.saveVideo()
            };

            // Record video WITH audio: combine both streams
            const micStream = await doufu.mic.start();
            const combined = new MediaStream([
              ...stream.getVideoTracks(),
              ...micStream.getAudioTracks()
            ]);
            const avRecorder = new MediaRecorder(combined, { mimeType: 'video/mp4' });

            // Capture a still frame to canvas
            const canvas = document.createElement('canvas');
            canvas.width = video.videoWidth;
            canvas.height = video.videoHeight;
            canvas.getContext('2d').drawImage(video, 0, 0);
            const dataUrl = canvas.toDataURL('image/jpeg', 0.9);
            // Save to photo library: await doufu.photos.savePhoto(dataUrl);

            // Switch camera (restarts with new facing direction)
            const newStream = await doufu.camera.start({facing: 'environment'});
            video.srcObject = newStream;

            // Tap-to-focus at normalized coordinates (0–1, origin top-left)
            await doufu.camera.focus({x: 0.5, y: 0.5});

            // Adjust exposure compensation in EV units (-3.0 to +3.0)
            await doufu.camera.exposure({bias: 1.0});   // brighter
            await doufu.camera.exposure({bias: -1.0});  // darker
            await doufu.camera.exposure({bias: 0});     // reset

            // Flashlight / torch (continuous fill light): 'on' or 'off'
            await doufu.camera.torch({mode: 'on'});

            // Zoom (1.0 = no zoom, clamped to device max)
            await doufu.camera.zoom({factor: 2.0});

            // Mirror hint: front camera streams have stream.__doufuMirrored = true
            // (back camera = false). Use CSS to apply: video.style.transform = stream.__doufuMirrored ? 'scaleX(-1)' : '';
            // To change: await doufu.camera.mirror({enabled: false});
            // This updates stream.__doufuMirrored on the active stream.
            await doufu.camera.mirror({enabled: true});

            // Stop camera
            await doufu.camera.stop();
            ```

            Returns a MediaStream with one video track. Requires system camera permission.
            The returned stream has a `__doufuMirrored` property (boolean) indicating whether
            the video should be displayed mirrored. Front camera defaults to `true`, back to `false`.
            Apply mirroring in CSS: `video.style.transform = stream.__doufuMirrored ? 'scaleX(-1)' : ''`.
            Do NOT use getUserMedia or any browser media API — they are blocked.
            If microphone is also needed, start both independently — see the combined recording example above.
            To save a captured frame to the photo library, use `doufu.photos.savePhoto()`.

            **IMPORTANT — WebRTC remote track:**
            The stream is delivered via WebRTC loopback. Display via `video.srcObject` and
            recording via `MediaRecorder` both work correctly. However, do NOT feed it into
            `AudioContext.createMediaStreamSource()` — it will produce silence (see microphone docs).
            For frame processing, draw the `<video>` element onto a `<canvas>` instead.
            """,
        "microphone": """
            ## doufu.mic

            ```js
            // Start microphone (returns a MediaStream)
            const stream = await doufu.mic.start();

            // Record audio using MediaRecorder (recommended)
            const recorder = new MediaRecorder(stream, {
              mimeType: MediaRecorder.isTypeSupported('audio/webm;codecs=opus')
                ? 'audio/webm;codecs=opus' : 'audio/mp4'
            });
            const chunks = [];
            recorder.ondataavailable = e => { if (e.data.size > 0) chunks.push(e.data); };
            recorder.start(200); // collect chunks every 200ms

            // Stop recording → get audio Blob
            recorder.stop();
            recorder.onstop = () => {
              const blob = new Blob(chunks, { type: recorder.mimeType });
              const url = URL.createObjectURL(blob);
              // use url for playback, download, etc.
            };

            // Stop microphone (call when done)
            await doufu.mic.stop();
            ```

            Returns a MediaStream with one audio track. Requires system microphone permission.
            Do NOT use getUserMedia or any browser media API — they are blocked.

            **IMPORTANT — Web Audio API limitation:**
            The returned stream is delivered via WebRTC loopback (remote track).
            `AudioContext.createMediaStreamSource(stream)` will produce **silence** —
            `ScriptProcessorNode` / `AudioWorklet` will receive all-zero buffers.
            Do NOT use createMediaStreamSource for recording, audio processing, or visualizers.
            Always use `MediaRecorder` to capture audio from this stream.
            For audio visualization, use `MediaRecorder` + `decodeAudioData` on recorded chunks,
            or implement a simple amplitude display based on recording duration/state (no real-time waveform).
            """,
        "photos": """
            ## doufu.photos

            ```js
            // Pick a single photo from the system photo picker (no permission needed)
            const url = await doufu.photos.pick();
            // Returns a temporary same-origin URL path string, e.g.
            // "/__doufu_tmp__/photos/xxx.jpg"
            // Returns null if user cancels
            if (url) img.src = url;

            // Pick multiple photos (up to limit)
            const photos = await doufu.photos.pick({multiple: true, limit: 5});
            // Returns an array of URL path strings (empty array if cancelled)
            photos.forEach(u => { /* ... */ });

            // Save an image to the iOS photo library
            // Requires "Save Photos" permission (add-only, cannot read library)
            await doufu.photos.savePhoto(canvas.toDataURL('image/jpeg', 0.9));

            // Save a video to the iOS photo library
            // Pass a data URL from a recorded Blob (e.g. from MediaRecorder)
            const blob = new Blob(chunks, { type: 'video/mp4' });
            const reader = new FileReader();
            reader.onload = () => doufu.photos.saveVideo(reader.result);
            reader.readAsDataURL(blob);
            ```

            `pick()` uses the system photo picker (PHPicker) — completely private,
            no photo library permission required. The user selects which photos to share.
            Returns a URL path string (single) or array of URL path strings (multiple).
            Large images are automatically downscaled (max 2048px).
            Picked photo URLs are temporary and cleared on page navigation.

            `savePhoto()` writes an image to the photo library. Requires system "Add Photos Only"
            permission. Pass a data URL (e.g. from canvas.toDataURL() or a picked photo).

            `saveVideo()` writes a video to the photo library. Same permission as savePhoto.
            Pass a data URL of the video (e.g. from FileReader.readAsDataURL on a recorded Blob).
            Best for short recordings — large videos may cause memory pressure during base64 encoding.
            """,
        "db": """
            ## doufu.db — Direct SQL Storage

            A simple key-value or relational store backed by SQLite (sql.js WASM).
            Each named database is persisted as `AppData/{name}.sqlite` — survives cache clears and app reinstalls.
            No permissions needed.

            ```js
            // Open (or create) a named database — returns a handle ID
            const db = await doufu.db.open('mydata');

            // Create a table
            await doufu.db.run(db, 'CREATE TABLE IF NOT EXISTS items (id INTEGER PRIMARY KEY, name TEXT, value REAL)');

            // Insert / update (use ? placeholders for parameters)
            await doufu.db.run(db, 'INSERT INTO items (name, value) VALUES (?, ?)', ['score', 42]);
            await doufu.db.run(db, 'UPDATE items SET value = ? WHERE name = ?', [100, 'score']);

            // Query — returns array of result sets, each with columns[] and values[][]
            const results = await doufu.db.exec(db, 'SELECT * FROM items WHERE value > ?', [10]);
            // results = [{ columns: ['id','name','value'], values: [[1,'score',100]] }]
            // Empty result → []

            if (results.length > 0) {
              for (const row of results[0].values) {
                console.log(row); // [1, 'score', 100]
              }
            }

            // Close (flushes to disk immediately)
            await doufu.db.close(db);
            ```

            **exec vs run**:
            - `exec(handle, sql, params?)` — for SELECT queries. Returns result rows. Does NOT trigger persist.
            - `run(handle, sql, params?)` — for INSERT/UPDATE/DELETE/CREATE. Triggers debounced persist (500ms).

            **Database names**: must match `[a-zA-Z0-9_-]` only.

            **When to use doufu.db vs indexedDB**:
            - Use `doufu.db` when you need relational queries (JOINs, aggregations, complex WHERE).
            - Use `indexedDB` when the code already uses it (e.g. libraries like Dexie.js).
            - Both persist to disk and survive cache clears.
            """,
    ]

    private func executeDoufuAPIDocs(args: [String: Any]) -> ToolExecutionResult {
        guard let capability = args["capability"] as? String else {
            return ToolExecutionResult(
                output: "Missing required parameter: capability (location, clipboard, camera, microphone, or photos)",
                isError: true,
                changedPaths: []
            )
        }

        guard let doc = Self.doufuAPIDocs[capability] else {
            return ToolExecutionResult(
                output: "Unknown capability: \(capability). Valid values: location, clipboard, camera, microphone, photos, db.",
                isError: true,
                changedPaths: []
            )
        }

        let preamble = """
            Standard browser APIs for this capability are permanently blocked in Doufu. Use the doufu.* API instead.
            Permission: First call triggers a per-project user permission prompt. If denied, the Promise rejects with NotAllowedError. Permission is changeable in project settings.
            """

        return ToolExecutionResult(
            output: preamble + "\n" + doc,
            isError: false,
            changedPaths: []
        )
    }

    // MARK: - Path Helpers (delegates to ProjectPathResolver)

    private static let webFetchPrefix = "__web_fetch__/"

    /// Resolves a path for **read** operations. Supports the `__web_fetch__/` virtual
    /// prefix (maps to `webFetchTmpURL`) in addition to the normal workspace sandbox.
    private func resolveReadablePath(_ path: String) -> URL? {
        if path.hasPrefix(Self.webFetchPrefix), let tmpURL = webFetchTmpURL {
            let subpath = String(path.dropFirst(Self.webFetchPrefix.count))
            guard !subpath.isEmpty,
                  !subpath.contains(".."),
                  !subpath.contains("/") else { return nil }
            let resolved = tmpURL.appendingPathComponent(subpath).standardizedFileURL
            // Ensure the resolved path stays within tmpURL
            guard resolved.path.hasPrefix(tmpURL.standardizedFileURL.path) else { return nil }
            return resolved
        }
        return ProjectPathResolver.resolveSafePath(path, in: workspaceURL)
    }

    /// Resolves the search root for read-only enumeration tools (search/grep/glob).
    /// Handles `__web_fetch__/` prefix by returning the tmp directory as root.
    private func resolveReadableDirectory(_ path: String?) -> URL? {
        guard let path, !path.isEmpty, path != "." else { return workspaceURL }
        if path == "__web_fetch__" || path == "__web_fetch__/" {
            return webFetchTmpURL
        }
        if path.hasPrefix(Self.webFetchPrefix), let tmpURL = webFetchTmpURL {
            let subpath = String(path.dropFirst(Self.webFetchPrefix.count))
            guard !subpath.contains("..") else { return nil }
            let resolved = tmpURL.appendingPathComponent(subpath).standardizedFileURL
            guard resolved.path.hasPrefix(tmpURL.standardizedFileURL.path) else { return nil }
            return resolved
        }
        return ProjectPathResolver.resolveSafePath(path, in: workspaceURL)
    }

    private func resolveSafePath(_ path: String) -> URL? {
        ProjectPathResolver.resolveSafePath(path, in: workspaceURL)
    }

    /// Removes the web_fetch temp directory if it exists.
    func cleanUpWebFetchTmp() {
        guard let tmpURL = webFetchTmpURL else { return }
        try? FileManager.default.removeItem(at: tmpURL)
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

    // MARK: - Match Preview

    /// Maximum characters in a single match preview line.
    private static let matchPreviewMaxLength = 120

    /// Returns a context window around the match position, with ellipsis
    /// if the line extends beyond the window in either direction.
    private func matchContextPreview(in line: String, matchRange: NSRange) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let maxLen = Self.matchPreviewMaxLength
        guard trimmed.count > maxLen else { return trimmed }

        let nsLine = line as NSString

        // Compute match start/end in character offsets
        let matchStart = matchRange.location
        let matchEnd = matchRange.location + matchRange.length

        // Calculate a window centered on the match
        let matchLen = matchRange.length
        let contextBudget = max(0, maxLen - matchLen)
        let leadContext = contextBudget / 2
        let trailContext = contextBudget - leadContext

        var windowStart = max(0, matchStart - leadContext)
        var windowEnd = min(nsLine.length, matchEnd + trailContext)

        // If the window is still shorter than maxLen, expand in the available direction
        let windowLen = windowEnd - windowStart
        if windowLen < maxLen {
            let deficit = maxLen - windowLen
            if windowStart > 0 {
                windowStart = max(0, windowStart - deficit)
            }
            if windowEnd - windowStart < maxLen {
                windowEnd = min(nsLine.length, windowStart + maxLen)
            }
        }

        let snippet = nsLine.substring(with: NSRange(location: windowStart, length: windowEnd - windowStart))
            .trimmingCharacters(in: .whitespaces)
        let prefix = windowStart > 0 ? "..." : ""
        let suffix = windowEnd < nsLine.length ? "..." : ""
        return prefix + snippet + suffix
    }

    // MARK: - Minified Code Formatter

    /// File extensions eligible for long-line reformatting.
    private static let formattableExtensions: Set<String> = [
        "js", "mjs", "jsx", "ts", "tsx",
        "css", "scss", "less",
        "html", "htm",
        "json",
    ]

    /// Threshold (in characters) above which a line is considered "minified".
    private static let longLineThreshold = 1000

    /// Break very long lines at structural boundaries to prevent single-line
    /// data explosion.  Only operates on lines exceeding `longLineThreshold`
    /// characters and only for known web file types.  String literals
    /// (single/double/template) are respected so content inside them is never
    /// split.
    ///
    /// Returns `(formatted, didFormat)`.
    private func breakLongLines(in content: String, fileExtension ext: String) -> (String, Bool) {
        guard Self.formattableExtensions.contains(ext.lowercased()) else {
            return (content, false)
        }

        // Normalize Windows \r\n and bare \r to \n so that the formatter
        // doesn't leave stray \r characters in the output.
        let normalized = content.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        let hasLongLines = lines.contains { $0.count > Self.longLineThreshold }
        guard hasLongLines else { return (content, false) }

        let breakAfter: Set<Character>
        let breakBefore: Set<Character>

        switch ext.lowercased() {
        case "json":
            breakAfter  = ["{", "[", ","]
            breakBefore = ["}", "]"]
        case "css", "scss", "less":
            breakAfter  = ["{", ";"]
            breakBefore = ["}"]
        default: // js, html, etc.
            breakAfter  = ["{", ";"]
            breakBefore = ["}"]
        }

        let formatted = lines.map { line -> String in
            guard line.count > Self.longLineThreshold else { return line }
            return Self.breakSingleLongLine(line, breakAfter: breakAfter, breakBefore: breakBefore)
        }.joined(separator: "\n")

        return (formatted, true)
    }

    /// Insert newlines at structural boundaries in a single long line.
    /// Respects string literals (', ", `) so content inside them is preserved.
    private static func breakSingleLongLine(
        _ line: String,
        breakAfter: Set<Character>,
        breakBefore: Set<Character>
    ) -> String {
        var result = ""
        result.reserveCapacity(line.count + line.count / 20)
        var stringDelimiter: Character?
        var escaped = false

        for char in line {
            // Escape sequences inside strings
            if escaped {
                result.append(char)
                escaped = false
                continue
            }
            if char == "\\", stringDelimiter != nil {
                escaped = true
                result.append(char)
                continue
            }

            // Track string open/close
            if let delim = stringDelimiter {
                result.append(char)
                if char == delim { stringDelimiter = nil }
                continue
            }
            if char == "'" || char == "\"" || char == "`" {
                stringDelimiter = char
                result.append(char)
                continue
            }

            // Structural break points (outside strings)
            if breakBefore.contains(char) {
                result.append("\n")
                result.append(char)
            } else {
                result.append(char)
            }

            if breakAfter.contains(char) {
                result.append("\n")
            }
        }

        // Clean up: collapse empty lines and trim whitespace per line.
        // Use .whitespacesAndNewlines so that any stray \r is also stripped.
        return result
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
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
