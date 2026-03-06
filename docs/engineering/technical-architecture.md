# 技术架构说明

## 技术选型

1. UI：`UIKit`（主框架）
2. Web 运行：`WKWebView`
3. 本地存储：`FileManager` + JSON
4. 并发：`Swift Concurrency`
5. 凭证：`Keychain`
6. 代码编辑：`Runestone`（可用时）+ Tree-sitter 语言包

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
3. `Doufu/Core/LLM/`
   - `ProjectChatService`：聊天服务对外入口。
   - `OpenAIOAuthService`：OpenAI OAuth（PKCE + localhost 回调）。
   - `LLMProviderSettingsStore`：Provider 元数据与 Keychain 凭证管理。
   - `ProjectChatThreadStore`：会话线程、消息、thread memory 文件持久化。
   - `LLMTokenUsageStore`：token 使用量聚合与按日统计。
   - `ChatPipeline/*`：
     - `ProjectChatOrchestrator`
     - `ProjectFileScanner`
     - `SessionMemoryManager`
     - `PromptBuilder`
     - `LLMStreamingClient`
     - `PatchApplicator`
4. `Doufu/Features/Home/` + `Doufu/HomeViewController.swift`
   - 首页画廊与排序页。
5. `Doufu/Features/ProjectRuntime/`
   - `ProjectWorkspaceViewController`：项目运行页与悬浮面板。
   - `ProjectChatViewController`：聊天页、线程切换、模型参数配置、项目 token usage。
   - `ProjectFileBrowserViewController`：文件树浏览与内容编辑。
   - `ProjectSettingsViewController`：项目设置与快照入口。
6. `Doufu/Features/Settings/`
   - 全局设置、Provider 管理、Add Provider、全局 token usage。
7. `Doufu/Features/Settings/Components/`
   - 设置风格复用 Cell 组件。

## 核心数据模型

1. `AppProjectRecord`
   - `id`, `name`, `projectURL`, `entryFileURL`, `createdAt`, `updatedAt`
2. `LLMProviderRecord`
   - `id`, `kind`, `authMode`, `label`, `baseURLString`, `autoAppendV1`, `modelID`, `chatGPTAccountID`
3. `ProjectChatThreadRecord` / `ProjectChatThreadIndex`
   - 线程元数据与当前线程指针。
4. `ProjectChatPersistedMessage`
   - role/text/timestamps/progress 标记 + 请求 token 用量。
5. `LLMTokenUsageRecord` / `LLMTokenUsageDailyRecord`
   - 按 provider/model/project/day 维度统计输入输出 token。

## 本地存储约定

1. 项目根目录：`Documents/AppProjects/{projectId}/`
2. 项目文件：
   - `index.html`, `style.css`, `script.js`, `manifest.json`, `AGENTS.md`, `DOUFU.MD`
3. 会话与线程：
   - `.doufu_threads_index.json`
   - `.doufu_thread_messages_{threadID}.json`
   - `thread_memory_{threadID}_{version}.md`
4. 快照：
   - `{project}/.doufu_snapshots/manual/*`
   - `{project}/.doufu_snapshots/auto/*`
5. 预览图：
   - `preview.jpg`（运行页截图写入）
6. Provider 元数据：
   - `UserDefaults`：`llm.providers.records.v1`
7. Token Usage 聚合：
   - `UserDefaults`：`llm.token_usage.records.v1`、`llm.token_usage.daily_records.v1`
8. 凭证：
   - `Keychain`：API Key / OAuth Bearer Token

## 聊天执行链路（当前实现）

1. 路由阶段（`dispatch_or_answer`）
   - 模型先判断走 `direct_answer`、`single_pass` 或 `multi_task`。
2. `direct_answer`
   - 直接回答问题，不进入文件检索与补丁应用流程。
3. `single_pass`
   - 扫描文件候选后一次性生成补丁并应用。
4. `multi_task`
   - `plan_tasks` 规划子任务。
   - 每个任务先 `select_context_files`，再 `generate_patch`，并立即落盘。
5. 输出协议
   - `json_schema` 约束结构化 JSON。
   - 支持 `changes`（整文件覆盖）和 `search_replace_changes`（增量替换）。
6. 上下文与记忆
   - 历史对话压缩 + 文件上下文预算。
   - `memory_update` 与 thread memory 同步更新，可触发版本 rollover。
   - 扫描时仅注入当前活跃 thread 的 `thread_memory` 文件，避免跨线程污染。
7. 失败与回退
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
