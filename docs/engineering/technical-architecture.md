# 技术架构说明

## 技术选型

1. UI：`UIKit`（主框架）
2. Web 运行：`WKWebView`
3. 本地存储：`GRDB.swift`（SQLite）+ `FileManager`（项目文件）
4. 并发：`Swift Concurrency`
5. 凭证：`Keychain`
6. 代码编辑：`Runestone`（可用时）+ Tree-sitter 语言包
7. 版本控制：`SwiftGitX`（项目级 Git 检查点与 undo）
8. 数据库：`GRDB.swift 7.10.0`，WAL 模式，外键 ON

## 架构原则

1. ViewController 聚焦 UI 和交互，核心逻辑下沉到 Service/Store。
2. 项目、Provider、聊天管线、统计分别独立模块。
3. 数据本地优先，默认不依赖云端项目存储。
4. 移动端优先（iPhone 竖屏、Safe Area、触控友好）。

## 关键目录映射

1. `Doufu/App/`
   - App 生命周期与根导航。`AppDelegate.setup()` 初始化 `DatabaseManager`。
2. `Doufu/Core/Database/`
   - `DatabaseManager`：SQLite 数据库单例，持有 `DatabasePool`，当前保留单个 `v1_initial_schema` 迁移，一次性创建所有现用表结构。
   - `DatabaseRecords`：所有 GRDB Record 类型（DBProject, DBPermission, DBProvider, DBProviderModel, DBTokenUsage, DBAppModelSelection, DBProjectModelSelection, DBThreadModelSelection, DBChatThread, DBAssistant, DBChatMessage, DBSessionMemory）及 domain ↔ DB 映射扩展。
   - `DatabaseTimestamp`：Date ↔ Int64 纳秒转换。
3. `Doufu/Core/Projects/`
   - `AppProjectStore`：项目元数据 CRUD 通过 GRDB（`project` + `permission` 表），创建项目目录与模板文件、读写项目元数据与权限。
   - `ProjectLifecycleCoordinator`：项目生命周期统一入口（create / delete / close / rename）；协调 `AppProjectStore` 与 `ChatSessionManager`，确保 ChatSession 状态与项目变更一致。
   - `ProjectChangeCenter`：project-scoped 变更事件中心，统一广播 `filesChanged`、`checkpointRestored`、`renamed`、`descriptionChanged`、`toolPermissionChanged`、`modelSelectionChanged`；其中 `filesChanged` / `checkpointRestored` 同步维护 `updatedAt`。
   - `ProjectActivityStore`：project-scoped 活动状态源，维护 `idle / building / newVersionAvailable / needsConfirmation / error`，供 Home / Workspace / Chat 共享消费。
   - `ProjectGitService`：项目级 Git 初始化、agent loop 前自动保存、检查点创建、历史恢复与 undo helper。
   - `ProjectArchiveImportService`：`.doufu` / `.doufull` 导入服务；负责 ZIP 安全解包、结构校验、创建新项目并落盘 `App/`、`AppData/`。
   - `ProjectArchiveExportService`：`.doufu` / `.doufull` 导出服务；负责按格式打包 `App/` 或 `App/ + AppData/`。
4. `Doufu/Core/Chat/`
   - `ChatSessionManager`：project-scoped ChatSession 注册表，允许 Workspace 关闭后会话在当前进程内继续执行。
   - `ChatSession`：项目级长生命周期聊天运行时，持有线程/消息状态、执行协调、pending tool confirmation continuation，并消费 `ProjectChangeCenter` 事件。
   - `ChatTaskCoordinator`：单次请求执行协调器；桥接 `ProjectChatOrchestrator`、`ActiveTaskManager`、`PiPProgressManager` 与 `ProjectActivityStore`。
5. `Doufu/Core/LLM/`
   - `ProjectChatService`：聊天服务对外入口与数据模型定义。
   - `LLMModelRegistry`：统一模型能力解析（capabilities + token budgets）。
   - `ChatDataStore`：`final class`，通过 GRDB `DatabasePool` 同步读写聊天数据（线程、消息、助理、会话记忆）。
   - `ChatDataService`：`@MainActor final class`，绑定单个 `projectID`，提供自动持久化。
   - `ChatSessionContext`：分离存储键（`projectID`）、工具执行路径（`workspaceURL` = App/）和 `projectRootURL`。
   - `ChatDataModels`：聊天数据模型定义，含 `ModelSelection` 统一类型。
   - `SessionMemory`：会话记忆模型。
   - `ModelSelectionStateStore`：App / Project / Thread 三层模型选择的共享状态源、缓存与变更通知。
   - `ModelSelectionResolver`：三层 `ModelSelection` 解析、校验与归一化。
   - `OpenAIOAuthService`：OpenAI OAuth（PKCE + localhost 回调）。
   - `LLMProviderSettingsStore`：Provider / Model CRUD 通过 GRDB（`llm_provider` + `llm_provider_model` 表）+ Keychain 凭证管理 + 三层 ModelSelection CRUD。
   - `LLMProviderModelDiscoveryService`：Provider 模型列表发现。
   - `ProviderCredentialResolver`：凭证解析（Keychain）。
   - `LLMTokenUsageStore`：token 用量写入 `token_usage` 表，SQL GROUP BY / SUM 查询统计。
   - `ChatPipeline/*`：
     - `ProjectChatOrchestrator`：Agent 循环主控制器
     - `ProjectChatConfiguration`：Agent 配置参数
     - `AgentTools`：工具定义、权限模型、进度事件
     - `PromptBuilder`：系统提示词与用户消息构建
     - `SessionMemoryManager`：会话记忆管理
     - `LLMStreamingClient`：流式请求客户端
     - `ToolUseRequestModels`：工具调用请求/响应模型
     - `LLMProviderProtocol`：Provider 请求适配协议
     - `OpenAIProvider` / `AnthropicProvider` / `GeminiProvider`：各 Provider 实现
     - `WebToolProvider`：Web 搜索与网页抓取
     - `CodeValidator`：隐藏 WKWebView 代码验证
     - `ProjectPathResolver`：项目路径安全解析
6. `Doufu/Features/Home/` + `Doufu/HomeViewController.swift`
   - 首页画廊与排序页，消费 `ProjectActivityStore` 展示项目状态标签。
7. `Doufu/Features/Chat/`
   - `ChatViewController`：聊天页 UI 布局与胶水代码（线程切换、输入处理、coordinator delegate 转发）。
   - `ChatThreadSessionManager`：线程会话管理。
   - `ChatMessageStore`：消息数组管理与 FlowState 状态机（idle / progress / streaming），通过 delegate 回调驱动 UI。
   - `ChatModelSelectionManager`：消费 `ModelSelectionStateStore`、解析当前有效模型、生成 reasoning/thinking 运行时选项。
   - `ChatMenuBuilder`：所有 UIMenu 构建（static 方法，无状态）。
   - `ChatMessage`：聊天消息模型。
   - `ChatMessageCell`：聊天消息气泡渲染。
   - `MarkdownRenderer`：Markdown 渲染。
   - `ModelConfigurationViewController`：共享模型配置页（App / Project / Thread）。
   - `ThreadManagementViewController`：线程管理页。
   - `MessageDetailViewController`：消息详情页。
   - 聊天页负责在重新出现时恢复 pending tool confirmation 展示，并在 checkpoint restore 后与新的 thread 上下文对齐。
8. `Doufu/Features/ProjectRuntime/`
   - `ProjectWorkspaceViewController`：项目运行页与悬浮面板，订阅 `ProjectChangeCenter` 刷新预览，并仅在真正可见时消费 `newVersionAvailable`。
   - `ProjectFileBrowserViewController`：文件树浏览与内容编辑。
   - `ProjectSettingsViewController`：项目设置与 checkpoint history 入口。
   - `ProjectTokenUsageViewController`：项目级 token 使用量。
   - `ProjectModelSelectionViewController`：项目级模型选择。
   - `ProjectOpenTransition`：项目打开转场动画。
9. `Doufu/Features/Settings/`
   - `SettingsViewController`：全局设置（General / LLM Providers / Project 三组）。
   - `ManageProvidersViewController`：Provider 列表管理。
   - `AddProviderViewController`：新增 Provider。
   - `ProviderAuthMethodViewController`：认证方式选择。
   - `ProviderAPIKeyFormViewController` / `ProviderOAuthFormViewController`：认证表单。
   - `ProviderModelEditorViewController`：模型能力编辑。
   - `ProviderModelManagementCoordinator`：模型管理协调器。
   - `DefaultModelSelectionViewController`：默认模型选择。
   - `LLMQuickSetupViewController`：首次使用快速设置。
   - `TokenUsageViewController`：全局 token usage Dashboard。
   - `SettingsPickerViewController`：通用选项选择器。
10. `Doufu/Features/Settings/Components/`
   - 设置风格复用 Cell 组件。
11. `Doufu/Core/`（其他）
    - `UIColor+Doufu`：自定义颜色扩展。
    - `WKWebView+Doufu`：WKWebView 扩展。
    - `LocalWebServer`：本地 Web 服务，含 CDN 资源代理缓存。
    - `DoufuBridge`：JS 桥接。
    - `ActiveTaskManager`：活跃任务追踪。
    - `PiPProgressManager`：画中画进度管理。

## 核心数据模型

### Domain 层

1. `AppProjectRecord`
   - `id`（纯 UUID，无前缀）, `name`, `projectURL`, `createdAt`, `updatedAt`
   - 计算属性：`appURL`（projectURL/App/）、`dataURL`（projectURL/AppData/）、`entryFileURL`（appURL/index.html）
2. `LLMProviderRecord`
   - `id`, `kind`, `authMode`, `label`, `baseURLString`, `autoAppendV1`, `extra`
3. `LLMProviderModelRecord`
   - Provider 关联的模型记录，含 `source`（discovered / custom）和 `capabilities`。
4. `ResolvedModelProfile`
   - 统一的模型能力描述：`reasoningEfforts`, `thinkingSupported`, `thinkingCanDisable`, `structuredOutputSupported`, `maxOutputTokens`, `contextWindowTokens`。
5. `ModelSelection`
   - 统一的模型选择类型（providerID, modelRecordID, reasoningEffort?, thinkingEnabled?），App/Project/Thread 三层共用。

### DB 层（GRDB Record）

1. `DBProject` / `DBPermission`
   - 项目元数据与工具权限（UNIQUE FK CASCADE）。
2. `DBProvider` / `DBProviderModel`
   - Provider 配置与关联模型（FK CASCADE：删除 Provider 自动删除模型）。
3. `DBTokenUsage`
   - 单次 LLM 请求的 token 用量记录。
4. `DBAppModelSelection` / `DBProjectModelSelection` / `DBThreadModelSelection`
   - 三层模型选择持久化。
5. `DBChatThread` / `DBAssistant` / `DBChatMessage` / `DBSessionMemory`
   - 聊天线程、助理（每线程一个）、消息、会话记忆。
   - CASCADE：删除线程 → 自动删除关联的助理、消息、会话记忆。
   - `message.assistant_id` 可空（NULL = 用户消息）。
   - `message.message_type`：0=system, 1=normal, 2=progress。
   - `message.token_usage_id` FK → `token_usage`。

## 本地存储约定

### SQLite 数据库

- 路径：`Documents/doufu.sqlite`（WAL 模式，外键 ON）
- 12 张表：`project`, `permission`, `llm_provider`, `llm_provider_model`, `token_usage`, `app_model_selection`, `project_model_selection`, `thread_model_selection`, `thread`, `assistant`, `message`, `session_memory`
- 所有结构化数据（项目元数据、Provider 配置、模型选择、聊天线程/消息/记忆、token 用量）统一存储在 SQLite 中

### 项目磁盘结构（v4）

- 根目录：`Documents/Projects/{uuid}/`（projectID 为纯 UUID，无前缀）
- `App/`：代码文件（index.html, style.css, script.js, AGENTS.md, DOUFU.MD）+ `.git`
- `AppData/`：用户数据（localStorage.json）— Git 检查点恢复时保留
- `preview.jpg`：项目预览图（运行页截图写入），位于项目根目录

### 项目归档格式（v1）

- `.doufu`：标准 ZIP 语义；导出/导入内容仅包含 `App/`。
- `.doufull`：标准 ZIP 语义；导出/导入内容包含 `App/` + `AppData/`（不包含 `preview.jpg`）。
- 导入按扩展名识别格式；同一归档允许重复导入，每次都会创建新项目 UUID。

### Git

- `{project}/App/.git/`（由 `ProjectGitService` 管理）
- 当前版本恢复能力依赖 Git checkpoint history；未启用独立的文件系统快照目录

### 凭证

- `Keychain`：API Key / OAuth Bearer Token

### UserDefaults（仅少量配置）

- `appDefaultToolPermissionMode`：App 级别工具权限模式

## Agent 聊天执行链路（当前实现）

1. 入口
   - `ProjectChatService` 构建 `ProviderCredential`（含 `ResolvedModelProfile`）。
   - `ProjectChatOrchestrator.sendAndApply()` 启动 agent loop。
2. 准备阶段
   - 读取 `AGENTS.md` 和 `DOUFU.MD` 作为额外上下文。
   - 构建系统提示词（含工具说明、安全约束、memory 格式）。
   - 将历史对话与工具活动摘要组装为 conversation items。
   - 确保 Git 仓库存在，并自动保存当前脏工作区。
3. Agent 循环
   - 每轮向模型发送完整 conversation + 工具定义。
   - 模型返回文本和/或工具调用。
   - 无工具调用：作为最终回复结束循环。
   - 有工具调用：按类型分流执行（只读并行 / 写入顺序）。
   - 工具结果追加到 conversation，进入下一轮。
   - 响应被 `max_tokens` 截断时自动续传。
   - 接近迭代预算上限时注入系统提示收尾。
4. 工具执行
   - 只读工具（`read_file`, `list_directory`, `search_files`, `grep_files`, `glob_files`, `diff_file`, `changed_files`）使用 TaskGroup 并行执行。
   - 写入工具（`write_file`, `edit_file`, `move_file`, `revert_file`）顺序执行。
   - 危险工具（`delete_file`, `web_search`, `web_fetch`）需用户确认。
   - `validate_code` 使用共享 WKWebView，不可并行。
5. 上下文管理
   - 4 阶段自适应压缩：
     1. 激进压缩可重读的工具结果
     2. 适度压缩搜索结果
     3. 压缩剩余大型非错误结果
     4. 丢弃最旧对话轮次（保持工具结果配对）
   - 历史对话和文件上下文做预算裁剪。
   - `memory_update` 与 thread memory 同步更新，可触发版本 rollover。
6. 权限控制
   - 三种权限模式：`standard` / `autoApproveNonDestructive` / `fullAutoApprove`。
   - 工具按危险程度分三级：`autoAllow` / `confirmOnce` / `alwaysConfirm`。
   - `confirmOnce` 工具在会话内首次使用时确认，之后自动通过。
7. 进度与回调
   - `ToolProgressEvent` 枚举覆盖所有工具操作阶段。
   - 支持 extended thinking 内容回传（Claude thinking blocks）。
   - 流式文本实时回传 UI。
   - `ChatMessageStore.FlowState` 状态机管理消息生命周期：
     - `.idle` → `.streaming` / `.progress`：首个事件到达时创建 live cell。
     - `.streaming` ↔ `.progress`：原子转换（finalize 旧 cell + 创建新 cell 同步完成）。
     - 任意 → `.idle`：请求完成/取消/出错时 finalize 并重置。
     - 不变量：任务执行期间恰好有一条消息 `finishedAt == nil`。
8. 失败与回退
   - 若 agent 实际改动了文件，结束时创建新的 Git checkpoint。
   - SSE 与非 SSE 响应都做失败解析。
   - `xhigh` 被拒时回退到 `high`。
   - `json_schema` 被拒时回退为普通文本模式重试。
   - 取消信号可透传整个链路。

## 项目变更与活动状态

1. 统一变更入口
   - 所有 project-scoped mutation 统一经 `ProjectChangeCenter` 广播，而不是由 VC 之间手工传闭包。
   - 当前事件类型包括：`filesChanged`、`checkpointRestored`、`renamed`、`descriptionChanged`、`toolPermissionChanged`、`modelSelectionChanged`。
2. 变更生产者
   - `ChatSession`（agent 改文件）
   - `ProjectFileBrowserViewController`（手动保存文件）
   - `ProjectSettingsViewController`（描述、工具权限、checkpoint restore）
   - `ProjectLifecycleCoordinator`（rename）
   - `ModelSelectionStateStore`（项目默认模型变化）
3. 变更消费者
   - `HomeViewController`：刷新项目列表、更新时间与活动标签。
   - `ProjectWorkspaceViewController`：刷新项目元数据、reload `WKWebView`，并仅在 workspace 真正可见时消费 `newVersionAvailable`。
   - `ChatSession`：收到 `checkpointRestored` 后新建 thread，并插入系统消息，避免旧聊天上下文继续作用于已恢复的代码状态。
4. 活动状态机
   - `ChatTaskCoordinator` 在任务开始、完成、取消、失败时更新 `ProjectActivityStore`。
   - `needsConfirmation` 表示工具确认被挂起，用户回到聊天页后可继续同一次确认。
   - `error` 不会在“准备打开聊天页”时提前清空；只有后续运行或显式状态变更才会覆盖它。
   - `newVersionAvailable` 只有在用户真正看到该项目运行页后才会被消费，避免后台存活的 workspace 提前吞掉首页标签。

## 多 Provider 请求适配

1. OpenAI Compatible
   - 走 `/responses`（流式 SSE）。
2. Anthropic
   - 走 `/messages`。
   - 支持 thinking 开关与 budget；若后端拒绝则自动降级。
3. Google Gemini
   - 走 `/models/{model}:generateContent`。
   - 支持 thinking budget；若后端拒绝则自动降级。
4. 聊天页按 Provider/Model 维度选择模型与参数：
   - `App / Project / Thread` 三层共享同一份 `ModelSelection(provider, model, reasoning, thinking)` 结构
   - OpenAI Compatible：`reasoning effort`
   - Anthropic/Gemini：`thinking` 开关

## OAuth 说明

1. OpenAI OAuth
   - `SFSafariViewController` + PKCE + `localhost:1455/auth/callback`。
   - 回调成功后自动填充 Base URL 和 Bearer Token。
2. Anthropic / Gemini OAuth
   - 当前为外部登录页跳转 + 手动填写 Token 的配置流（无本地 callback 交换）。

## 安全边界

1. 仅允许项目目录内读写，路径必须是安全相对路径。
2. 禁止绝对路径和 `..` 路径穿越。
3. 密钥不写入项目目录，只在 Keychain 中保存。
4. 调试日志默认脱敏请求体，避免泄露凭证。
5. 工具权限分级，危险操作需用户确认。

## CDN 资源缓存

1. `LocalWebServer` 在返回 HTML/CSS 文件时，将 `https://` 外部资源 URL 改写为走本地 `/__doufu_proxy__?url=<encoded>&cache=1` 代理路径。
2. Proxy 端检测 `cache=1` 参数时启用磁盘缓存（`Caches/CDNCache/`）：命中缓存直接返回，未命中则网络请求后缓存，网络失败时回退旧缓存。
3. 缓存 Key 为 URL 的 SHA256，存储 `<hash>.data` + `<hash>.meta`（JSON: contentType, statusCode, url）。
4. 容量上限 200 MB，超出按 LRU 淘汰到 150 MB；系统存储压力时可自动清除。
5. fetch/XHR 发起的 API 请求不带 `cache=1`，不会被缓存。
6. 提供 `clearCDNCache()` 公开方法供外部调用。
