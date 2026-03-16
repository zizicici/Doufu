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
   - `DatabaseManager`：SQLite 数据库单例，持有 `DatabasePool`，迁移链：`v1_initial_schema`（13 表）、`v2_add_indexes`、`v3_project_capabilities`（`project_capability` 表）、`v4_capability_activity`（`capability_activity` 表 + 索引）。
   - `DatabaseRecords`：所有 GRDB Record 类型（DBProject, DBPermission, DBProjectCapability, DBCapabilityActivity, DBProvider, DBProviderModel, DBTokenUsage, DBAppModelSelection, DBProjectModelSelection, DBThreadModelSelection, DBChatThread, DBAssistant, DBChatMessage, DBSessionMemory）及 domain ↔ DB 映射扩展。
   - `DatabaseTimestamp`：Date ↔ Int64 纳秒转换。
3. `Doufu/Core/Projects/`
   - `AppProjectStore`：项目元数据 CRUD 通过 GRDB（`project` + `permission` 表），创建项目目录与模板文件、读写项目元数据与权限。
   - `ProjectLifecycleCoordinator`：项目生命周期统一入口（create / delete / close / rename）；协调 `AppProjectStore` 与 `ChatSessionManager`，确保 ChatSession 状态与项目变更一致。
   - `ProjectChangeCenter`：project-scoped 变更事件中心，统一广播 `filesChanged`、`checkpointRestored`、`renamed`、`descriptionChanged`、`toolPermissionChanged`、`modelSelectionChanged`；其中 `filesChanged` / `checkpointRestored` 同步维护 `updatedAt`。
   - `ProjectActivityStore`：project-scoped 活动状态源，维护 `idle / building / newVersionAvailable / needsConfirmation / error`，供 Home / Workspace / Chat 共享消费。
   - `ProjectCapabilityStore`：Per-Project 设备能力权限 CRUD（`project_capability` 表）。
   - `CapabilityActivityStore`：能力活动事件记录与查询（`capability_activity` 表，JOIN project 取项目名）。
   - `ProjectGitService`：项目级 Git 初始化、agent loop 前自动保存、检查点创建、历史恢复与 undo helper。
   - `ProjectArchiveImportService`：`.doufu` / `.doufull` 导入服务；负责 ZIP 安全解包、结构校验、创建新项目并落盘 `App/`、`AppData/`。
   - `ProjectArchiveExportService`：`.doufu` / `.doufull` 导出服务；负责按格式打包 `App/` 或 `App/ + AppData/`。
4. `Doufu/Core/Chat/`
   - `ChatSessionManager`：project-scoped ChatSession 注册表，允许 Workspace 关闭后会话在当前进程内继续执行。
   - `ChatSession`：项目级长生命周期聊天运行时，持有线程/消息状态、执行协调、pending tool confirmation continuation，并消费 `ProjectChangeCenter` 事件。
   - `ChatTaskCoordinator`：单次请求执行协调器；桥接 `ProjectChatOrchestrator`、`ActiveTaskManager`、`PiPProgressManager` 与 `ProjectActivityStore`。
   - `ChatDataStore`：`final class`，通过 GRDB `DatabasePool` 同步读写聊天数据（线程、消息、助理、会话记忆）。
   - `ChatDataService`：`@MainActor final class`，绑定单个 `projectID`，提供自动持久化。
   - `ChatSessionContext`：分离存储键（`projectID`）、工具执行路径（`workspaceURL` = App/）和 `projectRootURL`。
   - `ChatThreadManager`：线程生命周期管理（切换、创建、删除、重排序），通过 delegate 通知 ChatSession 加载消息/记忆。
   - `ChatModelSelectionManager`：消费 `ModelSelectionStateStore`、解析当前有效模型、生成 reasoning/thinking 运行时选项、管理凭证刷新。
   - `ChatDataModels`：聊天数据模型定义，含 `ModelSelection` 统一类型。
   - `SessionMemory`：会话记忆模型。
5. `Doufu/Core/LLM/`
   - `ProjectChatService`：聊天服务对外入口与数据模型定义。
   - `LLMModelRegistry`：统一模型能力解析（capabilities + token budgets）。
   - `ModelSelectionStateStore`：App / Project / Thread 三层模型选择的共享状态源、缓存与变更通知。
   - `ModelSelectionResolver`：三层 `ModelSelection` 解析、校验与归一化。
   - `OpenAIOAuthService`：OpenAI OAuth（PKCE + localhost 回调）。
   - `OpenRouterOAuthService`：OpenRouter OAuth（PKCE，返回 API Key）。
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
     - `ChatPipelineModels`：请求/响应共享模型（`ResponsesRequest`、`JSONValue` 等）
     - `OpenAIProvider` / `AnthropicProvider` / `GeminiProvider` / `OpenRouterProvider`：各 Provider 实现
     - `WebToolProvider`：Web 搜索与网页抓取
     - `CodeValidator`：隐藏 WKWebView 代码验证
     - `ProjectPathResolver`：项目路径安全解析
6. `Doufu/Features/Home/` + `Doufu/HomeViewController.swift`
   - 首页画廊与排序页，消费 `ProjectActivityStore` 展示项目状态标签。
7. `Doufu/Features/Chat/`
   - `ChatViewController`：聊天页 UI 布局与胶水代码（线程切换、输入处理、coordinator delegate 转发）。
   - `ChatMessageStore`：消息数组管理与 FlowState 状态机（idle / progress / streaming / tool），通过 delegate 回调驱动 UI。
   - `ChatMenuBuilder`：所有 UIMenu 构建（static 方法，无状态）。
   - `ChatMessage`：聊天消息模型。
   - `ChatMessageCell`：聊天消息气泡渲染。
   - `ChatToolMessageCell`：工具消息气泡渲染（展示 summary，点击展开详情）。
   - `MarkdownRenderer`：Markdown 渲染。
   - `ModelConfigurationViewController`：共享模型配置页（App / Project / Thread）。
   - `ThreadManagementViewController`：线程管理页。
   - `MessageDetailViewController`：消息详情页。
   - `ToolActivityDetailViewController`：工具活动详情页（结构化卡片展示工具调用结果）。
   - 聊天页负责在重新出现时恢复 pending tool confirmation 展示，并在 checkpoint restore 后与新的 thread 上下文对齐。
8. `Doufu/Features/ProjectRuntime/`
   - `ProjectWorkspaceViewController`：项目运行页与悬浮面板，订阅 `ProjectChangeCenter` 刷新预览，并仅在真正可见时消费 `newVersionAvailable`。
   - `ProjectFileBrowserViewController`：文件树浏览与内容编辑。
   - `ProjectSettingsViewController`：项目设置与 checkpoint history 入口，含能力权限 toggle 和活动记录入口。
   - `CapabilityToastView`：设备能力使用浮动提示（纯色胶囊，可拖动）。
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
   - `ToolPermissionPickerViewController`：工具权限选择器。
   - `CapabilityDetailViewController`：单项设备能力详情页。
   - `CapabilityActivityLogViewController`：能力活动记录页。
   - `SettingsPickerViewController`：通用选项选择器。
   - `SettingsSpecificationsViewController`：App 规格与第三方许可。
10. `Doufu/Features/Settings/Components/`
   - 设置风格复用 Cell 组件。
11. `Doufu/Core/`（其他）
    - `UIColor+Doufu`：自定义颜色扩展。
    - `WKWebView+Doufu`：WKWebView 扩展。
    - `LocalWebServer`：本地 Web 服务，含 CDN 资源代理缓存。
    - `Core/Media/MediaSessionManager`：WebRTC 摄像头/麦克风管理（per-VC 实例，非 singleton）。
    - `Core/Media/LoopbackSTUNServer`：本地 STUN 服务器（`127.0.0.1:random`），使 WebRTC ICE 在任何网络状态下通过 loopback srflx candidate 建立连接。
    - `DoufuBridge`：JS 桥接（注入策略、权限封堵、fetch 代理、localStorage shim、IndexedDB shim、doufu.db API、能力请求、WebRTC 信令）。
    - `ActiveTaskManager`：活跃任务追踪。
    - `PiPProgressManager`：画中画进度管理。

## 核心数据模型

### Domain 层

1. `AppProjectRecord`
   - `id`（纯 UUID，无前缀）, `name`, `projectURL`, `createdAt`, `updatedAt`
   - 计算属性：`appURL`（projectURL/App/）、`dataURL`（projectURL/AppData/）、`entryFileURL`（appURL/index.html）
2. `LLMProviderRecord`
   - `id`, `kind`, `authMode`, `label`, `baseURLString`, `autoAppendV1`, `chatGPTAccountID?`, `modelID?`, `models`
3. `LLMProviderModelRecord`
   - Provider 关联的模型记录，含 `source`（discovered / custom）和 `capabilities`。
4. `ResolvedModelProfile`
   - 统一的模型能力描述：`reasoningEfforts`, `thinkingSupported`, `thinkingCanDisable`, `structuredOutputSupported`, `maxOutputTokens`, `contextWindowTokens`。
5. `ModelSelection`
   - 统一的模型选择类型（providerID, modelRecordID, reasoningEffort?, thinkingEnabled?），App/Project/Thread 三层共用。

### DB 层（GRDB Record）

1. `DBProject` / `DBPermission`
   - 项目元数据与工具权限（UNIQUE FK CASCADE）。
1a. `DBProjectCapability` / `DBCapabilityActivity`
   - Per-Project 设备能力权限状态与活动记录（FK CASCADE：删除项目自动清理）。
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
   - `message.message_type`：0=system, 1=normal, 2=progress, 3=tool。
   - `message.token_usage_id` FK → `token_usage`。

## 本地存储约定

### SQLite 数据库

- 路径：`Documents/doufu.sqlite`（WAL 模式，外键 ON）
- 14 张表：`project`, `permission`, `project_capability`, `capability_activity`, `llm_provider`, `llm_provider_model`, `token_usage`, `app_model_selection`, `project_model_selection`, `thread_model_selection`, `thread`, `assistant`, `message`, `session_memory`
- 所有结构化数据（项目元数据、Provider 配置、模型选择、聊天线程/消息/记忆、token 用量）统一存储在 SQLite 中

### 项目磁盘结构（v4）

- 根目录：`Documents/Projects/{uuid}/`（projectID 为纯 UUID，无前缀）
- `App/`：代码文件（index.html, style.css, script.js, AGENTS.md, DOUFU.MD）+ `.git`
- `AppData/`：用户数据 — Git 检查点恢复时保留
  - `localStorage.json`：localStorage 数据
  - `indexedDB.sqlite`：IndexedDB 数据（sql.js WASM SQLite）
  - `{name}.sqlite`：`doufu.db` API 自定义数据库
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
   - 写入工具（`write_file`, `edit_file`, `revert_file`）顺序执行。
   - 危险工具（`delete_file`, `move_file`, `web_search`, `web_fetch`）需用户确认，顺序执行。
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
4. OpenRouter
   - 走 `/chat/completions`。
   - 支持 reasoning effort；映射消息格式到 OpenRouter 格式。
5. 聊天页按 Provider/Model 维度选择模型与参数：
   - `App / Project / Thread` 三层共享同一份 `ModelSelection(provider, model, reasoning, thinking)` 结构
   - OpenAI Compatible：`reasoning effort`
   - Anthropic/Gemini：`thinking` 开关

## OAuth 说明

1. OpenAI OAuth
   - `SFSafariViewController` + PKCE + `localhost:1455/auth/callback`。
   - 回调成功后自动填充 Base URL 和 Bearer Token。
2. OpenRouter OAuth
   - PKCE 流程，返回 API Key（非 Bearer Token）。
3. Anthropic / Gemini OAuth
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

## DoufuBridge 注入与 Shim 层

### 注入策略

1. **权限封堵脚本**：`forMainFrameOnly: false` — 所有 frame（含 iframe）都被封堵标准 Web API（getUserMedia, geolocation, clipboard, Permissions API 返回 denied）。
2. **Bridge 脚本**：`forMainFrameOnly: false` — 所有 frame 注入，由 JS 侧 origin 守卫决定是否初始化：
   - `location.protocol === 'file:' || location.hostname === 'localhost'` → 注入
   - 跨源 iframe（如 `https://example.com`）、`data:`/`blob:`/`about:blank` → 跳过
3. **Native 消息处理**：`DoufuBridgeMessageHandler` 对所有消息做 origin 校验（`host == "localhost" || protocol == "file"`），非本地来源直接忽略。

| Frame 类型 | 权限封堵 | 存储 shim | fetch proxy | doufu.* API | native 消息 |
|---|---|---|---|---|---|
| main frame | ✓ | ✓ | ✓ | ✓ | ✓ |
| same-origin iframe | ✓ | ✓（代理到 parent） | ✓ | ✓（已知限制） | ✓ |
| cross-origin iframe | ✓ | ✗ | ✗ | ✗ | ✗ |

> **已知限制**：same-origin iframe 中的 `doufu.*` capability 请求能发出并被 native 处理，但响应通过 `webView.evaluateJavaScript()` 交付到 main frame（WKWebView API 限制），因此 iframe 中的 Promise 不会 resolve。存储和 fetch 不受影响。

### fetch() 代理

1. 覆盖 `window.fetch` 和 `XMLHttpRequest.prototype.open`。
2. 跨源请求透明改写为 `/__doufu_proxy__?url=<encoded>`，由 `LocalWebServer` 代理。
3. 同源请求不代理，直接走原始 fetch/XHR。
4. 每个 frame 独立设置代理（非共享），保证每个 frame 的 `location.origin` 判断正确。

### localStorage 持久化 Shim

1. 使用 `Object.create(null)` 作为 `_data` 后备存储，避免 `toString`/`__proto__` 等原型链 key 冲突。
2. `Proxy` 覆盖 `window.localStorage`，支持 `getItem`/`setItem`/`removeItem`/`clear`/`key`/`length` 以及属性式访问（`localStorage.foo = 'bar'`、`delete localStorage.foo`、`for...in`、`Object.keys()`）。
3. 属性访问对不存在的 key 返回 `null`（与原生 Storage named getter 一致）。
4. 每次写入同步发送完整 `_data` 快照到 native（`doufuStorage` message handler），native 端原子替换 `storageData` 并写入 `AppData/localStorage.json`。
5. **iframe 共享**：same-origin iframe 通过 `Object.defineProperty(window, 'localStorage', { get: () => window.parent.localStorage })` 代理到 parent frame 的 shim 实例 — 单一 `_data`、单一 flush 路径。
6. **清除安全**：`clearLocalStorage()` 调用 JS 侧 `__doufuLocalStorageClear()`（清空 `_data` + 禁用 `_flush`），防止 beforeunload 等 handler 在页面卸载期间重新持久化旧数据。
7. **已知限制**：
   - 无 `storage` 事件（跨 frame StorageEvent 不触发）
   - `localStorage instanceof Storage` 返回 `false`

### IndexedDB 持久化 Shim（sql.js 后端）

1. **sql.js（WASM SQLite）** 在文档开始时加载（`sql-wasm.js` + `sql-wasm.wasm`），提供完整的内存 SQLite 引擎。
2. **API 覆盖面**：`IDBFactory`（open/deleteDatabase/databases/cmp）、`IDBDatabase`、`IDBTransaction`（SAVEPOINT 回滚）、`IDBObjectStore`（put/add/get/getKey/getAll/getAllKeys/delete/clear/count/createIndex/deleteIndex/openCursor/openKeyCursor）、`IDBIndex`（get/getKey/getAll/getAllKeys/count/openCursor/openKeyCursor）、`IDBCursor`（continue/advance/continuePrimaryKey/update/delete）、`IDBKeyRange`（only/lowerBound/upperBound/bound/includes）。
3. **SQLite Schema**：5 张表 — `databases`、`object_stores`、`indexes`、`records`（value 为 JSON）、`index_records`。
4. **Key 编码**：二进制编码（类型前缀 + 值），通过 SQLite BLOB 比较保持 IDB 规范排序（number < date < string < binary < array）。数字使用 IEEE 754 sign-flip 编码。
5. **Structured Clone**：支持 Date、ArrayBuffer、TypedArray（全 9 种）、DataView、Blob、File、Map、Set、RegExp、Error、ImageData、NaN、Infinity、-0、undefined。Blob/File 异步提取 ArrayBuffer 后转 base64 存储。循环引用检测并抛出 DataCloneError。
6. **持久化**：写事务提交后延迟 80ms HTTP PUT 到 `/__doufu_appdata__/indexedDB.sqlite`；beforeunload/pagehide 使用同步 XHR 确保写入。
7. **事务**：readwrite/versionchange 事务创建 SAVEPOINT，abort() 时 ROLLBACK，commit 时 RELEASE。自动提交：`_scheduleCommit` 检查 `!_holdAutoCommit && _pendingRequests === 0` 后调用 `_tryCommit()`（幂等）。
8. **async onupgradeneeded**：检测 `onupgradeneeded` / `addEventListener('upgradeneeded')` handler 返回的 thenable。async 路径通过 `_holdAutoCommit` 阻止 constructor setTimeout 和 `_scheduleCommit` 提前提交，`_awaitPending` 微任务轮询等待所有 IDBRequest 完成后 commit。多 thenable 聚合使用手动计数器 + settled 守卫。handler 同步 throw 被 try/catch 捕获后 abort + fail。
9. **大数据集分块**：`getAll`/`getAllKeys`/`openCursor`/`openKeyCursor` 对 >500 条结果使用 `_parseInChunks`（每 500 行 `setTimeout(0)` 让出主线程）。分块期间 `_pendingRequests > 0` 阻止事务提前提交。transform 异常由 errback 捕获后 `req._fail(DataError)`，避免事务挂死。
10. **iframe 共享**：same-origin iframe 代理 `window.indexedDB` + 9 个全局构造函数 + `doufu.db` 到 parent，跳过 sql.js WASM 加载。
11. **清除**：`clearIndexedDB()` 调用 JS 侧 `__doufuIDBCancelPersist()`（取消 flush timer + close db），然后删除 `AppData/indexedDB.sqlite`。
12. **JSON 迁移**：首次加载时若无 `.sqlite` 但存在 `.json`（旧格式），自动迁移为 SQLite 并持久化。
13. **已知限制**：
    - cursor 一次性快照所有匹配 record，迭代中新增的 record 不可见（符合 IDB spec 快照语义）
    - 无 `blocked` / `versionchange` 事件（单页面场景无影响）
    - `DOMStringList` / `Event` / `IDBFactory` 的 instanceof 检查失败（核心 IDB 类型如 IDBDatabase/IDBRequest/IDBTransaction 的 instanceof 正常）
    - Blob 与非 Blob 混合写入同一事务时可能产生排序问题（async/sync 混合）

### doufu.db 直接 SQL API

1. `doufu.db.open(name)` → 打开/创建命名数据库，返回 handle ID。
2. `doufu.db.exec(handle, sql)` / `doufu.db.run(handle, sql, params)` → 执行 SQL。
3. `doufu.db.close(handle)` → 关闭数据库。
4. 每个命名数据库独立持久化为 `AppData/{name}.sqlite`（HTTP PUT/GET）。
5. beforeunload 使用同步 XHR flush 所有打开的数据库。
6. 数据库名仅允许 `[a-zA-Z0-9_-]`。
