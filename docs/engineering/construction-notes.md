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
4. 聊天请求超时：
   - `reasoning=high`：400s
   - `reasoning=xhigh`：600s

## 安全与隐私

1. 严格限制文件访问路径，禁止越权读取。
2. 项目之间目录隔离，不共享私有数据。
3. API Key / Bearer Token 必须存储在 Keychain，不写入项目目录。
4. 分享前提示用户检查敏感信息。

## 聊天协议注意事项

1. 调用 `responses` 接口时，历史消息 content type 必须和角色匹配：
   - `user -> input_text`
   - `assistant -> output_text`
2. 聊天链路是三路执行：
   - `direct_answer`：直接回答问题，不改文件。
   - `single_pass`：单次改动路径。
   - `multi_task`：任务规划 + 逐任务检索 + 逐任务补丁。
3. 复杂改动路径中，文件检索阶段返回 `selected_paths`，补丁阶段返回 `assistant_message + changes/search_replace_changes`。
4. 请求体的结构化输出优先走 `text.format = json_schema`，后端不支持时要自动降级重试。
5. 返回流需要兼容多种事件形态：
   - 标准 SSE 事件
   - newline-delimited JSON（无空行分隔）
6. JSON 补丁落盘前必须做路径安全检查：
   - 仅允许相对路径
   - 禁止 `..` 与绝对路径
7. 对 `xhigh` 不支持的后端要自动降级为 `high` 重试。
8. `json_schema` 被拒绝时要自动降级并重试。
9. 历史对话与文件上下文都要做预算裁剪，避免 token 失控。
10. 维护结构化会话记忆（`objective/constraints/changed_files/todo_items`）并与 thread memory 同步。
11. 多任务执行时，每个子任务落盘后刷新文件候选，避免后续任务基于旧代码。
12. 取消请求必须透传到路由/规划/检索/生成全链路，不允许被 fallback 吞掉。
13. 若后端在 `200 + SSE` 阶段返回失败事件，仍需走与 4xx 一致的降级重试策略。

## 多 Provider 请求注意事项

1. OpenAI Compatible 走 `/responses`。
2. Anthropic 走 `/messages`（thinking 配置可能被后端拒绝，要可回退）。
3. Gemini 走 `/models/{model}:generateContent`（thinking config 可能被后端拒绝，要可回退）。
4. 不同 Provider 的鉴权头不同：
   - API Key 模式：Provider 特定 header（例如 `x-api-key`）。
   - OAuth 模式：`Authorization: Bearer ...`。

## 调试与排障

1. 聊天异常时优先看控制台：
   - `HTTP 请求失败`
   - `invalidResponse`
   - SSE 原始事件列表
2. 调试日志必须脱敏：
   - 可以保留请求标签、响应头、SSE 事件
   - 禁止输出完整请求体与任何 Bearer Token/API Key
3. 请求日志中需要区分阶段标签（如 `dispatch_or_answer`、`plan_tasks`、`select_context_files`、`generate_patch`）。

## 测试建议

1. 单元测试优先覆盖：
   - 路径校验与补丁安全写入
   - 项目创建/删除/改名
   - Provider 存储与 Keychain 读写
   - 线程索引与 thread memory rollover
2. UI 测试至少覆盖：
   - 首页新建与项目打开
   - 空状态显示
   - Add Provider 表单启用态
   - 项目创建后的列表刷新与排序
   - 聊天中取消请求与阶段气泡展示

## 变更流程

1. 需求变更先改产品文档，再改工程文档。
2. 编码前检查是否与文档冲突。
3. 合并前至少完成一次本地运行验证。
