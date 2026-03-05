# 技术架构说明

## 技术选型

1. UI 框架：`UIKit`（默认与优先）
2. 网页渲染：`WKWebView`
3. 本地存储：`FileManager` + JSON 元数据
4. 并发模型：`Swift Concurrency`（必要时结合 GCD）
5. 安全存储：`Keychain`（API Key / Bearer Token）
6. 最低要求：保持与当前工程 Deployment Target 一致

> 约束：除非明确收益显著，否则不引入 SwiftUI 页面。

## 架构原则

1. 界面层与业务层分离，避免 ViewController 承担全部逻辑。
2. LLM 调用、文件系统、Provider 管理封装为独立 Service/Store。
3. 项目目录结构标准化，支持后续导出与分享。
4. 默认移动端优先（iPhone 竖屏 + Safe Area + 触控可用性）。

## 当前目录映射（关键）

1. `Doufu/App/`
   - 应用启动与根导航装配。
2. `Doufu/Core/Projects/`
   - `AppProjectStore`：项目创建、删除、改名、`manifest.json` 更新时间维护、项目快照创建/读取/恢复。
3. `Doufu/Core/LLM/`
   - `LLMProviderSettingsStore`：Provider 元数据与 Keychain 凭证管理。
   - `OpenAICodexOAuthService`：OpenAI 登录、回调、token 交换与 Bearer Token 解析。
   - `CodexProjectChatService`：聊天服务薄入口（对外 API）。
   - `ChatPipeline/*`：聊天链路分层实现：
     - `ProjectFileScanner`、`SessionMemoryManager`、`PromptBuilder`
     - `LLMStreamingClient`、`PatchApplicator`、`CodexChatOrchestrator`
4. `Doufu/Features/Home/`
   - `ProjectSortViewController`：项目拖拽排序页。
   - 首页主控制器当前仍在 `Doufu/HomeViewController.swift`（后续可归档到 `Features/Home`）。
5. `Doufu/Features/ProjectRuntime/`
   - `ProjectWorkspaceViewController`：网页运行页 + 悬浮面板。
   - `CodexProjectChatViewController`：项目聊天入口与消息流。
   - `ProjectSettingsViewController`：项目级设置页。
6. `Doufu/Features/Settings/`
   - 全局设置与 Provider 管理页面（含 Add Provider 多级流程）。
7. `Doufu/Features/Settings/Components/`
   - 系统设置风格通用 Cell（输入、密钥显示切换、开关、居中按钮）。

## 关键数据模型

1. `AppProject`
   - `id`, `name`, `projectURL`, `entryFileURL`, `createdAt`, `updatedAt`
2. `manifest.json`
   - `projectId`, `name`, `entryFilePath`, `createdAt`, `updatedAt`
   - `prompt`, `description`, `source`（当前为 `local`）
3. `LLMProviderRecord`
   - `id`, `kind`, `authMode`, `label`, `baseURLString`, `autoAppendV1`
   - `chatGPTAccountID`, `createdAt`, `updatedAt`

## 本地存储约定

1. 根目录：`Documents/AppProjects/`
2. 单项目目录：`Documents/AppProjects/{projectId}/`
3. 每个项目至少包含：
   - `index.html`
   - `style.css`
   - `script.js`
   - `manifest.json`
   - `AGENTS.md`（项目级移动端约束）
4. 快照目录：`{project}/.doufu_snapshots/`
   - `manual/`：手动快照，最多保留 10 条
   - `auto/`：聊天自动快照，最多保留 10 条
   - 每条快照包含 `snapshot.json` 与 `content/`
5. Provider 元数据：`UserDefaults`（`llm.providers.records.v1`）
6. 敏感信息：`Keychain`（`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`）

## Codex 请求链路（当前实现）

1. 阶段 0：任务规划
   - 先请求 `plan_tasks`，把复杂请求拆成 1-5 个可顺序执行的子任务。
   - 每个子任务独立执行，任一步失败即停止后续任务。
2. 阶段 1：文件索引与检索
   - 扫描项目文本文件生成轻量目录（`path/byteCount/lineCount/preview`）。
   - 先请求模型仅返回 `selected_paths`，选择真正相关文件。
3. 阶段 2：补丁生成
   - 仅携带选中文件内容进入主生成请求，避免整包文件上传。
   - 角色映射：`user -> input_text`，`assistant -> output_text`（兼容后端校验）。
   - 轻量模式下每个子任务最多带 3 个文件，降低单次风险。
   - 多任务模式下每个任务写入成功后重新扫描文件候选，保证后续任务读取最新代码。
   - 支持 `changes`（整文件覆盖）与 `search_replace_changes`（片段替换）双通道。
4. 上下文压缩
   - 历史消息有上限，较早轮次自动摘要压缩再注入上下文。
   - 文件上下文执行单文件和总量预算裁剪，控制 token 膨胀。
5. 会话结构化记忆
   - 内部维护并滚动更新 memory block：`objective / constraints / changed_files / todo_items`。
   - 每轮请求注入 memory block，模型可返回 `memory_update` 增量更新。
   - memory 会落盘到项目目录 `.doufu_chat_session.json`，重开聊天可恢复。
6. 模型输出要求
   - 强制返回 JSON：`assistant_message + changes[] (+ search_replace_changes[])`。
   - 通过 `text.format = json_schema` 约束结构化输出；若后端不支持自动降级。
7. 响应解析
   - 处理标准 SSE 事件，也兼容部分后端的“逐行 JSON”变体。
8. 安全落盘
   - 仅允许相对路径，禁止绝对路径和 `..`。
9. 超时与推理
   - `reasoning=high` 默认超时 400s；
   - `reasoning=xhigh` 超时 600s，若后端拒绝则自动降级回 `high`。
10. 快照策略
   - 聊天成功且有文件改动时自动创建一次快照（`auto`）。
   - 载入快照时先清空当前项目文件（保留快照仓），再恢复目标快照内容。
11. 轻量快速路径
   - 当项目文件较少且请求较简单时，跳过任务规划/文件选择阶段，直接单次生成并应用改动。
   - 快速路径使用本地启发式文件选择，而不是简单“前 N 个文件”。
12. 取消与流式回退
   - `Task.cancel()` 会沿规划/检索/生成链路透传，不会被 fallback 逻辑吞掉。
   - 若后端在 `200 + SSE` 阶段返回失败事件，也会触发与 4xx 相同的自动回退策略。

## OAuth 链路（OpenAI / Compatible API）

1. 使用 `SFSafariViewController` 打开 OpenAI 授权页。
2. 本地回调服务监听 `localhost:1455/auth/callback`。
3. 使用 PKCE 交换授权码，解析 `id_token/access_token/refresh_token`。
4. 优先尝试换取 API Key 风格 Token；失败时回退使用 Access Token + ChatGPT Codex Backend。
5. 登录成功后自动填充 Base URL 与 Bearer Token 到表单。

## 安全边界

1. 每个项目仅可访问自身目录。
2. 运行时禁止读取沙盒外路径。
3. 路径写入前执行相对路径白名单校验。
4. 密钥不落盘到项目目录，只进入 Keychain。
