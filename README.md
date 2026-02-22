# Doufu

一个基于 UIKit 的 iOS App，目标是让用户通过大语言模型快速生成并运行本地 `html + css + js` 网页，从而具备“自己写 App”的能力。

## 文档目录（协作与交接入口）

- `docs/product/`
- `docs/engineering/`

## 什么时候使用这些目录

1. 需求定义或产品方向讨论时，优先看 `docs/product/`。
2. 开始编码、拆模块、排期和评估风险时，优先看 `docs/engineering/`。
3. 需求发生变更时，先更新 `docs/product/`，再同步更新 `docs/engineering/`。
4. 新的 LLM 或新成员接手时，建议按以下顺序阅读：
   `README.md` -> `docs/product/vision.md` -> `docs/product/pages/home.md` -> `docs/engineering/technical-architecture.md` -> `docs/engineering/implementation-plan.md`

## 目录内容说明

- `docs/product/vision.md`：产品愿景、目标用户和核心原则。
- `docs/product/features.md`：功能范围（MVP 与后续阶段）。
- `docs/product/pages/home.md`：主页面的功能与布局文档（首个页面）。
- `docs/engineering/technical-architecture.md`：技术栈与关键技术约束（UIKit 优先）。
- `docs/engineering/module-design.md`：模块职责划分与边界。
- `docs/engineering/implementation-plan.md`：分阶段执行计划与验收标准。
- `docs/engineering/construction-notes.md`：施工注意事项和工程约束清单。

## 当前状态

- 已完成文档骨架与首批规格。
- 已完成第一个主页面的 UIKit 初始实现（新建网页 / 打开已有网页）。
