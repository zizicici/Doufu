# 模块设计

## 模块总览

1. `Home`
   - 主要文件：`HomeViewController.swift`、`Features/Home/ProjectSortViewController.swift`
   - 责任：项目卡片画廊、搜索、长按菜单、排序与新建入口。
2. `Project Runtime`
   - 主要文件：`Features/ProjectRuntime/ProjectWorkspaceViewController.swift`
   - 责任：网页运行、悬浮面板、退出确认、运行时快捷入口、LLM 设置检测与快速设置引导。
3. `Project Chat`
   - 主要文件：
     - `Features/ProjectRuntime/ProjectChatViewController.swift`：UI 布局、View 生命周期、UITableViewDataSource、输入处理、线程管理协调、ChatTaskCoordinatorDelegate 转发。
     - `Features/ProjectRuntime/ChatMessageStore.swift`：消息数组管理、FlowState 状态机（idle / progress / streaming 三态）、追加/finalize/streaming 生命周期、持久化。
     - `Features/ProjectRuntime/ChatModelSelectionManager.swift`：Provider/Model 切换、reasoning/thinking 设置、per-thread 选择存取、运行时凭证解析。
     - `Features/ProjectRuntime/ChatMenuBuilder.swift`：所有 UIMenu 构建（thread / more / model），纯 static 方法，不持有状态。
   - 责任：聊天消息流、线程管理、模型配置、进度展示、取消请求、extended thinking 展示、工具活动摘要展示。
   - 消息流状态机：`ChatMessageStore.FlowState` 保证任务执行期间恰好有一条消息处于 live 状态（`finishedAt == nil`），streaming 与 progress 消息通过原子状态转换交替出现。
4. `Project Model Configuration`
   - 主要文件：`Features/ProjectRuntime/ProjectModelConfigurationViewController.swift`
   - 责任：项目内模型选择与参数配置（reasoning effort / thinking 开关）。
5. `Project File Browser`
   - 主要文件：`Features/ProjectRuntime/ProjectFileBrowserViewController.swift`
   - 责任：项目文件树浏览、文件编辑与保存（Runestone 优先）。
6. `Project Settings`
   - 主要文件：`Features/ProjectRuntime/ProjectSettingsViewController.swift`
   - 责任：项目名修改、快照保存、快照恢复入口。
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
    - 责任：全局默认模型选择（Provider → Model 两步选择）。
11. `LLM Quick Setup`
    - 主要文件：`Features/Settings/LLMQuickSetupViewController.swift`
    - 责任：首次使用聊天时的快速配置引导（添加 Provider → 选择默认模型）。
12. `Settings Picker`
    - 主要文件：`Features/Settings/SettingsPickerViewController.swift`
    - 责任：通用选项选择器，替代各功能专用 Picker。
13. `Project Storage`
    - 主要文件：`Core/Projects/AppProjectStore.swift`
    - 责任：项目生命周期、模板写入、manifest 更新时间、快照管理。
14. `Project Git Service`
    - 主要文件：`Core/Projects/ProjectGitService.swift`
    - 责任：项目级 Git 初始化、检查点创建（agent loop 前）、undo 回退、变更查询。
15. `Provider Storage`
    - 主要文件：`Core/LLM/LLMProviderSettingsStore.swift`
    - 责任：Provider 元数据持久化、模型记录管理、Keychain 凭证增删改查。
16. `Model Registry`
    - 主要文件：`Core/LLM/LLMModelRegistry.swift`
    - 责任：统一模型能力解析，多级优先级回退（用户自定义 > 内置 > 发现 > 保守默认）。
17. `Model Selection Store`
    - 主要文件：`Core/LLM/ProjectModelSelectionStore.swift`
    - 责任：项目级/线程级模型选择与参数偏好持久化。
18. `OAuth Service`
    - 主要文件：`Core/LLM/OpenAIOAuthService.swift`
    - 责任：OpenAI OAuth 流程（授权 URL、callback、token 交换、结果回传）。
19. `Chat Thread Store`
    - 主要文件：`Core/LLM/ProjectChatThreadStore.swift`
    - 责任：线程索引、线程消息、thread memory 文件版本化。
20. `Agent Chat Pipeline`
    - 主要文件：`Core/LLM/ProjectChatService.swift` + `Core/LLM/ChatPipeline/*`
    - 责任：对外 `sendAndApply`、agent loop 控制、工具定义与执行、流式请求、上下文压缩、进度事件。
21. `Token Usage Analytics`
    - 主要文件：`Core/LLM/LLMTokenUsageStore.swift`、`Features/Settings/TokenUsageViewController.swift`、`Features/ProjectRuntime/ProjectTokenUsageViewController.swift`
    - 责任：按项目/Provider/Model/天聚合 token，并驱动全局与项目视角展示。

## 通信方式

1. UI 到业务：ViewController 直接调用 Service/Store。
2. 模块间协作：通过结构化模型（如 `LLMProviderRecord`、`ResolvedModelProfile`、`ProjectChatThreadRecord`）。
3. 页面刷新：主要通过闭包回调传递事件（项目文件更新、设置更新、排序更新）。

## 关键流程

1. 新建项目
   - `HomeViewController` 调用 `AppProjectStore.createBlankProject()`
   - 创建模板文件、初始化 Git 仓库并 push 到 `ProjectWorkspaceViewController`
2. Agent 聊天改项目
   - `ProjectChatViewController` 构建 `ProviderCredential`（含 `ResolvedModelProfile`）
   - 调用 `ProjectChatOrchestrator.sendAndApply()` 启动 agent loop
   - Agent 自主调用工具（读文件 → 分析 → 编辑/写入 → 验证）
   - 只读工具并行执行，写入工具顺序执行
   - 改动成功后刷新运行页并创建 `auto` 快照
3. 工具权限与确认
   - 工具按危险程度分级（autoAllow / confirmOnce / alwaysConfirm）
   - `ToolConfirmationHandler` 协议由 ChatViewController 实现
   - 用户可在设置中选择权限模式
4. 线程与 memory 持久化
   - 线程索引：`.doufu_threads_index.json`
   - 消息：`.doufu_thread_messages_{threadID}.json`
   - 记忆：`thread_memory_{threadID}_{version}.md`
   - `thread_should_rollover=true` 时自动创建新版本 memory 文件
5. 模型选择持久化
   - 项目级：`.doufu_project_config.json` 存 `providerID + modelRecordID`
   - 线程级：`.doufu_thread_selections.json` 存每线程 provider/model/reasoning/thinking 偏好
6. Git 检查点与 undo
   - Agent loop 开始前 `ProjectGitService.createCheckpoint()` 提交当前状态
   - `ProjectGitService.undo()` 可回退到最近检查点
7. 快照恢复
   - `ProjectSettingsViewController` 或聊天自动链路触发快照
   - `AppProjectStore.restoreSnapshot()` 覆盖恢复并更新时间
8. Provider 配置
   - `AddProviderViewController` 选择 Provider 类型
   - `ProviderAuthMethodViewController` 选择 API Key / OAuth
   - 表单提交后写入 `LLMProviderSettingsStore`（元数据+凭证）
9. Token Usage 统计
   - `LLMStreamingClient` 在请求完成后记录 token 用量
   - `UsageAccumulator` actor 线程安全聚合多轮 token
   - Dashboard 支持 Provider/Model 维度切换与项目隔离视图
