# 执行计划

## 当前状态（2026-03-09）

1. 已完成首页项目画廊（搜索、长按菜单、拖拽排序、新建入口）。
2. 已完成项目运行页（全屏预览 + 悬浮面板 + 退出确认 + 文件入口）。
3. 已完成项目级设置页（名称修改 + 快照入口）。
4. 已完成项目快照能力（手动 10 条 + 自动 10 条 + 载入快照页）。
5. 已完成 Provider 管理全链路（OpenAI Compatible / Anthropic / Gemini，均支持 API Key + OAuth）。
6. 已完成 Provider 模型管理（发现/自定义/能力参数编辑）。
7. 已完成 `LLMModelRegistry` 统一模型能力解析（多级优先级回退）。
8. 已完成聊天架构升级为 **tool-use agent loop**（替代原 pipeline 三路执行）。
9. 已完成 15 种 Agent 工具：文件 CRUD、搜索、diff、web_search、web_fetch、validate_code。
10. 已完成工具权限分级与三种权限模式（standard / autoApproveNonDestructive / fullAutoApprove）。
11. 已完成只读工具并行执行与写入工具顺序执行。
12. 已完成 `ProjectGitService`：项目级 Git 初始化、检查点创建与 undo。
13. 已完成 `CodeValidator`：隐藏 WKWebView 代码验证。
14. 已完成 `WebToolProvider`：Web 搜索（多引擎降级）与网页抓取。
15. 已完成对话上下文 4 阶段自适应压缩。
16. 已完成 extended thinking 内容展示（Claude thinking blocks）。
17. 已完成迭代预算控制与 max_tokens 截断自动续传。
18. 已完成项目级/线程级模型选择持久化。
19. 已完成默认模型选择 UI 与 LLM 快速设置引导。
20. 已完成设置页重构（General / LLM Providers / Project 三组 + 通用 SettingsPickerViewController）。
21. 已完成聊天输入框升级（多行输入 + 动态高度）与 thread 持久化。
22. 已完成 WebView JS 错误桥接、预览图 JPEG 保存、文件浏览器与 Runestone 编辑。
23. 已完成 Token Usage 页面能力（全局 + 项目视角、7 天图表、按周翻页、Provider/Model 维度切换、长按明细）。
24. 已完成 Token Usage 相关文案本地化（`en / zh-Hans / zh-Hant / zh-HK`）。

## 已完成阶段回顾

1. Phase A：基础框架
   - 文档骨架、目录规范、核心模块边界。
2. Phase B：项目生命周期
   - 本地项目创建、读取、删除、改名、更新时间维护、快照管理。
3. Phase C：首页交互
   - 卡片网格展示、搜索、空状态、上下文菜单、排序页。
4. Phase D：运行与编辑入口
   - `WKWebView` 运行页、悬浮面板、刷新与退出流程、文件浏览与编辑。
5. Phase E：Provider 与认证
   - Manage Providers、Add Provider、多 Provider（OpenAI/Anthropic/Gemini）、API Key 与 OAuth。
6. Phase F：聊天改工程（Pipeline 阶段）
   - 文件上下文、流式请求、JSON 补丁解析、安全写入、日志排障。
7. Phase G：Agent 架构升级
   - 从 pipeline 三路执行升级为 tool-use agent loop。
   - 15 种工具定义与执行、权限分级。
   - Git 检查点与 undo。
   - 代码验证、Web 搜索与抓取。
   - 对话上下文自适应压缩。
   - Extended thinking 支持。
8. Phase H：模型管理
   - `LLMModelRegistry` 统一能力解析。
   - 项目级/线程级模型选择持久化。
   - 默认模型选择 UI、LLM 快速设置引导。
   - Provider 模型列表管理与能力编辑。

## 下一阶段计划

1. Phase I：聊天体验增强
   - 失败重试策略可视化、结果回滚体验、direct answer 与改代码路径的体验对齐。
2. Phase J：项目调试能力
   - 运行日志可视化、构建前检查、错误定位辅助。
3. Phase K：Provider 生态扩展
   - 连通性检测、模型能力探测、配置导入导出。
4. Phase L：分享与导出
   - 项目导出包、隐私检查、分享入口。

## 验收口径（下一阶段）

1. 聊天失败场景可定位原因并有明确恢复路径。
2. 关键改动可回滚，不破坏项目目录完整性。
3. 快照能力在手动与自动两条链路均稳定工作，且可正确按类型淘汰旧快照。
4. 新增能力不破坏现有项目运行与 Provider 配置。
