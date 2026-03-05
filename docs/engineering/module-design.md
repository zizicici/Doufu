# 模块设计

## 模块总览

1. `Home`
   - 主要文件：`HomeViewController.swift`、`Features/Home/ProjectSortViewController.swift`
   - 责任：项目卡片画廊、搜索过滤、长按菜单、排序入口、新建入口。
2. `Project Runtime`
   - 主要文件：`Features/ProjectRuntime/ProjectWorkspaceViewController.swift`
   - 责任：全屏网页运行、悬浮面板交互、退出确认、项目级设置/聊天入口。
3. `Project Settings`
   - 主要文件：`Features/ProjectRuntime/ProjectSettingsViewController.swift`
   - 责任：项目名称修改与后续项目配置承载。
4. `Global Settings & Providers`
   - 主要文件：`Features/Settings/*`
   - 责任：Manage Providers 列表、Add Provider 流程、认证方式分流（API Key/OAuth）。
5. `Project Storage`
   - 主要文件：`Core/Projects/AppProjectStore.swift`
   - 责任：项目目录生命周期、模板写入、manifest 维护。
6. `Provider Storage`
   - 主要文件：`Core/LLM/LLMProviderSettingsStore.swift`
   - 责任：Provider 元数据持久化、Keychain 凭据存取与清理。
7. `OAuth Service`
   - 主要文件：`Core/LLM/OpenAICodexOAuthService.swift`
   - 责任：OpenAI 授权、回调监听、token 交换、登录结果整合。
8. `Codex Chat Service`
   - 主要文件：`Core/LLM/CodexProjectChatService.swift`
   - 责任：请求构造、流式解析、错误处理、补丁应用、调试日志输出。
9. `Settings UI Components`
   - 主要文件：`Features/Settings/Components/SettingsFormCells.swift`
   - 责任：复用设置风格 Cell（文本输入、密钥输入可显隐、Toggle、底部操作按钮）。

## 通信方式

1. UI 到业务：ViewController 直接调用 Store/Service（当前阶段）。
2. 模块边界：跨模块通过明确的数据结构（`AppProjectRecord`、`LLMProviderRecord`）传递。
3. 回调通知：使用闭包回调（例如项目更新后回刷首页）。

## 关键流程拆分

1. 新建项目
   - `HomeViewController` 触发 `AppProjectStore.createBlankProject()`
   - 创建目录与模板文件后 push 到 `ProjectWorkspaceViewController`
2. 聊天改项目
   - `CodexProjectChatViewController` 收集消息与 Provider
   - 调用 `CodexProjectChatService.sendAndApply()`
   - 成功后回调运行页刷新 `WKWebView`
3. 添加 Provider（API Key）
   - 表单校验通过后写入 `LLMProviderSettingsStore`
   - 元数据进 `UserDefaults`，密钥进 `Keychain`
4. 添加 Provider（OAuth）
   - `OpenAIOAuthProviderFormViewController` 发起登录
   - `OpenAICodexOAuthService` 回调成功后自动填充
   - 用户确认后写入 Provider Store
