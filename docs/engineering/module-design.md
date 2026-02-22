# 模块设计

## 模块总览

1. `HomeModule`
   - 责任：展示主入口与项目列表。
   - 输出：新建流程入口、项目详情入口。
2. `ProjectCreateModule`
   - 责任：收集需求并创建项目目录和初始文件。
   - 依赖：`GenerationService`、`ProjectRepository`。
3. `ProjectRuntimeModule`
   - 责任：加载本地网页并提供运行预览。
   - 依赖：`WKWebView`、`SecurityGuard`。
4. `ProjectRepository`
   - 责任：项目增删改查、索引管理、迁移。
5. `GenerationService`
   - 责任：把用户需求转成网页代码文件。
6. `SecurityGuard`
   - 责任：路径校验、越权访问阻断、风险策略。

## 通信方式

1. UI 到业务：通过 UseCase 或 Service 调用。
2. 模块间：通过协议接口，避免硬编码依赖。
3. 事件通知：必要时使用 NotificationCenter（控制范围）。

## 第一阶段落地范围

1. 完成 `HomeModule` 的 UI 与交互骨架。
2. 完成 `ProjectRepository` 的空实现接口。
3. 打通“新建网页 / 打开已有网页”的导航占位。
