# Doufu

一个基于 `UIKit` 的 iOS App，目标是让用户通过自然语言快速生成并迭代本地 `html + css + js` 项目，并在 `WKWebView` 中直接运行。使用 `GRDB.swift`（SQLite）作为统一数据存储层。

## 文档目录（协作入口）

- `docs/product/`
- `docs/engineering/`

## 推荐阅读顺序

1. `README.md`
2. `docs/product/vision.md`
3. `docs/product/pages/home.md`
4. `docs/engineering/technical-architecture.md`
5. `docs/engineering/implementation-plan.md`

## 当前能力（与代码一致）

1. 首页项目画廊：
   - 3 列平铺卡片、搜索过滤、空状态、长按菜单（设置/排序/删除）。
   - 卡片右上角支持项目状态标签：`正在建造中`、`新版本`、`需要确认`、`出错了`。
   - `需要确认` / `出错了` 状态点击后直接进入聊天页，其余状态进入运行页。
   - 右上角 `+` 直接创建项目并进入运行页。
2. 项目运行页：
   - 全屏 `WKWebView`。
   - 可拖拽悬浮面板（刷新/聊天/文件/设置/退出）。
   - 支持边缘吸附、自动收起、点击展开。
   - 支持 JS 错误桥接提示，项目预览图保存为 `preview.jpg`（JPEG）。
3. 项目设置与版本记录：
   - 项目名与描述修改。
   - 项目默认模型与工具权限覆盖。
   - Git 检查点历史查看与恢复入口。
   - 恢复 checkpoint 后，若该项目聊天会话仍在，会自动开启新 thread，避免旧对话上下文继续作用于已恢复的代码状态。
4. 文件浏览与编辑：
   - 内置项目文件浏览器，支持二级目录。
   - 文件内容页支持编辑与保存。
   - 优先使用 `Runestone`（若可用）并按后缀启用语法高亮。
5. Provider 管理：
   - `Settings -> Manage Providers -> Add Provider`。
   - 支持 `OpenAI Compatible`、`Anthropic`、`Google Gemini`。
   - 每个 Provider 支持 `API Key` 与 `OAuth` 模式。
   - Provider 元数据在 SQLite，凭证在 `Keychain`。
   - 支持模型列表管理（发现/自定义/编辑能力参数）。
6. Agent 聊天改工程（Project Chat）：
   - 会话支持多线程（thread）持久化，可切换历史线程。
   - 基于 **tool-use agent loop** 架构：模型自主调用工具完成任务。
   - 内置 15 种工具：文件读写/编辑/删除/移动/回退、目录浏览、搜索/grep/glob、diff/changed_files、web_search/web_fetch、validate_code。
   - 工具权限分三级（autoAllow / confirmOnce / alwaysConfirm），支持三种权限模式（standard / autoApproveNonDestructive / fullAutoApprove）。
   - 只读工具并行执行，写入工具顺序执行。
   - 支持 extended thinking 内容展示（如 Claude thinking blocks）。
   - Agent 循环开始前会确保项目 Git 仓库存在，并自动保存用户当前未提交改动。
   - 若本轮实际改动了文件，结束后会创建 Git checkpoint，并刷新运行页与项目更新时间。
   - 设置页支持查看并恢复 checkpoint 历史。
   - 项目级执行状态统一为 `building / newVersionAvailable / needsConfirmation / error / idle`，首页与运行页共享同一状态源。
   - 工具确认支持进程内挂起与恢复；App 回前台或重新进入聊天页后，可以继续处理之前等待确认的 tool call。
   - 对话上下文 4 阶段自适应压缩，控制 token 预算。
   - 支持任务进度分气泡展示、取消请求、请求级 token 用量展示。
7. 模型管理：
   - `LLMModelRegistry` 统一模型能力解析（reasoning effort / thinking / structured output / token 预算）。
   - 解析优先级：用户自定义 > 内置注册表 > 发现记录 > 保守回退。
   - 支持 `App / Project / Thread` 三层统一的模型选择持久化（`provider / model / reasoning / thinking` 同构），均存储在 SQLite 表中。
   - `ModelSelectionStateStore` 作为单一状态源统一管理三层选择，Chat / Settings / Project Settings 都通过同一份状态和通知刷新。
   - 模型配置页会显式保留 invalid selection / missing selection，不做 silent fallback 到首个可用模型。
   - 设置页支持选择 App 默认模型，项目页支持设置 Project 默认模型。
   - 首次使用聊天时提供 LLM 快速设置引导。
8. Token Usage：
   - 设置页和项目页共用 Dashboard。
   - 展示总输入/总输出、按周分页的 7 天图表、按 Provider/Model 维度切换。
   - 长按图表可查看当天分项明细。
   - 相关文案已本地化（`en / zh-Hans / zh-Hant / zh-HK`）。
9. 代码验证：
   - 内置 `CodeValidator`，通过隐藏 WKWebView 执行 JS 并捕获错误。
   - 作为 `validate_code` 工具可被 Agent 自动调用。
10. Web 能力：
    - `WebToolProvider` 支持 web_search（DuckDuckGo / Bing / Google 多引擎）和 web_fetch。
    - Agent 可自主搜索文档、获取网页内容辅助开发。

## 维护规则

1. 需求变更先更新 `docs/product`，再更新 `docs/engineering`。
2. 新增用户可见文案时，必须同步 `Localizable.xcstrings`。
3. 涉及架构调整时，必须同步 `technical-architecture.md` 与 `module-design.md`。

文档已按当前实现同步更新（2026-03-12）。所有结构化数据已迁移到 SQLite（GRDB.swift 7.10.0）。
