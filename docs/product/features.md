# 功能范围说明

## 已完成功能（截至 2026-03-12）

1. 首页项目画廊
   - 3 列平铺卡片，支持搜索过滤。
   - 无项目时隐藏搜索栏并展示空状态。
   - 长按项目支持 `设置 / 排序 / 删除`。
   - 卡片右上角显示项目状态标签：`正在建造中`、`新版本`、`需要确认`、`出错了`。
   - `需要确认` / `出错了` 状态点击后直接进入聊天页。
2. 项目生命周期与版本记录
   - 一键创建本地项目目录和空白模板。
   - 项目变更（create / delete / close / rename）通过统一协调器执行，保证聊天 session 状态一致。
   - 项目创建时自动初始化 Git 仓库。
   - Agent 循环开始前自动保存当前脏工作区。
   - Agent 实际改动文件后自动创建 checkpoint commit。
   - 项目设置页支持查看并恢复 checkpoint 历史。
3. 项目运行页
   - 全屏 `WKWebView` 加载本地入口文件。
   - 悬浮面板支持拖拽、边缘吸附、自动收起、再次展开。
   - 面板项：`刷新 / 聊天 / 文件 / 设置 / 退出`。
   - Agent 执行中禁止从运行页进入 `文件 / 设置`，避免与正在进行的写入竞争。
   - 内置 JS 错误桥接提示，避免静默失败。
4. 文件浏览与编辑
   - 文件浏览器支持目录递进与文件打开。
   - 文件内容页支持编辑和保存。
   - 集成 `Runestone`（可用时）并按后缀自动语法高亮。
5. Provider 管理
   - 支持 `OpenAI Compatible`、`Anthropic`、`Google Gemini`。
   - 每个 Provider 支持 `API Key` 与 `OAuth` 模式。
   - 支持自定义 Base URL、Model。
   - 模型列表管理：发现/自定义/编辑能力参数（reasoning effort / thinking / structured output）。
   - 表单字段有效时才允许提交。
6. Agent 聊天改工程
   - 会话支持多线程（thread）持久化与切换。
   - 基于 tool-use agent loop 架构，模型自主调用工具迭代完成任务。
   - 内置 15 种工具：
     - 只读：`read_file`、`list_directory`、`search_files`、`grep_files`、`glob_files`、`diff_file`、`changed_files`
     - 写入：`write_file`、`edit_file`、`move_file`、`revert_file`
     - 危险：`delete_file`、`web_search`、`web_fetch`
     - 验证：`validate_code`
   - 工具权限三级分层：autoAllow / confirmOnce / alwaysConfirm。
   - 三种权限模式：standard / autoApproveNonDestructive / fullAutoApprove。
   - 只读工具并行执行，写入工具顺序执行，保证数据一致性。
   - 支持 extended thinking 内容展示。
   - 对话上下文 4 阶段自适应压缩。
   - 支持请求取消、阶段进度气泡、完成时长和请求级 token 用量显示。
   - 改动成功后刷新运行页、更新时间，并创建 Git checkpoint。
   - 项目级执行状态统一为 `building / newVersionAvailable / needsConfirmation / error / idle`，首页和运行页共享同一状态源。
   - 工具确认支持进程内挂起与恢复；用户回到聊天页后可继续处理之前等待确认的 tool call。
   - checkpoint restore 发生时，若该项目聊天会话仍活跃，会自动开启新的 thread，避免旧聊天上下文继续作用于已恢复的代码状态。
   - 迭代次数预算控制，接近上限时注入系统提示收尾。
   - 响应被 max_tokens 截断时自动续传。
7. 模型管理
   - `LLMModelRegistry` 统一解析模型能力与 token 预算。
   - 解析优先级：用户自定义 > 内置注册表 > 发现记录 > 保守回退。
   - App / Project / Thread 三层模型选择均持久化到 SQLite 表。
   - 设置页默认模型选择入口。
   - 首次使用聊天时 LLM 快速设置引导。
   - 三层模型选择产品语义见 `docs/product/model-selection.md`。
8. Token Usage 统计
   - 设置页与项目页复用同一套 Dashboard。
   - 展示总输入/总输出 Token。
   - 固定 7 天图表，支持按周前后翻页。
   - 支持按 Provider/Model 维度查看日分布。
   - 长按柱状图可查看当日各分类明细。
9. 代码验证
   - `CodeValidator` 通过隐藏 WKWebView 执行项目代码并捕获 JS 错误。
   - 作为 `validate_code` 工具集成到 Agent 工具链。
10. Web 能力
    - `WebToolProvider` 支持 web_search（DuckDuckGo / Bing / Google 多引擎自动降级）。
    - web_fetch 获取网页内容并提取文本。
    - Agent 可自主搜索技术文档辅助开发。
11. 本地化与安全
    - 文案已本地化（`en / zh-Hans / zh-Hant / zh-HK`）。
    - Provider 凭证存 `Keychain`，元数据存 SQLite。
    - 所有结构化数据（项目、Provider、聊天、token 用量、模型选择）统一存储在 SQLite 数据库。
    - 文件操作限制在项目目录，含路径安全校验。
    - 调试日志脱敏，禁止输出凭证。
12. CDN 资源缓存
   - HTML/CSS 中外部 `https://` 资源自动改写为走本地代理。
   - 代理层磁盘缓存（`Caches/CDNCache/`），首次加载后离线可用。
   - 容量上限 200 MB，LRU 淘汰；系统存储压力时可自动清除。
   - fetch/XHR 发起的 API 请求不受影响，不会被缓存。
13. 项目导入导出（`.doufu` / `.doufull`）
   - `Export Code` 导出为 `.doufu`（ZIP 语义，仅包含 `App/`）。
   - `Export Project Backup` 导出为 `.doufull`（ZIP 语义，包含 `App/` + `AppData/`，不包含 `preview.jpg`）。
   - 首页支持从 iCloud Drive / Files 导入 `.doufu`、`.doufull` 并创建新项目。
   - 支持重复导入同一文件；每次导入都会创建独立项目记录。

## 下一阶段（路线图）

1. 聊天稳定性和可解释性增强
   - 更细的失败原因分层、重试策略可视化、结果回滚体验。
2. 运行调试能力增强
   - 更完整的运行日志与错误定位辅助。
3. Provider 生态增强
   - 更多模型参数控制与连接诊断。
4. 导入导出增强
   - 兼容更多第三方打包行为与导入诊断信息。

## 非目标（当前阶段）

1. 云端多人实时协作。
2. 完整托管后端平台。
3. 跨设备强同步。
