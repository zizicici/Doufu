# Doufu

一个基于 UIKit 的 iOS App，目标是让用户通过大语言模型快速生成并运行本地 `html + css + js` 网页，从而具备“自己写 App”的能力。

## 文档目录（协作与交接入口）

- `docs/product/`
- `docs/engineering/`

## 什么时候使用这些目录

1. 需求定义、体验方向或页面行为讨论时，优先看 `docs/product/`。
2. 编码、拆模块、排期和排障时，优先看 `docs/engineering/`。
3. 需求变更时，先更新产品文档，再同步工程文档。
4. 新成员接手建议按顺序阅读：
   `README.md` -> `docs/product/vision.md` -> `docs/product/pages/home.md` -> `docs/engineering/technical-architecture.md` -> `docs/engineering/implementation-plan.md`

## 目录内容说明

- `docs/product/vision.md`：产品愿景、目标用户和核心原则。
- `docs/product/features.md`：已完成能力、在研事项与路线图。
- `docs/product/pages/home.md`：首页（项目画廊）规格与交互。
- `docs/engineering/technical-architecture.md`：技术架构、数据流与安全边界。
- `docs/engineering/module-design.md`：当前模块职责与主要类映射。
- `docs/engineering/implementation-plan.md`：当前阶段状态、后续计划和验收口径。
- `docs/engineering/construction-notes.md`：施工约束、协议细节与排障建议。

## 当前状态

1. 首页是项目画廊模式（Safari 风格平铺）：
   - 每行约 3 列豆腐块卡片
   - 有项目时显示搜索栏；无项目时自动隐藏
   - 右上角 `+` 新建项目，左上角进入设置页
   - 长按项目支持 `设置 / 排序 / 删除`
2. 新建项目会在本地创建目录与空白模板，并自动写入项目级 `AGENTS.md`（移动端优先约束）。
3. 项目运行页已支持：
   - 全屏 `WKWebView`
   - 拖拽悬浮面板（刷新 / 聊天 / 设置 / 退出）
   - 新项目未修改时退出的“保存/不保存”确认
   - 项目设置内支持“保存快照 / 载入快照”
4. 设置体系已支持：
   - `Settings -> Manage Providers -> Add Provider`
   - `OpenAI / Compatible API`，含 `API Key` 与 `OAuth` 两种方式
   - Provider 元数据存 `UserDefaults`，密钥与 Token 存 `Keychain`
5. Codex 聊天改文件链路已打通：
   - 轻量多任务链路：先规划任务，再逐任务检索和生成补丁
   - 自动压缩历史上下文，避免长对话无上限膨胀
   - 会话结构化记忆块自动滚动更新（目标/约束/已改文件/待办）
   - 上下文预算裁剪（按文件和总量限制）
   - 多任务执行时每步改动后会刷新项目文件快照，后续任务基于最新文件继续执行
   - 解析结构化 JSON 补丁并安全落盘
   - 聊天成功改动后自动创建项目快照（最多保留 10 条）
   - 调试日志（请求标签、响应头、SSE 事件；请求体脱敏）
   - 支持在流式阶段失败时自动回退（如 `xhigh -> high`、`json_schema -> 普通文本`）
   - 取消请求可立即生效（不会被任务规划/文件选择 fallback 吞掉）
   - `reasoning` 默认 `high`，复杂任务可 `xhigh`，不支持时自动回退

## 近期说明

- 新建项目模板会自动生成项目级 `AGENTS.md`，用于持续约束移动端优先（Safe Area、触控尺寸、弱网页感等）。
- 聊天请求默认 `reasoning=high`，复杂任务会尝试 `xhigh`，若后端不支持会自动回退到 `high`。
- 调试模式下会在控制台打印请求标签、响应头与 SSE 事件；请求体固定脱敏，避免泄漏敏感信息。
- 项目快照分为手动与自动两类：手动快照最多 10 条，自动快照最多 10 条。
- 文档已按当前实现同步更新（2026-03-05）。
