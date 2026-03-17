# 执行计划

## 当前状态（2026-03-14）

1. 已完成首页项目画廊（搜索、长按菜单、拖拽排序、新建入口）。
2. 已完成项目运行页（全屏预览 + 悬浮面板 + 退出确认 + 文件入口）。
3. 已完成项目级设置页（名称/描述修改、项目级模型、工具权限、checkpoint history 入口）。
4. 已完成 Git checkpoint history（agent loop 前自动保存、实际改动后创建 checkpoint、列表恢复）。
5. 已完成 Provider 管理全链路（OpenAI Compatible / Anthropic / Gemini / OpenRouter，均支持 API Key + OAuth）。
6. 已完成 Provider 模型管理（发现/自定义/能力参数编辑）。
7. 已完成 `LLMModelRegistry` 统一模型能力解析（多级优先级回退）。
8. 已完成聊天架构升级为 **tool-use agent loop**（替代原 pipeline 三路执行）。
9. 已完成 16 种 Agent 工具：文件 CRUD、搜索、diff、web_search、web_fetch、validate_code、doufu_api_docs。
10. 已完成工具权限分级与三种权限模式（standard / autoApproveNonDestructive / fullAutoApprove）。
11. 已完成只读工具并行执行与写入工具顺序执行。
12. 已完成 `ProjectGitService`：项目级 Git 初始化、自动保存、检查点创建、历史恢复与 undo helper。
13. 已完成 `CodeValidator`：隐藏 WKWebView 代码验证。
14. 已完成 `WebToolProvider`：Web 搜索（多引擎降级）与网页抓取。
15. 已完成对话上下文 4 阶段自适应压缩。
16. 已完成 extended thinking 内容展示（Claude thinking blocks）。
17. 已完成迭代预算控制与 max_tokens 截断自动续传。
18. 已完成项目级/线程级模型选择持久化。
19. 已完成默认模型选择 UI 与 LLM 快速设置引导。
20. 已完成设置页重构（General / LLM Providers / Project 三组 + 通用 SettingsPickerViewController）。
21. 已完成聊天输入框升级（多行输入 + 动态高度）与 thread 持久化。
22. 已完成 WebView JS 错误桥接、预览图 JPEG 保存、文件浏览器与 Runestone 编辑。
23. 已完成 Token Usage 页面能力（全局 + 项目视角、7 天图表、按周翻页、Provider/Model 维度切换、长按明细）。
24. 已完成 Token Usage 相关文案本地化（`en / zh-Hans / zh-Hant / zh-HK`）。
25. 已完成 CDN 资源缓存（LocalWebServer URL 改写 + 磁盘缓存 + 离线兜底）。
26. 已完成聊天模块职责拆分（`ChatMessageStore` / `ChatModelSelectionManager` / `ChatMenuBuilder` + 薄 VC）。
27. 已完成消息流 FlowState 状态机（idle / progress / streaming 三态，原子转换，消除孤儿 live cell 和全部结束间隙）。
28. 已完成 SQLite 迁移（GRDB.swift）：所有结构化数据从 JSON/UserDefaults 迁移到 SQLite 数据库。
29. 已完成项目磁盘结构 v4（`Projects/{uuid}/App/` + `AppData/`）。
30. 已完成聊天数据 SQLite 存储（线程、消息、助理、会话记忆）。
31. 已完成聊天模块 UI 重组至 `Features/Chat/` 目录。
32. 已完成 `ProjectLifecycleCoordinator`：项目生命周期统一入口（create / delete / close / rename），修复删除执行中项目文件丢失、discard 后 session 泄漏、rename 后 session context 不同步三处 Bug。
33. 已完成 project 状态收口：引入 `ProjectChangeCenter` 统一项目变更广播，引入 `ProjectActivityStore` 统一项目活动状态（building / newVersionAvailable / needsConfirmation / error）。
34. 已完成数据层完善：索引优化（`token_usage.created_at`、`message(thread_id, sort_order)` 复合索引）、迁移合并为单一 `v1_initial_schema`。

## 已完成阶段回顾

1. Phase A：基础框架
   - 文档骨架、目录规范、核心模块边界。
2. Phase B：项目生命周期
   - 本地项目创建、读取、删除、改名、更新时间维护、Git 仓库初始化与 checkpoint history。
3. Phase C：首页交互
   - 卡片网格展示、搜索、空状态、上下文菜单、排序页。
4. Phase D：运行与编辑入口
   - `WKWebView` 运行页、悬浮面板、刷新与退出流程、文件浏览与编辑。
5. Phase E：Provider 与认证
   - Manage Providers、Add Provider、多 Provider（OpenAI/Anthropic/Gemini/OpenRouter）、API Key 与 OAuth。
6. Phase F：聊天改工程（Pipeline 阶段）
   - 文件上下文、流式请求、JSON 补丁解析、安全写入、日志排障。
7. Phase G：Agent 架构升级
   - 从 pipeline 三路执行升级为 tool-use agent loop。
   - 15 种工具定义与执行、权限分级。
   - Git 检查点、历史恢复与 undo helper。
   - 代码验证、Web 搜索与抓取。
   - 对话上下文自适应压缩。
   - Extended thinking 支持。
8. Phase H：模型管理
   - `LLMModelRegistry` 统一能力解析。
   - 项目级/线程级模型选择持久化。
   - 默认模型选择 UI、LLM 快速设置引导。
   - Provider 模型列表管理与能力编辑。
9. Phase H.5：聊天模块重构
   - `ProjectChatViewController` 职责拆分为四个文件。
   - 消息流 FlowState 状态机，保证任务期间恰好一条 live 消息。
10. Phase I：SQLite 迁移
    - 引入 GRDB.swift 7.10.0，建立 `DatabaseManager` 单例（WAL 模式，外键 ON）。
    - 14 张表覆盖所有结构化数据：项目元数据（`project` + `permission` + `project_capability` + `capability_activity`）、Provider 配置（`llm_provider` + `llm_provider_model`）、三层模型选择、聊天数据（`thread` + `assistant` + `message` + `session_memory`）、token 用量。单一迁移 `v1_initial_schema`。
    - 移除所有 JSON 文件存储（manifest.json, threads_index, thread_messages, project_config, thread_selections）和 UserDefaults 存储（providers, token usage）。
    - 项目磁盘结构升级到 v4：`Documents/Projects/{uuid}/App/` + `AppData/`。
    - 聊天 UI 文件重组到 `Features/Chat/` 目录。
11. Phase I.5：Project 状态收口
   - 从跨 VC 闭包回调切换为 `ProjectChangeCenter` project-scoped 事件流。
   - 引入 `ProjectActivityStore`，统一首页、运行页、聊天页的执行状态语义。
   - checkpoint restore 与活跃聊天会话联动，恢复后自动开启新 thread。

## 下一阶段计划

1. Phase J：聊天体验增强
   - 失败重试策略可视化、结果回滚体验、direct answer 与改代码路径的体验对齐。
2. Phase K：项目调试能力
   - 运行日志可视化、构建前检查、错误定位辅助。
3. Phase L：Provider 生态扩展
   - 连通性检测、模型能力探测、配置导入导出。
4. Phase M：分享与导出
   - 项目导出包、隐私检查、分享入口。

## 验收口径（下一阶段）

1. 聊天失败场景可定位原因并有明确恢复路径。
2. 关键改动可回滚，不破坏项目目录完整性。
3. Git checkpoint 历史可正确恢复代码目录，同时保持 `AppData/` 用户数据不受影响。
4. 新增能力不破坏现有项目运行与 Provider 配置。
