# Doufu

一个基于 `UIKit` 的 iOS App，目标是让用户通过自然语言快速生成并迭代本地 `html + css + js` 项目，并在 `WKWebView` 中直接运行。

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
   - 右上角 `+` 直接创建项目并进入运行页。
2. 项目运行页：
   - 全屏 `WKWebView`。
   - 可拖拽悬浮面板（刷新/聊天/文件/设置/退出）。
   - 支持边缘吸附、自动收起、点击展开。
   - 支持 JS 错误桥接提示，项目预览图保存为 `preview.jpg`（JPEG）。
3. 项目设置与快照：
   - 项目名修改。
   - 手动快照最多 10 条、自动快照最多 10 条。
   - 支持“载入快照”恢复。
4. 文件浏览与编辑：
   - 内置项目文件浏览器，支持二级目录。
   - 文件内容页支持编辑与保存。
   - 优先使用 `Runestone`（若可用）并按后缀启用语法高亮。
5. Provider 管理：
   - `Settings -> Manage Providers -> Add Provider`。
   - 支持 `OpenAI Compatible`、`Anthropic`、`Google Gemini`。
   - 每个 Provider 支持 `API Key` 与 `OAuth` 模式。
   - Provider 元数据在 `UserDefaults`，凭证在 `Keychain`。
6. 聊天改工程（Project Chat）：
   - 会话支持多线程（thread）持久化，可切换历史线程。
   - 执行路由支持三种模式：`direct_answer` / `single_pass` / `multi_task`。
   - 支持结构化输出（`json_schema`）、整文件覆盖与 `search_replace_changes` 增量修改。
   - 支持任务进度分气泡展示、取消请求、请求级 token 用量展示。
   - 聊天成功改动后自动快照。
7. Token Usage：
   - 设置页和项目页共用 Dashboard。
   - 展示总输入/总输出、按周分页的 7 天图表、按 Provider/Model 维度切换。
   - 长按图表可查看当天分项明细。
   - 相关文案已本地化（`en / zh-Hans / zh-Hant / zh-HK`）。

## 维护规则

1. 需求变更先更新 `docs/product`，再更新 `docs/engineering`。
2. 新增用户可见文案时，必须同步 `Localizable.xcstrings`。
3. 涉及架构调整时，必须同步 `technical-architecture.md` 与 `module-design.md`。

文档已按当前实现同步更新（2026-03-06）。
