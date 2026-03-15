# 模块设计

## 模块总览

1. `Home`
   - 主要文件：`HomeViewController.swift`、`Features/Home/ProjectSortViewController.swift`
   - 责任：项目卡片画廊、搜索、长按菜单、排序与新建入口；消费 `ProjectActivityStore` 展示 `正在建造中 / 新版本 / 需要确认 / 出错了` 标签，并在 `需要确认 / 出错了` 时直接路由进聊天页。
2. `Project Runtime`
   - 主要文件：`Features/ProjectRuntime/ProjectWorkspaceViewController.swift`、`Core/Media/MediaSessionManager.swift`、`Core/Media/LoopbackSTUNServer.swift`
   - 责任：网页运行、悬浮面板、退出确认、运行时快捷入口、Chat 入口的 App 默认模型检查、`LLMQuickSetup` / `Read Only` 分流、LLM 设置检测与快速设置引导、WebRTC Camera/Mic loopback 媒体管理（含本地 STUN 服务）。
3. `Project Chat`
   - 主要文件：
     - `Features/Chat/ChatViewController.swift`：UI 布局、View 生命周期、UITableViewDataSource、输入处理、线程管理协调、ChatTaskCoordinatorDelegate 转发。
     - `Features/Chat/ChatMessageStore.swift`：消息数组管理、FlowState 状态机（idle / progress / streaming / tool 四态）、追加/finalize/streaming 生命周期、持久化。
     - `Features/Chat/ChatMenuBuilder.swift`：所有 UIMenu 构建（thread / more / model），纯 static 方法，不持有状态。
     - `Features/Chat/ChatMessage.swift`：聊天消息模型。
     - `Features/Chat/ChatMessageCell.swift`：聊天消息气泡渲染。
     - `Features/Chat/ChatToolMessageCell.swift`：工具消息气泡渲染（展示 summary，点击展开详情）。
     - `Features/Chat/MarkdownRenderer.swift`：Markdown 渲染。
     - `Features/Chat/MessageDetailViewController.swift`：消息详情页。
     - `Features/Chat/ToolActivityDetailViewController.swift`：工具活动详情页（结构化卡片展示工具调用结果）。
     - `Features/Chat/ThreadManagementViewController.swift`：线程管理页。
   - 责任：聊天消息流、线程管理、模型配置、进度展示、取消请求、extended thinking 展示、工具活动摘要展示，以及 pending tool confirmation 的挂起恢复。
   - 消息流状态机：`ChatMessageStore.FlowState` 保证任务执行期间恰好有一条消息处于 live 状态（`finishedAt == nil`），streaming 与 progress 消息通过原子状态转换交替出现。
4. `Project Model Configuration`
   - 主要文件：`Features/Chat/ModelConfigurationViewController.swift`、`Features/ProjectRuntime/ProjectModelSelectionViewController.swift`
   - 责任：Project / Thread 模型配置、继承态展示、invalid selection 显式修复入口。
5. `Project File Browser`
   - 主要文件：`Features/ProjectRuntime/ProjectFileBrowserViewController.swift`
   - 责任：项目文件树浏览、文件编辑与保存（Runestone 优先）。
6. `Project Settings`
   - 主要文件：`Features/ProjectRuntime/ProjectSettingsViewController.swift`
   - 责任：项目名/描述修改、项目级模型与工具权限配置、Git checkpoint 历史入口、设备能力权限 toggle、能力活动记录入口。
7. `Global Settings`
   - 主要文件：`Features/Settings/SettingsViewController.swift`
   - 责任：全局设置页，分 General / LLM Providers / Project 三组。
8. `Provider Management`
   - 主要文件：`Features/Settings/ManageProvidersViewController.swift`、`AddProviderViewController.swift`、`ProviderAuthMethodViewController.swift`、`ProviderAPIKeyFormViewController.swift`、`ProviderOAuthFormViewController.swift`
   - 责任：Provider 列表管理、新增 Provider、认证方式分流（API Key / OAuth）。
9. `Provider Model Management`
   - 主要文件：`Features/Settings/ProviderModelEditorViewController.swift`、`ProviderModelManagementCoordinator.swift`
   - 责任：Provider 关联模型的发现、自定义、能力参数编辑。
10. `Default Model Selection`
    - 主要文件：`Features/Settings/DefaultModelSelectionViewController.swift`
    - 责任：全局默认模型选择（Provider / Model / reasoning / thinking）。
11. `LLM Quick Setup`
    - 主要文件：`Features/Settings/LLMQuickSetupViewController.swift`
    - 责任：首次使用聊天时的快速配置引导（添加 Provider → 选择默认模型）。
12. `Settings Picker`
    - 主要文件：`Features/Settings/SettingsPickerViewController.swift`
    - 责任：通用选项选择器，替代各功能专用 Picker。
13a. `Capability Detail`
    - 主要文件：`Features/Settings/CapabilityDetailViewController.swift`
    - 责任：单项设备能力详情页（系统权限状态 + Per-Project toggle + 活动记录入口）。
13b. `Capability Activity Log`
    - 主要文件：`Features/Settings/CapabilityActivityLogViewController.swift`、`CapabilityActivityLogTypes.swift`
    - 责任：能力活动记录页（DiffableDataSource，按日期分组，支持按项目 `.project(id:)` 或按能力类型 `.capability(type:)` 过滤）。
14. `Database`
    - 主要文件：`Core/Database/DatabaseManager.swift`、`DatabaseRecords.swift`、`DatabaseTimestamp.swift`
    - 责任：SQLite 数据库初始化与迁移（`v1_initial_schema` + `v2_add_indexes` + `v3_project_capabilities` + `v4_capability_activity`）、索引优化、GRDB Record 类型定义、domain ↔ DB 映射。
15. `Project Storage`
    - 主要文件：`Core/Projects/AppProjectStore.swift`
    - 责任：项目元数据 CRUD（GRDB `project` + `permission` 表）、模板写入、权限读写。
15a. `Capability Activity Store`
    - 主要文件：`Core/Projects/CapabilityActivityStore.swift`
    - 责任：能力活动事件写入 `capability_activity` 表（`recordEvent`），支持按项目或按能力类型查询（JOIN project 取项目名）。
15. `Project Lifecycle Coordinator`
   - 主要文件：`Core/Projects/ProjectLifecycleCoordinator.swift`
   - 责任：项目生命周期操作（create / delete / close / rename）的统一入口；确保 ChatSession 状态与项目变更一致（delete 前 cancel + flush + endSession；rename 同步 session context；close 时按执行状态决定是否 endSession）。
16. `Project Change Center`
   - 主要文件：`Core/Projects/ProjectChangeCenter.swift`
   - 责任：project-scoped 变更事件中心；统一广播文件改动、checkpoint restore、rename、description/tool permission/model selection 变化，并在文件/restore 事件里统一维护 `updatedAt`。
17. `Project Activity Store`
   - 主要文件：`Core/Projects/ProjectActivityStore.swift`
   - 责任：project-scoped 活动状态源；维护 `idle / building / newVersionAvailable / needsConfirmation / error`，供 Home / Workspace / Chat 共享消费。
18. `Project Git Service`
   - 主要文件：`Core/Projects/ProjectGitService.swift`
   - 责任：项目级 Git 初始化、agent loop 前自动保存、检查点创建、历史恢复、变更查询。
19. `Provider Storage`
   - 主要文件：`Core/LLM/LLMProviderSettingsStore.swift`
   - 责任：Provider / Model CRUD 通过 GRDB（`llm_provider` + `llm_provider_model` 表）、Keychain 凭证管理、三层 ModelSelection CRUD。
20. `Model Registry`
   - 主要文件：`Core/LLM/LLMModelRegistry.swift`
   - 责任：统一模型能力解析，多级优先级回退（用户自定义 > 内置 > 发现 > 保守默认）。
21. `Model Selection Store`
   - 主要文件：`Core/LLM/ModelSelectionStateStore.swift`、`Core/LLM/ModelSelectionResolver.swift`
   - 责任：App / Project / Thread 三层 `ModelSelection` 的共享状态源、缓存、变更通知、解析与归一化。从 `LLMProviderSettingsStore` 读取数据（不再依赖 `ChatDataService`）。
22. `Chat Data Storage`
   - 主要文件：`Core/Chat/ChatDataStore.swift`、`Core/Chat/ChatDataService.swift`、`Core/Chat/ChatSessionContext.swift`
   - 责任：`ChatDataStore`（`final class`）通过 GRDB 同步读写聊天数据；`ChatDataService`（`@MainActor`）绑定单个 projectID 提供自动持久化。
23. `OAuth Service`
   - 主要文件：`Core/LLM/OpenAIOAuthService.swift`、`Core/LLM/OpenRouterOAuthService.swift`
   - 责任：OpenAI OAuth（PKCE + localhost 回调，返回 Bearer Token）；OpenRouter OAuth（PKCE，返回 API Key）。
24. `Agent Chat Pipeline`
   - 主要文件：`Core/LLM/ProjectChatService.swift` + `Core/LLM/ChatPipeline/*`
   - 责任：对外 `sendAndApply`、agent loop 控制、工具定义与执行、流式请求、上下文压缩、进度事件。
25. `Token Usage Analytics`
   - 主要文件：`Core/LLM/LLMTokenUsageStore.swift`、`Features/Settings/TokenUsageViewController.swift`、`Features/ProjectRuntime/ProjectTokenUsageViewController.swift`
   - 责任：token 用量写入 `token_usage` 表，SQL GROUP BY / SUM 查询，驱动全局与项目视角展示。

## 通信方式

1. UI 到业务：ViewController 通过 `ProjectLifecycleCoordinator` 执行项目生命周期操作（create / delete / close / rename），其余 project mutation 调用直接到对应 Service/Store，再统一广播到 `ProjectChangeCenter`。
2. 模块间协作：通过结构化模型（如 `LLMProviderRecord`、`ResolvedModelProfile`）。
3. 页面刷新：项目变更统一通过 `ProjectChangeCenter` 广播；模型选择状态通过 `ModelSelectionStateStore` 广播；项目执行状态通过 `ProjectActivityStore` 广播。

## 关键流程

1. 新建项目
   - `HomeViewController` 调用 `ProjectLifecycleCoordinator.createProject()`
   - Coordinator 委托 `AppProjectStore.createBlankProject()` 完成 DB 插入、磁盘目录创建与模板文件、Git 仓库初始化
   - push 到 `ProjectWorkspaceViewController`
2. Agent 聊天改项目
   - `ChatViewController` 构建 `ProviderCredential`（含 `ResolvedModelProfile`）
   - 调用 `ProjectChatOrchestrator.sendAndApply()` 启动 agent loop
   - Agent 自主调用工具（读文件 → 分析 → 编辑/写入 → 验证）
   - 只读工具并行执行，写入工具顺序执行
   - `ChatTaskCoordinator` 驱动 `ProjectActivityStore` 进入 `building / newVersionAvailable / error / idle`
   - 改动成功后由 `ChatSession` 广播 `filesChanged`，刷新运行页、更新时间，并创建 Git checkpoint
3. 工具权限与确认
   - 工具按危险程度分级（autoAllow / confirmOnce / alwaysConfirm）
   - `ToolConfirmationPresenter` 协议由 ChatViewController 实现
   - 用户可在设置中选择权限模式
   - 当聊天 UI 暂时不可用时，确认会被挂起为 `needsConfirmation`，用户回到聊天页后继续同一次确认
4. 项目变更传播
   - 手动保存文件、checkpoint restore、rename、description 变更、工具权限变化、项目默认模型变化、agent 改文件都统一广播到 `ProjectChangeCenter`
   - `HomeViewController`、`ProjectWorkspaceViewController`、`ChatSession` 订阅同一事件流，不再依赖跨 VC 闭包链路
   - `checkpointRestored` 会触发运行页 reload，并让活跃聊天会话自动开启新 thread
5. 聊天数据持久化（SQLite）
   - 线程、消息、助理、会话记忆均存储在 SQLite 表中
   - `ChatDataStore` 同步读写，`ChatDataService` 绑定 projectID 提供自动持久化
   - `ChatMessageStore` 通过 `mutationDelegate` 自动持久化（无需手动调用）
   - CASCADE 删除：删除线程 → 自动清除关联数据
6. 模型选择持久化（SQLite）
   - App 级：`app_model_selection` 表
   - 项目级：`project_model_selection` 表
   - 线程级：`thread_model_selection` 表
   - `LLMProviderSettingsStore` 统一 CRUD
   - 运行时 UI 通过 `ModelSelectionStateStore` 读取和订阅
7. Git 检查点与恢复
   - Agent loop 开始前 `ProjectGitService.ensureRepository()` + `autoSaveIfDirty()` 保存当前工作区状态
   - Agent loop 结束后若实际改动文件，再通过 `createCheckpoint()` 记录检查点
   - `ProjectSettingsViewController` 提供 checkpoint history 恢复入口
   - 恢复后统一发出 `checkpointRestored`，运行页刷新；若聊天会话仍活跃，则切到新的 thread 与恢复后的代码状态对齐
8. Provider 配置
   - `AddProviderViewController` 选择 Provider 类型
   - `ProviderAuthMethodViewController` 选择 API Key / OAuth
   - 表单提交后写入 `LLMProviderSettingsStore`（GRDB 元数据 + Keychain 凭证）
9. Token Usage 统计
   - `LLMTokenUsageStore.recordUsage()` 每次 LLM 请求插入一行到 `token_usage` 表
   - `providerLabel` 通过 SQL JOIN 解析，不在写入时传入
   - Dashboard 使用 GROUP BY / SUM 查询，支持 Provider/Model 维度切换与项目隔离视图
