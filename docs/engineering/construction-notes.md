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

## 性能与稳定性

1. 文件读写和生成操作放到后台线程。
2. UI 更新回主线程，避免并发错误。
3. 对超大生成内容设置大小与超时保护。
4. Codex 请求超时：
   - `reasoning=high`：400s
   - `reasoning=xhigh`：600s

## 安全与隐私

1. 严格限制文件访问路径，禁止越权读取。
2. 项目之间目录隔离，不共享私有数据。
3. API Key / Bearer Token 必须存储在 Keychain，不写入项目目录。
4. 分享前提示用户检查敏感信息。

## Codex 协议注意事项

1. 调用 `responses` 接口时，历史消息 content type 必须和角色匹配：
   - `user -> input_text`
   - `assistant -> output_text`
2. 聊天链路采用“两阶段请求”：
   - 阶段 A：文件检索（仅返回 `selected_paths`）
   - 阶段 B：补丁生成（返回 `assistant_message + changes`）
   - 在复杂需求下会先执行 `plan_tasks`，再逐任务走 A/B 阶段。
3. 请求体必须包含 `instructions`（当前实现依赖该字段约束 JSON 输出结构）。
4. 返回流需要兼容多种事件形态：
   - 标准 SSE 事件
   - newline-delimited JSON（无空行分隔）
5. JSON 补丁落盘前必须做路径安全检查：
   - 仅允许相对路径
   - 禁止 `..` 与绝对路径
6. 对 `xhigh` 不支持的后端要自动降级为 `high` 重试。
7. 历史对话和文件内容都要做预算裁剪，避免上下文无限增长。
8. 维护结构化会话记忆块（`objective/constraints/changed_files/todo_items`），并在每轮自动滚动更新。
9. 轻量子任务执行约束：每个子任务默认最多携带 3 个文件；任一步失败即停止后续任务并提示重试。

## 调试与排障

1. 聊天异常时优先看控制台：
   - `HTTP 请求失败`
   - `invalidResponse`
   - SSE 原始事件列表
2. 建议保留请求体和响应头输出，便于定位后端字段兼容问题。
3. 请求日志中需要区分阶段标签（如 `select_context_files`、`generate_patch`）。

## 测试建议

1. 单元测试优先覆盖：
   - 路径校验与补丁安全写入
   - 项目创建/删除/改名
   - Provider 存储与 Keychain 读写
2. UI 测试至少覆盖：
   - 首页新建与项目打开
   - 空状态显示
   - Add Provider 表单启用态
   - 项目创建后的列表刷新与排序

## 变更流程

1. 需求变更先改产品文档，再改工程文档。
2. 编码前检查是否与文档冲突。
3. 合并前至少完成一次本地运行验证。
