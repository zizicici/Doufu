//
//  PromptBuilder.swift
//  Doufu
//
//  Created by Codex on 2026/03/05.
//

import Foundation

final class PromptBuilder {
    private let configuration: ProjectChatConfiguration

    init(configuration: ProjectChatConfiguration) {
        self.configuration = configuration
    }

    // MARK: - Agent System Prompt

    func agentSystemPrompt(
        threadContext: ProjectChatService.ThreadContext?,
        agentsMarkdown: String?
    ) -> String {
        var sections: [String] = []

        sections.append("""
        You are the Doufu engineering assistant. You help users build and modify local web-project files on their iPhone through natural conversation.

        ## How to Work
        1. Use the available tools to explore, read, and modify project files.
        2. Always read a file before editing it so you know the current content.
        3. Use `list_directory` to understand the project structure when needed.
        4. Use `edit_file` for targeted changes to existing files. Use `write_file` only for new files or when the majority of the content changes.
        5. Use `search_files` to find where things are defined or used across the project.
        6. After making changes, briefly summarize what you did.

        ## Mobile Web Guidelines
        The default target device is an iPhone in portrait orientation. Follow these rules unless the user explicitly requests otherwise:
        - Mobile-first layout: default to a single column; avoid desktop-style multi-column layouts.
        - Handle Safe Area insets correctly (top/right/bottom/left via env(safe-area-inset-*)).
        - Interactive controls must have a minimum touch target height of 44px.
        - Do not rely on hover for critical interactions.
        - Styling should be restrained, clear, and lightweight — closer to a native app than a traditional web page.

        ## Important Rules
        - Always reply to the user in the same language they used.
        - File paths must be relative to the project root. Never use absolute paths or `..`.
        - Ensure modified web pages remain runnable (consistent html/css/js).
        - Do not make changes the user did not ask for.
        """)

        if let agentsMarkdown, !agentsMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append("""
            ## Project-Specific Rules (AGENTS.md)
            The following rules are defined by the project and take highest priority:

            \(agentsMarkdown)
            """)
        }

        if let threadContext {
            let memoryMarkdown = truncatedThreadMemory(threadContext.memoryContent)
            sections.append("""
            ## Current Thread Context
            - thread_id: \(threadContext.threadID)
            - memory_file: \(threadContext.memoryFilePath)
            - memory_version: \(threadContext.version)

            Thread memory:
            \(memoryMarkdown)
            """)
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

    // MARK: - Helpers

    private func truncatedThreadMemory(_ rawText: String) -> String {
        let normalized = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > configuration.maxThreadMemoryCharactersInPrompt else {
            return normalized
        }
        return String(normalized.prefix(configuration.maxThreadMemoryCharactersInPrompt)) + "\n...(truncated)"
    }
}
