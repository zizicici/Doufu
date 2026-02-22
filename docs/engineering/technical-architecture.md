# 技术架构说明

## 技术选型

1. UI 框架：`UIKit`（默认与优先）
2. 网页渲染：`WKWebView`
3. 本地存储：`FileManager` + JSON 元数据
4. 并发模型：`Swift Concurrency`（必要时结合 GCD）
5. 最低要求：保持与当前工程 Deployment Target 一致

> 约束：除非明确收益显著，否则不引入 SwiftUI 页面。

## 架构原则

1. 界面层与业务层分离，避免 ViewController 承担全部逻辑。
2. LLM 生成、文件系统、部署能力都封装为独立 Service。
3. 项目目录结构标准化，支持后续导出与分享。

## 建议目录（随实现逐步落地）

1. `Doufu/App/`：App 生命周期与基础装配
2. `Doufu/Features/Home/`：主页面
3. `Doufu/Features/ProjectCreate/`：新建流程
4. `Doufu/Features/ProjectDetail/`：预览与编辑入口
5. `Doufu/Core/Storage/`：项目存储、索引、迁移
6. `Doufu/Core/Generation/`：LLM 请求与产物组装
7. `Doufu/Core/Security/`：沙盒访问控制与校验

## 数据模型（初版）

1. `AppProject`
   - `id`
   - `name`
   - `createdAt`
   - `updatedAt`
   - `entryFilePath`
2. `ProjectManifest`
   - `projectId`
   - `files`
   - `version`

## 本地存储约定（初版）

1. 根目录：`Documents/AppProjects/`
2. 单项目目录：`Documents/AppProjects/{projectId}/`
3. 每个项目至少包含：
   - `index.html`
   - `style.css`
   - `script.js`
   - `manifest.json`

## 安全边界

1. 每个项目仅可访问自身目录。
2. 运行时禁止读取沙盒外路径。
3. 对用户输入和生成代码做基本静态校验（后续迭代）。
