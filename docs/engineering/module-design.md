# 模块设计

## 模块总览

1. `Home`
   - 主要文件：`HomeViewController.swift`、`Features/Home/ProjectSortViewController.swift`
   - 责任：项目卡片画廊、搜索、长按菜单、排序与新建入口。
2. `Project Runtime`
   - 主要文件：`Features/ProjectRuntime/ProjectWorkspaceViewController.swift`
   - 责任：网页运行、悬浮面板、退出确认、运行时快捷入口。
3. `Project Chat`
   - 主要文件：`Features/ProjectRuntime/ProjectChatViewController.swift`
   - 责任：聊天消息流、线程管理、模型配置、进度展示、取消请求。
4. `Project File Browser`
   - 主要文件：`Features/ProjectRuntime/ProjectFileBrowserViewController.swift`
   - 责任：项目文件树浏览、文件编辑与保存（Runestone 优先）。
5. `Project Settings`
   - 主要文件：`Features/ProjectRuntime/ProjectSettingsViewController.swift`
   - 责任：项目名修改、快照保存、快照恢复入口。
6. `Global Settings & Providers`
   - 主要文件：`Features/Settings/*`
   - 责任：Manage Providers、Add Provider、认证方式分流（API Key/OAuth）。
7. `Project Storage`
   - 主要文件：`Core/Projects/AppProjectStore.swift`
   - 责任：项目生命周期、模板写入、manifest 更新时间、快照管理。
8. `Provider Storage`
   - 主要文件：`Core/LLM/LLMProviderSettingsStore.swift`
   - 责任：Provider 元数据持久化、Keychain 凭证增删改查。
9. `OAuth Service`
   - 主要文件：`Core/LLM/OpenAIOAuthService.swift`
   - 责任：OpenAI OAuth 流程（授权 URL、callback、token 交换、结果回传）。
10. `Chat Thread Store`
    - 主要文件：`Core/LLM/ProjectChatThreadStore.swift`
    - 责任：线程索引、线程消息、thread memory 文件版本化。
11. `Project Chat Pipeline`
    - 主要文件：`Core/LLM/ProjectChatService.swift` + `Core/LLM/ChatPipeline/*`
    - 责任：对外 `sendAndApply`、执行路由、文件检索、补丁生成与安全落盘。
12. `Token Usage Analytics`
    - 主要文件：`Core/LLM/LLMTokenUsageStore.swift`、`Features/Settings/TokenUsageViewController.swift`
    - 责任：按项目/Provider/Model/天聚合 token，并驱动全局与项目视角展示。

## 通信方式

1. UI 到业务：ViewController 直接调用 Service/Store。
2. 模块间协作：通过结构化模型（如 `LLMProviderRecord`、`ProjectChatThreadRecord`）。
3. 页面刷新：主要通过闭包回调传递事件（项目文件更新、设置更新、排序更新）。

## 关键流程

1. 新建项目
   - `HomeViewController` 调用 `AppProjectStore.createBlankProject()`
   - 创建模板文件并 push 到 `ProjectWorkspaceViewController`
2. 聊天改项目
   - `ProjectChatViewController` 收集上下文并调用 `ProjectChatService.sendAndApply()`
   - 管线按 `direct_answer/single_pass/multi_task` 执行
   - 改动成功后刷新运行页并创建 `auto` 快照
3. 线程与 memory 持久化
   - 线程索引：`.doufu_threads_index.json`
   - 消息：`.doufu_thread_messages_{threadID}.json`
   - 记忆：`thread_memory_{threadID}_{version}.md`
   - `thread_should_rollover=true` 时自动创建新版本 memory 文件
4. 快照恢复
   - `ProjectSettingsViewController` 或聊天自动链路触发快照
   - `AppProjectStore.restoreSnapshot()` 覆盖恢复并更新时间
5. Provider 配置
   - `AddProviderViewController` 选择 Provider 类型
   - `OpenAIProviderAuthMethodViewController` 选择 API Key / OAuth
   - 表单提交后写入 `LLMProviderSettingsStore`（元数据+凭证）
6. Token Usage 统计
   - `LLMStreamingClient` 在请求完成后记录 token 用量
   - Dashboard 支持 Provider/Model 维度切换与项目隔离视图
