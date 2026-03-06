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

    func patchDeveloperInstruction(compactMode: Bool = false) -> String {
        var instruction = """
        你是 Doufu App 内的 Codex 工程助手。你会根据用户需求，直接修改本地网页项目文件。
        默认目标设备是 iPhone 竖屏，必须优先保证移动端体验，并尽量贴近 iOS 原生观感，避免强烈网页感。
        如果项目根目录存在 AGENTS.md，你必须严格遵循其规则，并在规则冲突时以 AGENTS.md 为最高优先级。

        移动端硬性要求（除非用户明确要求例外）：
        1) 保持移动优先布局，默认单栏，避免桌面化多栏主布局。
        2) 正确处理 Safe Area（top/right/bottom/left）。
        3) 交互控件触控区域高度至少 44px。
        4) 不依赖 hover 完成关键交互。
        5) 样式要克制、清晰、轻量，贴近原生 App，而非传统网页风格。

        你必须严格输出 JSON 对象，不要输出 markdown，不要输出代码块，不要输出额外说明。
        JSON schema:
        {
          "assistant_message": "给用户的简短说明",
          "changes": [
            {
              "path": "相对于项目根目录的文件路径，如 index.html 或 src/main.js",
              "content": "文件完整内容（覆盖写入）"
            }
          ],
          "search_replace_changes": [
            {
              "path": "相对路径",
              "operations": [
                {
                  "search": "要查找的原文片段",
                  "replace": "替换后的文本",
                  "replace_all": false,
                  "ignore_case": false
                }
              ]
            }
          ],
          "memory_update": {
            "memory_delta": {
              "objective": "可选，更新后的目标摘要",
              "constraints": ["可选，约束列表"],
              "todo_items": ["可选，后续待办列表"],
              "notes": ["可选，重要记录项"]
            },
            "thread_should_rollover": false,
            "thread_next_version_summary": "可选；若 thread_should_rollover 为 true，需提供上一版本简短摘要"
          }
        }
        规则：
        1) path 必须是相对路径，禁止以 / 开头，禁止 ..。
        2) 只改与用户需求相关的最小文件集，默认优先使用 search_replace_changes。
        3) 除“新建文件”或“文件很短（<=300行）”外，禁止使用 changes 返回整文件内容。
        4) 每次最多修改 6 个文件；每个文件最多 12 条 operations。
        5) 若无需改动，返回 changes: [] 且 search_replace_changes: []。
        6) 修改网页时尽量保证可直接运行（html/css/js 一致）。
        7) memory_update 必须始终有意义：总结本轮用户意图、已执行改动、未完成事项。
        8) 若你判断 thread_memory 过长难以维护，可将 thread_should_rollover 设为 true，并提供 thread_next_version_summary。
        9) 禁止返回 thread_content_markdown 与 thread_next_version_content_markdown 字段。
        10) 所有 JSON 字符串必须是合法 JSON 转义：
           - 换行写成 \\n
           - 双引号写成 \\\"
           - 反斜杠写成 \\\\
        """
        if compactMode {
            instruction += """

            当前是紧凑重试模式（上一次响应过长或格式异常）：
            A) 必须将 changes 置为 []，只允许使用 search_replace_changes。
            B) 只输出必要的最小修改：最多 3 个文件，每个文件最多 6 条 operations。
            C) memory_update.memory_delta.notes 保持精简，不超过 4 条。
            D) assistant_message 保持一句话简述，不超过 120 字符。
            """
        }
        return instruction
    }

    func patchUserPrompt(
        memoryJSON: String,
        filesJSON: String,
        userMessage: String,
        threadContext: ProjectChatService.ThreadContext?
    ) -> String {
        """
        设备上下文：
        - Platform: iPhone
        - Orientation: portrait
        - 要求：移动优先、Safe Area 完整适配、降低网页感、提升原生感

        \(threadContextBlock(threadContext))

        会话记忆块（JSON）：
        \(memoryJSON)

        当前项目文件（JSON）：
        \(filesJSON)

        用户请求：
        \(userMessage)
        """
    }

    func fileSelectionDeveloperInstruction() -> String {
        """
        你是 Doufu App 的上下文检索助手。你的任务是从文件清单中挑选最相关的文件路径，供后续代码修改阶段读取。
        你必须严格输出 JSON 对象，不要输出 markdown，不要输出代码块，不要输出额外说明。
        JSON schema:
        {
          "selected_paths": ["相对路径1", "相对路径2"],
          "notes": "可选，简短说明"
        }
        规则：
        1) 只能从给定清单中选择路径，禁止编造不存在的路径。
        2) 优先选择与用户请求直接相关的文件。
        3) 至少选择 1 个，最多选择 \(configuration.maxFilePathsFromSelection) 个。
        4) 若项目中存在 AGENTS.md，优先纳入 selected_paths。
        """
    }

    func fileSelectionUserPrompt(
        userMessage: String,
        memoryJSON: String,
        fileCatalogJSON: String,
        threadContext: ProjectChatService.ThreadContext?
    ) -> String {
        """
        \(threadContextBlock(threadContext))

        用户请求：
        \(userMessage)

        会话记忆块（JSON）：
        \(memoryJSON)

        文件清单（JSON）：
        \(fileCatalogJSON)
        """
    }

    func taskPlanDeveloperInstruction() -> String {
        """
        你是 Doufu App 的任务规划助手。你需要把用户请求拆成可顺序执行的 1 到 \(configuration.maxPlannedTasks) 个子任务。
        你必须严格输出 JSON 对象，不要输出 markdown，不要输出代码块，不要输出额外说明。
        JSON schema:
        {
          "summary": "任务总览，简短一句话",
          "tasks": [
            {
              "title": "任务标题（简短）",
              "goal": "该任务要完成的具体目标"
            }
          ]
        }
        规则：
        1) tasks 至少 1 个，最多 \(configuration.maxPlannedTasks) 个。
        2) 每个任务要可独立执行，且按顺序执行更稳妥。
        3) 若用户请求很简单，返回 1 个任务即可。
        4) 不要输出不存在的文件路径。
        """
    }

    func taskPlanUserPrompt(
        userMessage: String,
        memoryJSON: String,
        filePathListJSON: String,
        threadContext: ProjectChatService.ThreadContext?
    ) -> String {
        """
        \(threadContextBlock(threadContext))

        用户请求：
        \(userMessage)

        会话记忆块（JSON）：
        \(memoryJSON)

        项目文件路径列表（JSON）：
        \(filePathListJSON)
        """
    }

    func executionRouteDeveloperInstruction() -> String {
        """
        你是 Doufu App 的执行策略路由助手。你需要在 direct_answer、single_pass 与 multi_task 之间做选择。
        你必须严格输出 JSON 对象，不要输出 markdown，不要输出代码块，不要输出额外说明。
        JSON schema:
        {
          "mode": "direct_answer 或 single_pass 或 multi_task",
          "reason": "可选，简短理由",
          "assistant_message": "当 mode=direct_answer 时，给用户的最终直接回答",
          "memory_update": {
            "memory_delta": {
              "objective": "可选，更新后的目标摘要",
              "constraints": ["可选，约束列表"],
              "todo_items": ["可选，后续待办列表"],
              "notes": ["可选，重要记录项"]
            },
            "thread_should_rollover": false,
            "thread_next_version_summary": "可选；若 thread_should_rollover 为 true，需提供上一版本简短摘要"
          }
        }
        规则：
        1) mode 只能是 direct_answer / single_pass / multi_task。
        2) 若用户主要在提问、讨论方案、解释概念或排查思路，且不要求立即改文件，优先 direct_answer。
        3) 若用户明确要求修改代码，且改动集中且低风险时可选 single_pass。
        4) 若用户明确要求修改代码，且请求复杂、跨多文件或需分阶段稳定推进时优先 multi_task。
        5) 当 mode=direct_answer 时，assistant_message 必须是可以直接展示给用户的最终回答，不需要再走后续步骤。
        6) 当 mode=direct_answer 时，memory_update 至少应包含 memory_delta 或 thread_should_rollover。
        7) 禁止返回 thread_content_markdown 与 thread_next_version_content_markdown 字段。
        8) 所有 JSON 字符串必须是合法 JSON 转义：
           - 换行写成 \\n
           - 双引号写成 \\\"
           - 反斜杠写成 \\\\
        """
    }

    func executionRouteUserPrompt(
        userMessage: String,
        memoryJSON: String,
        threadContext: ProjectChatService.ThreadContext?
    ) -> String {
        """
        \(threadContextBlock(threadContext))

        用户请求：
        \(userMessage)

        会话记忆块（JSON）：
        \(memoryJSON)
        """
    }

    func directAnswerDeveloperInstruction() -> String {
        """
        你是 Doufu App 内的工程助手。当前任务是直接回答用户问题，不执行代码修改。
        你必须严格输出 JSON 对象，不要输出 markdown，不要输出代码块，不要输出额外说明。
        JSON schema:
        {
          "assistant_message": "给用户的直接回答",
          "memory_update": {
            "memory_delta": {
              "objective": "可选，更新后的目标摘要",
              "constraints": ["可选，约束列表"],
              "todo_items": ["可选，后续待办列表"],
              "notes": ["可选，重要记录项"]
            },
            "thread_should_rollover": false,
            "thread_next_version_summary": "可选；若 thread_should_rollover 为 true，需提供上一版本简短摘要"
          }
        }
        规则：
        1) 直接回答用户问题，不要输出文件修改建议列表。
        2) assistant_message 要简洁、可执行、可理解。
        3) memory_update 至少应包含 memory_delta 或 thread_should_rollover。
        4) 禁止返回 thread_content_markdown 与 thread_next_version_content_markdown 字段。
        5) 所有 JSON 字符串必须是合法 JSON 转义：
           - 换行写成 \\n
           - 双引号写成 \\\"
           - 反斜杠写成 \\\\
        """
    }

    func directAnswerUserPrompt(
        userMessage: String,
        memoryJSON: String,
        threadContext: ProjectChatService.ThreadContext?
    ) -> String {
        """
        \(threadContextBlock(threadContext))

        会话记忆块（JSON）：
        \(memoryJSON)

        用户请求：
        \(userMessage)
        """
    }

    func patchResponseTextFormat() -> ResponsesTextFormat {
        ResponsesTextFormat(
            type: "json_schema",
            name: "doufu_patch_payload",
            schema: .object([
                "type": .string("object"),
                "properties": .object([
                    "assistant_message": .object([
                        "type": .string("string"),
                        "maxLength": .integer(500)
                    ]),
                    "changes": .object([
                        "type": .string("array"),
                        "maxItems": .integer(6),
                        "items": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "path": .object([
                                    "type": .string("string"),
                                    "maxLength": .integer(512)
                                ]),
                                "content": .object([
                                    "type": .string("string"),
                                    "maxLength": .integer(12_000)
                                ])
                            ]),
                            "required": .array([.string("path"), .string("content")]),
                            "additionalProperties": .bool(false)
                        ])
                    ]),
                    "search_replace_changes": .object([
                        "type": .string("array"),
                        "maxItems": .integer(6),
                        "items": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "path": .object([
                                    "type": .string("string"),
                                    "maxLength": .integer(512)
                                ]),
                                "operations": .object([
                                    "type": .string("array"),
                                    "maxItems": .integer(12),
                                    "items": .object([
                                        "type": .string("object"),
                                        "properties": .object([
                                            "search": .object([
                                                "type": .string("string"),
                                                "maxLength": .integer(10_000)
                                            ]),
                                            "replace": .object([
                                                "type": .string("string"),
                                                "maxLength": .integer(10_000)
                                            ]),
                                            "replace_all": .object(["type": .string("boolean")]),
                                            "ignore_case": .object(["type": .string("boolean")])
                                        ]),
                                        "required": .array([.string("search"), .string("replace")]),
                                        "additionalProperties": .bool(false)
                                    ])
                                ])
                            ]),
                            "required": .array([.string("path"), .string("operations")]),
                            "additionalProperties": .bool(false)
                        ])
                    ]),
                    "memory_update": memoryUpdateSchema()
                ]),
                "required": .array([.string("assistant_message"), .string("changes"), .string("search_replace_changes"), .string("memory_update")]),
                "additionalProperties": .bool(false)
            ]),
            strict: true
        )
    }

    func directAnswerResponseTextFormat() -> ResponsesTextFormat {
        ResponsesTextFormat(
            type: "json_schema",
            name: "doufu_direct_answer",
            schema: .object([
                "type": .string("object"),
                "properties": .object([
                    "assistant_message": .object(["type": .string("string")]),
                    "memory_update": memoryUpdateSchema()
                ]),
                "required": .array([.string("assistant_message"), .string("memory_update")]),
                "additionalProperties": .bool(false)
            ]),
            strict: true
        )
    }

    func fileSelectionResponseTextFormat() -> ResponsesTextFormat {
        ResponsesTextFormat(
            type: "json_schema",
            name: "doufu_file_selection",
            schema: .object([
                "type": .string("object"),
                "properties": .object([
                    "selected_paths": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")])
                    ]),
                    "notes": .object(["type": .string("string")])
                ]),
                "required": .array([.string("selected_paths")]),
                "additionalProperties": .bool(false)
            ]),
            strict: true
        )
    }

    func taskPlanResponseTextFormat() -> ResponsesTextFormat {
        ResponsesTextFormat(
            type: "json_schema",
            name: "doufu_task_plan",
            schema: .object([
                "type": .string("object"),
                "properties": .object([
                    "summary": .object(["type": .string("string")]),
                    "tasks": .object([
                        "type": .string("array"),
                        "items": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "title": .object(["type": .string("string")]),
                                "goal": .object(["type": .string("string")])
                            ]),
                            "required": .array([.string("title"), .string("goal")]),
                            "additionalProperties": .bool(false)
                        ])
                    ])
                ]),
                "required": .array([.string("summary"), .string("tasks")]),
                "additionalProperties": .bool(false)
            ]),
            strict: true
        )
    }

    func executionRouteResponseTextFormat() -> ResponsesTextFormat {
        ResponsesTextFormat(
            type: "json_schema",
            name: "doufu_execution_route",
            schema: .object([
                "type": .string("object"),
                "properties": .object([
                    "mode": .object([
                        "type": .string("string"),
                        "enum": .array([.string("direct_answer"), .string("single_pass"), .string("multi_task")])
                    ]),
                    "reason": .object(["type": .string("string")]),
                    "assistant_message": .object(["type": .string("string")]),
                    "memory_update": memoryUpdateSchema()
                ]),
                "required": .array([.string("mode")]),
                "additionalProperties": .bool(false)
            ]),
            strict: true
        )
    }

    private func threadContextBlock(_ threadContext: ProjectChatService.ThreadContext?) -> String {
        guard let threadContext else {
            return "线程上下文：未提供。"
        }

        let memoryMarkdown = truncatedThreadMemory(threadContext.memoryContent)
        return """
        当前线程：
        - thread_id: \(threadContext.threadID)
        - memory_file: \(threadContext.memoryFilePath)
        - memory_version: \(threadContext.version)

        当前线程记忆（Markdown）：
        \(memoryMarkdown)
        """
    }

    private func truncatedThreadMemory(_ rawText: String) -> String {
        let normalized = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > configuration.maxThreadMemoryCharactersInPrompt else {
            return normalized
        }
        return String(normalized.prefix(configuration.maxThreadMemoryCharactersInPrompt)) + "\n...(truncated)"
    }

    private func memoryUpdateSchema() -> JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object([
                "memory_delta": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "objective": .object([
                            "type": .string("string"),
                            "maxLength": .integer(400)
                        ]),
                        "constraints": .object([
                            "type": .string("array"),
                            "maxItems": .integer(16),
                            "items": .object([
                                "type": .string("string"),
                                "maxLength": .integer(300)
                            ])
                        ]),
                        "todo_items": .object([
                            "type": .string("array"),
                            "maxItems": .integer(20),
                            "items": .object([
                                "type": .string("string"),
                                "maxLength": .integer(300)
                            ])
                        ]),
                        "notes": .object([
                            "type": .string("array"),
                            "maxItems": .integer(20),
                            "items": .object([
                                "type": .string("string"),
                                "maxLength": .integer(600)
                            ])
                        ])
                    ]),
                    "additionalProperties": .bool(false)
                ]),
                "thread_should_rollover": .object(["type": .string("boolean")]),
                "thread_next_version_summary": .object([
                    "type": .string("string"),
                    "maxLength": .integer(800)
                ])
            ]),
            "additionalProperties": .bool(false)
        ])
    }
}
