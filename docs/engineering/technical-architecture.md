# 技术架构说明

## 技术选型

1. UI：`UIKit`（主框架）
2. Web 运行：`WKWebView`
3. 本地存储：`FileManager` + JSON
4. 并发：`Swift Concurrency`
5. 凭证：`Keychain`
6. 代码编辑：`Runestone`（可用时）+ Tree-sitter 语言包
7. 版本控制：`SwiftGitX`（项目级 Git 检查点与 undo）

## 架构原则

1. ViewController 聚焦 UI 和交互，核心逻辑下沉到 Service/Store。
2. 项目、Provider、聊天管线、统计分别独立模块。
3. 数据本地优先，默认不依赖云端项目存储。
4. 移动端优先（iPhone 竖屏、Safe Area、触控友好）。

## 关键目录映射

1. `Doufu/App/`
   - App 生命周期与根导航。
2. `Doufu/Core/Projects/`
   - `AppProjectStore`：项目创建、删除、改名、快照创建与恢复、模板写入。
   - `ProjectGitService`：项目级 Git 初始化、检查点创建与 undo。
3. `Doufu/Core/LLM/`
   - `ProjectChatService`：聊天服务对外入口与数据模型定义。
   - `LLMModelRegistry`：统一模型能力解析（capabilities + token budgets）。
   - `ProjectModelSelectionStore`：项目级/线程级模型选择持久化。
   - `OpenAIOAuthService`：OpenAI OAuth（PKCE + localhost 回调）。
   - `LLMProviderSettingsStore`：Provider 元数据与 Keychain 凭证管理。
   - `LLMProviderModelDiscoveryService`：Provider 模型列表发现。
   - `ProjectChatThreadStore`：会话线程、消息、thread memory 文件持久化。
   - `LLMTokenUsageStore`：token 使用量聚合与按日统计。
   - `ChatPipeline/*`：
     - `ProjectChatOrchestrator`：Agent 循环主控制器
     - `ProjectChatConfiguration`：Agent 配置参数
     - `AgentTools`：工具定义、权限模型、进度事件
     - `PromptBuilder`：系统提示词与用户消息构建
     - `SessionMemoryManager`：会话记忆管理
     - `LLMStreamingClient`：流式请求客户端
     - `ChatPipelineModels`：管线内部数据模型
     - `ToolUseRequestModels`：工具调用请求/响应模型
     - `LLMProviderProtocol`：Provider 请求适配协议
     - `OpenAIProvider` / `AnthropicProvider` / `GeminiProvider`：各 Provider 实现
     - `WebToolProvider`：Web 搜索与网页抓取
     - `CodeValidator`：隐藏 WKWebView 代码验证
     - `ProjectPathResolver`：项目路径安全解析
4. `Doufu/Features/Home/` + `Doufu/HomeViewController.swift`
   - 首页画廊与排序页。
5. `Doufu/Features/ProjectRuntime/`
   - `ProjectWorkspaceViewController`：项目运行页与悬浮面板。
   - `ProjectChatViewController`：聊天页、线程切换、模型参数配置、项目 token usage。
   - `ProjectModelConfigurationViewController`：项目内模型配置。
   - `ProjectTokenUsageViewController`：项目级 token 使用量。
   - `ProjectFileBrowserViewController`：文件树浏览与内容编辑。
   - `ProjectSettingsViewController`：项目设置与快照入口。
   - `ChatMessageCell`：聊天消息气泡渲染。
   - `MarkdownRenderer`：Markdown 渲染。
   - `ProjectOpenTransition`：项目打开转场动画。
6. `Doufu/Features/Settings/`
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
7. `Doufu/Features/Settings/Components/`
   - 设置风格复用 Cell 组件。
8. `Doufu/Core/`
   - `UIColor+Doufu`：自定义颜色扩展。
   - `LocalWebServer`：本地 Web 服务。
   - `DoufuBridge`：JS 桥接。
   - `PiPProgressManager`：画中画进度管理。

## 核心数据模型

1. `AppProjectRecord`
   - `id`, `name`, `projectURL`, `entryFileURL`, `createdAt`, `updatedAt`
2. `LLMProviderRecord`
   - `id`, `kind`, `authMode`, `label`, `baseURLString`, `autoAppendV1`, `modelID`, `chatGPTAccountID`
3. `LLMProviderModelRecord`
   - Provider 关联的模型记录，含 `source`（discovered / custom）和 `capabilities`。
4. `ResolvedModelProfile`
   - 统一的模型能力描述：`reasoningEfforts`, `thinkingSupported`, `thinkingCanDisable`, `structuredOutputSupported`, `maxOutputTokens`, `contextWindowTokens`。
5. `ProjectModelSelection` / `ThreadModelSelection`
   - 项目级/线程级模型选择与参数偏好。
6. `ProjectChatThreadRecord` / `ProjectChatThreadIndex`
   - 线程元数据与当前线程指针。
7. `ProjectChatPersistedMessage`
   - role/text/timestamps/progress 标记 + 请求 token 用量 + 工具活动摘要。
8. `LLMTokenUsageRecord` / `LLMTokenUsageDailyRecord`
   - 按 provider/model/project/day 维度统计输入输出 token。

## 本地存储约定

1. 项目根目录：`Documents/AppProjects/{projectId}/`
2. 项目文件：
   - `index.html`, `style.css`, `script.js`, `manifest.json`, `AGENTS.md`, `DOUFU.MD`
3. 会话与线程：
   - `.doufu_threads_index.json`
   - `.doufu_thread_messages_{threadID}.json`
   - `thread_memory_{threadID}_{version}.md`
4. 模型选择：
   - `.doufu_project_config.json`（项目级模型选择）
   - `.doufu_thread_selections.json`（线程级模型选择与参数）
5. 快照：
   - `{project}/.doufu_snapshots/manual/*`
   - `{project}/.doufu_snapshots/auto/*`
6. Git：
   - `{project}/.git/`（由 `ProjectGitService` 管理）
7. 预览图：
   - `preview.jpg`（运行页截图写入）
8. Provider 元数据：
   - `UserDefaults`：`llm.providers.records.v1`
9. Token Usage 聚合：
   - `UserDefaults`：`llm.token_usage.records.v1`、`llm.token_usage.daily_records.v1`
10. 凭证：
    - `Keychain`：API Key / OAuth Bearer Token

## Agent 聊天执行链路（当前实现）

1. 入口
   - `ProjectChatService` 构建 `ProviderCredential`（含 `ResolvedModelProfile`）。
   - `ProjectChatOrchestrator.sendAndApply()` 启动 agent loop。
2. 准备阶段
   - 读取 `AGENTS.md` 和 `DOUFU.MD` 作为额外上下文。
   - 构建系统提示词（含工具说明、安全约束、memory 格式）。
   - 将历史对话与工具活动摘要组装为 conversation items。
   - 创建 Git 检查点。
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
8. 失败与回退
   - SSE 与非 SSE 响应都做失败解析。
   - `xhigh` 被拒时回退到 `high`。
   - `json_schema` 被拒时回退为普通文本模式重试。
   - 取消信号可透传整个链路。

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
