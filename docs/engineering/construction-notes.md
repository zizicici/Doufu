# 施工注意事项

## 技术约束

1. 页面开发默认使用 `UIKit`，避免无边界引入 SwiftUI。
2. 优先保持最小依赖，不提前引入复杂三方框架。
3. 以 iPhone 竖屏为默认设计目标，优先保证 Safe Area 与触控可用性。

## 代码组织

1. 每个 Feature 独立目录，控制文件规模。
2. ViewController 只处理 UI 组装和交互转发。
3. 业务逻辑进入 Service / Repository。
4. 设置页风格优先复用 `Features/Settings/Components` 中的通用 Cell。
5. 所有用户可见文案必须接入 `Localizable.xcstrings`，禁止新增硬编码显示文本。

## 性能与稳定性

1. 文件读写和生成操作放到后台线程。
2. UI 更新回主线程，避免并发错误。
3. 对超大生成内容设置大小与超时保护。
4. Agent 循环迭代次数有上限（`maxAgentIterations`），接近时注入系统提示收尾。
5. 只读工具并行执行以提升吞吐；写入工具顺序执行以保证数据一致性。
6. `validate_code` 使用共享 WKWebView，不可并行。
7. `UsageAccumulator` 使用 actor 保证 token 计数线程安全。

## 安全与隐私

1. 严格限制文件访问路径，禁止越权读取。
2. 项目之间目录隔离，不共享私有数据。
3. API Key / Bearer Token 必须存储在 Keychain，不写入项目目录。
4. 分享前提示用户检查敏感信息。
5. 工具权限分三级（autoAllow / confirmOnce / alwaysConfirm），危险操作需用户确认。

## Agent 工具注意事项

1. 工具定义与执行集中在 `AgentTools.swift` 和 `AgentToolProvider`。
2. 工具按危险程度分级：
   - `autoAllow`：read_file, list_directory, search_files, grep_files, glob_files, validate_code, diff_file, changed_files
   - `confirmOnce`：write_file, edit_file, move_file, revert_file
   - `alwaysConfirm`：delete_file, web_search, web_fetch
3. 三种权限模式：
   - `standard`：默认模式，写入工具首次确认，危险工具每次确认。
   - `autoApproveNonDestructive`：非危险操作自动通过。
   - `fullAutoApprove`：所有操作自动通过。
4. 工具结果需截断以控制上下文膨胀。
5. 工具执行分流：
   - 只读工具使用 TaskGroup 并行执行。
   - 写入工具顺序执行。
   - `validate_code` 串行（共享 WKWebView）。
6. 进度事件需覆盖所有工具操作阶段（`ToolProgressEvent` 枚举）。

## 对话上下文管理

1. 4 阶段自适应压缩：
   - 激进压缩可重读的工具结果（如 read_file）
   - 适度压缩搜索结果
   - 压缩剩余大型非错误结果
   - 丢弃最旧对话轮次（保持工具结果配对完整）
2. 历史对话与文件上下文都要做预算裁剪，避免 token 失控。
3. 维护结构化会话记忆（`objective/constraints/changed_files/todo_items`）并与 thread memory 同步。
4. 迭代次数预算控制，接近上限时注入系统提示要求收尾。
5. 响应被 `max_tokens` 截断时自动请求续传。

## 多 Provider 请求注意事项

1. OpenAI Compatible 走 `/responses`。
2. Anthropic 走 `/messages`（thinking 配置可能被后端拒绝，要可回退）。
3. Gemini 走 `/models/{model}:generateContent`（thinking config 可能被后端拒绝，要可回退）。
4. 不同 Provider 的鉴权头不同：
   - API Key 模式：Provider 特定 header（例如 `x-api-key`）。
   - OAuth 模式：`Authorization: Bearer ...`。
5. 模型能力统一通过 `LLMModelRegistry.resolve()` 获取 `ResolvedModelProfile`。

## Git 检查点注意事项

1. Agent loop 开始前通过 `ProjectGitService.createCheckpoint()` 创建检查点。
2. 检查点 commit message 格式：`[doufu-checkpoint] {用户消息前 120 字}`。
3. `undo()` 回退到最近检查点 commit。
4. 项目创建时自动初始化 Git 仓库。

## 模型能力解析注意事项

1. 所有模型能力信息统一通过 `LLMModelRegistry.resolve()` 获取。
2. 解析优先级：用户自定义 > 内置注册表 > 发现记录 > 保守回退。
3. `ResolvedModelProfile` 包含：reasoningEfforts, thinkingSupported, thinkingCanDisable, structuredOutputSupported, maxOutputTokens, contextWindowTokens。
4. 下游消费者不应直接读取 model record，而是使用 resolved profile。

## 调试与排障

1. 聊天异常时优先看控制台：
   - `HTTP 请求失败`
   - `invalidResponse`
   - SSE 原始事件列表
2. 调试日志必须脱敏：
   - 可以保留请求标签、响应头、SSE 事件
   - 禁止输出完整请求体与任何 Bearer Token/API Key
3. Agent 循环日志标注迭代次数和工具调用详情。

## 测试建议

1. 单元测试优先覆盖：
   - 路径校验与安全写入
   - 项目创建/删除/改名
   - Provider 存储与 Keychain 读写
   - 线程索引与 thread memory rollover
   - `LLMModelRegistry.resolve()` 各优先级场景
   - 工具权限分级逻辑
2. UI 测试至少覆盖：
   - 首页新建与项目打开
   - 空状态显示
   - Add Provider 表单启用态
   - 项目创建后的列表刷新与排序
   - 聊天中取消请求与阶段气泡展示
   - 工具确认对话框流程
   - 默认模型选择与 LLM 快速设置

## 变更流程

1. 需求变更先改产品文档，再改工程文档。
2. 编码前检查是否与文档冲突。
3. 合并前至少完成一次本地运行验证。
