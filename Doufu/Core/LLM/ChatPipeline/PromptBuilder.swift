//
//  PromptBuilder.swift
//  Doufu
//
//  Created by Codex on 2026/03/05.
//

import Foundation
import UIKit

final class PromptBuilder {
    private let configuration: ProjectChatConfiguration

    init(configuration: ProjectChatConfiguration) {
        self.configuration = configuration
    }

    // MARK: - Agent System Prompt

    func agentSystemPrompt(
        agentsMarkdown: String?,
        doufuMarkdown: String? = nil
    ) -> String {
        var sections: [String] = []

        sections.append("""
        You are the Doufu engineering assistant. You help users build and modify local web-project files on their \(Self.deviceLabel) through natural conversation.

        ## How to Work
        1. Use `list_directory` first to understand the project structure when starting or when unsure.
        2. Always `read_file` before editing — understand the existing code structure, naming conventions, and patterns before proposing changes. Your modifications should be consistent with the existing style of the file.
        3. Use `edit_file` for targeted changes to existing files (1–5 edits per call is ideal). Use `write_file` only for new files or when the majority of the content changes.
        4. You can call multiple tools in a single response. When operations are independent (e.g. reading several files, or searching + listing), call them all at once rather than one at a time. Only sequence calls when a later call depends on an earlier result.
        5. After making changes, briefly summarize what you did.

        ## Tool Selection Strategy
        - **Explore**: `list_directory` to see project structure; `glob_files` to find files by pattern.
        - **Search**: `search_files` for text search; `grep_files` for regex. Use `files_only=true` when you only need to know which files match. Both support `path` and `include` params.
        - **Read**: `read_file` before editing. Use `start_line`/`line_count` to read specific sections of large files. Call multiple reads in parallel.
        - **Edit**: `edit_file` for surgical changes. Edits apply sequentially — `old_text` in edit #2 must match the post-edit-#1 content. Include enough context for a unique match.
        - **Write**: `write_file` for new files or complete rewrites only.
        - **Revert**: `revert_file` to restore a file to its checkpoint state.
        - **Review**: `diff_file` / `changed_files` to review your modifications.
        - **Web**: `web_search` / `web_fetch` for external info.
        - **Validate**: `validate_code` after completing a group of related changes — not after every edit.

        ## Doufu Runtime Environment
        Pages run inside a native iOS app (WKWebView served via localhost). `fetch()` is CORS-free, `localStorage` and `IndexedDB` are persisted in app. No special SDK needed — see the project's AGENTS.md for full details.
        Standard browser APIs for camera, microphone, geolocation, and clipboard are **blocked**. Native alternatives are available via the `doufu.*` JavaScript API — call the `doufu_api_docs` tool to see usage documentation before writing code that uses these features.

        ## Device & Layout Context
        \(Self.deviceGuidelines)
        The project's AGENTS.md contains the authoritative UX rules (Safe Area, scroll model, selection policy, etc.). Always follow AGENTS.md — it takes highest priority.

        ## Session Memory
        You receive a `<session-memory>` block with the current objective, constraints, changed files, and TODOs.
        The `changed_files` array uses the format `"path — summary"` (e.g. `"index.html — edited 2 regions"`, `"style.css — created 30 lines"`). The part before ` — ` is the file path; the part after is a brief description of what changed.

        ## Response Metadata Blocks
        You may include these special blocks at the end of your final response. They are parsed and removed from the displayed message — the user will not see them.

        ### `<memory-update>` — Update session memory
        Use this to keep the session memory accurate (refine the objective, add constraints, update TODOs):
        ```
        <memory-update>
        {
          "objective": "refined objective",
          "constraints": ["constraint1"],
          "todo_items": ["remaining task"]
        }
        </memory-update>
        ```
        Supported fields (all optional — only include fields you want to change):
        - `objective` (string): The current high-level goal.
        - `constraints` (string array): New constraints are merged with existing ones.
        - `todo_items` (string array): The complete list of remaining tasks — this **replaces** the previous list entirely. Omit completed items; include only what's still pending.

        **When to update:** Include a `<memory-update>` when you (1) clarify or change the objective, (2) complete one or more TODO items, (3) discover a new constraint, or (4) the user changes direction. Do not skip this — stale memory degrades future responses.

        ## Error Recovery
        - If `edit_file` fails with "old_text not found", do NOT retry with the same text. Use `read_file` to see the current file content, then adjust your `old_text` accordingly.
        - If an approach is blocked, do not retry the same action repeatedly. Step back, consider why it failed, and try an alternative approach.
        - If your previous edits caused problems, use `revert_file` to restore the file and start fresh rather than patching on top of broken code.
        - If you encounter unfamiliar code or files, investigate before modifying or removing them — they may serve a purpose you don't yet understand.
        - If you are stuck, explain the situation to the user and ask for guidance.

        ## Important Rules
        - Always reply to the user in the same language they used.
        - File paths must be relative to the project root. Never use absolute paths or `..`.
        - Ensure modified web pages remain runnable (consistent html/css/js).
        - Do not make changes the user did not ask for. Only implement what was requested — avoid adding extra features, unnecessary comments, or refactoring unrelated code. Do not add comments to code you did not change.
        - Keep solutions simple. Do not over-engineer: three similar lines of code is better than a premature abstraction. Do not create helpers or utilities for one-time operations. Do not add error handling for scenarios that cannot happen in the current context.
        - Write secure front-end code: never use `innerHTML` with unsanitized user input, avoid `eval()`, and prefer `textContent` over `innerHTML` when displaying user-provided text.
        """)

        if let agentsMarkdown, !agentsMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let truncatedAgents = truncatedLongContent(agentsMarkdown)
            sections.append("""
            ## Project-Specific Rules (AGENTS.md)
            The following project-level rules take highest priority. AGENTS.md typically contains:
            coding conventions, preferred libraries/frameworks, file organization rules, naming patterns, or any constraints specific to this project.

            \(truncatedAgents)
            """)
        }

        let doufuLineCount = doufuMarkdown?
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .count ?? 0

        if let doufuMarkdown, !doufuMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let truncated = truncatedLongContent(doufuMarkdown)
            sections.append("""
            ## Project Memory (DOUFU.MD)
            Long-lived project context and architecture notes:

            \(truncated)
            """)
        }

        // When DOUFU.MD is absent or small, inject the <doufu-update> instruction
        // directly after the main prompt's Response Metadata Blocks section.
        // We insert it into sections[0] so it stays grouped with <memory-update>.
        if doufuLineCount < 10 {
            let doufuInstruction = """

            ### `<doufu-update>` — Auto-learn project patterns
            When you discover important project patterns during your work (tech stack, code conventions, architecture decisions, recurring issues), include a `<doufu-update>` block at the end of your response:
            ```
            <doufu-update>
            - Tech stack: vanilla JS + Tailwind CSS
            - Convention: all API calls go through api.js
            </doufu-update>
            ```
            Each line is appended to DOUFU.MD. Only include genuinely useful, stable facts — not task-specific notes. Do NOT repeat information already in DOUFU.MD.
            """
            // Insert after the "## Response Metadata Blocks" section within sections[0],
            // right before "## Error Recovery"
            if let range = sections[0].range(of: "\n        ## Error Recovery") {
                sections[0].insert(contentsOf: doufuInstruction, at: range.lowerBound)
            }
        }

        return sections.joined(separator: "\n\n")
    }

    // MARK: - Memory User Prompt

    func agentUserPrompt(
        userMessage: String,
        memoryJSON: String
    ) -> String {
        """
        <session-memory>
        \(memoryJSON)
        </session-memory>

        <user-request>
        \(userMessage)
        </user-request>
        """
    }

    // MARK: - Device Detection

    private static let isIPad: Bool = UIDevice.current.userInterfaceIdiom == .pad

    private static let deviceLabel: String = isIPad ? "iPad" : "iPhone"

    private static let deviceGuidelines: String = isIPad
        ? """
        Current device: iPad. The app window can be resized at any time (full screen, Split View, Slide Over). \
        Layouts MUST be responsive — adapt from compact width (~320pt) to full iPad width (~1024pt) using CSS media queries or container queries. \
        Use single-column layout at narrow widths and optionally multi-column (side-by-side panels, master-detail) at wider breakpoints.
        """
        : """
        Current device: iPhone. Default to single-column, portrait-first layout. Landscape rotation may occur — \
        layouts must remain usable in both orientations without hard-coded portrait-only dimensions.
        """

    // MARK: - Helpers

    private func truncatedLongContent(_ rawText: String) -> String {
        let normalized = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        let limit = configuration.maxLongContentCharactersInPrompt
        guard normalized.count > limit else {
            return normalized
        }
        let omitted = normalized.count - limit
        return String(normalized.prefix(limit)) + "\n...(\(omitted) characters truncated)"
    }
}
