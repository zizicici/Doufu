//
//  PromptBuilder.swift
//  Doufu
//
//  Created by Codex on 2026/03/05.
//

import Foundation

final class PromptBuilder {
    private let configuration: CodexChatConfiguration

    init(configuration: CodexChatConfiguration) {
        self.configuration = configuration
    }

    func patchDeveloperInstruction() -> String {
        """
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
            "objective": "可选，更新后的目标摘要",
            "constraints": ["可选，约束列表"],
            "todo_items": ["可选，后续待办列表"]
          }
        }
        规则：
        1) path 必须是相对路径，禁止以 / 开头，禁止 ..。
        2) 只改与用户需求相关的最小文件集。
        3) 若仅改大文件中的少量片段，优先使用 search_replace_changes 以减少冗余输出。
        4) 若无需改动，返回 changes: [] 且 search_replace_changes: []。
        5) 修改网页时尽量保证可直接运行（html/css/js 一致）。
        """
    }

    func patchUserPrompt(memoryJSON: String, filesJSON: String, userMessage: String) -> String {
        """
        设备上下文：
        - Platform: iPhone
        - Orientation: portrait
        - 要求：移动优先、Safe Area 完整适配、降低网页感、提升原生感

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

    func fileSelectionUserPrompt(userMessage: String, memoryJSON: String, fileCatalogJSON: String) -> String {
        """
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

    func taskPlanUserPrompt(userMessage: String, memoryJSON: String, filePathListJSON: String) -> String {
        """
        用户请求：
        \(userMessage)

        会话记忆块（JSON）：
        \(memoryJSON)

        项目文件路径列表（JSON）：
        \(filePathListJSON)
        """
    }

    func patchResponseTextFormat() -> ResponsesTextFormat {
        ResponsesTextFormat(
            type: "json_schema",
            name: "doufu_patch_payload",
            schema: .object([
                "type": .string("object"),
                "properties": .object([
                    "assistant_message": .object(["type": .string("string")]),
                    "changes": .object([
                        "type": .string("array"),
                        "items": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "path": .object(["type": .string("string")]),
                                "content": .object(["type": .string("string")])
                            ]),
                            "required": .array([.string("path"), .string("content")]),
                            "additionalProperties": .bool(false)
                        ])
                    ]),
                    "search_replace_changes": .object([
                        "type": .string("array"),
                        "items": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "path": .object(["type": .string("string")]),
                                "operations": .object([
                                    "type": .string("array"),
                                    "items": .object([
                                        "type": .string("object"),
                                        "properties": .object([
                                            "search": .object(["type": .string("string")]),
                                            "replace": .object(["type": .string("string")]),
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
                    "memory_update": .object([
                        "type": .string("object"),
                        "properties": .object([
                            "objective": .object(["type": .string("string")]),
                            "constraints": .object([
                                "type": .string("array"),
                                "items": .object(["type": .string("string")])
                            ]),
                            "todo_items": .object([
                                "type": .string("array"),
                                "items": .object(["type": .string("string")])
                            ])
                        ]),
                        "additionalProperties": .bool(false)
                    ])
                ]),
                "required": .array([.string("assistant_message"), .string("changes")]),
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
}
