# 产品规格：三层 Model Selection

## 文档目标

定义 `App / Project / Thread` 三层模型选择的产品语义、状态表现和主要交互，作为后续实现与验收的唯一产品依据。

## 适用范围

本规格覆盖以下入口与页面：

1. 全局默认模型设置页
2. 项目设置页中的项目默认模型
3. 聊天页中的线程模型配置
4. Workspace 进入 Chat 的准入逻辑
5. Chat 页顶部模型状态展示
6. 发送按钮的启用/禁用规则

## 核心原则

1. 三层模型选择是覆盖关系，不是缓存关系。
2. 下层 `override` 缺失时才继承上层。
3. 已存在但无效的 `override` 不自动回退。
4. 恢复默认的语义永远是“删除当前层 override”。
5. Thread 只保存一条当前显式选择，不保存每个 Provider 的历史选择。
6. `reasoning / thinking` 不参与三层继承，只属于当前 Thread 的显式配置。

## 层级定义

### App

全局默认模型。

- 数据含义：用户给整个 App 设定的默认 Provider + Model。
- 可为空：为空表示 App 层缺失。
- 设置入口：`设置 -> 默认模型`
- 清除动作：`Not Set`

### Project

项目默认模型。

- 数据含义：仅对当前 Project 生效的默认 Provider + Model。
- 可为空：为空表示继续继承 App 默认。
- 设置入口：`项目设置 -> 默认模型`
- 清除动作：`Use App Default`

### Thread

当前线程的显式模型选择。

- 数据含义：当前 Thread 使用的 Provider + Model + 线程级参数。
- 可为空：为空表示继续继承 `Project -> App`。
- 设置入口：聊天页中的模型配置入口
- 清除动作：`Use Default`

## Thread 层数据范围

Thread 层只保存以下信息：

1. `providerID`
2. `modelRecordID`
3. `reasoningEffort?`
4. `thinkingEnabled?`

不再保存“切到别的 Provider 时上次用过什么模型”的历史信息。

## 有效状态模型

系统需要明确区分以下状态：

1. `noUsableProviderEnvironment`
   - 没有任何可用 Provider / Token。
2. `missingSelection`
   - Provider / Token 可用，但三层都没有有效选择。
3. `valid`
   - 当前存在有效模型选择，可正常发送。
4. `invalidOverride`
   - 当前存在显式 override，但该 override 无效。

`invalidOverride` 至少区分以下原因：

1. Provider 已不存在
2. Credential 不可用
3. Model 已不存在

### 当前实现映射

当前代码没有把 `noUsableProviderEnvironment` 单独建成第四个 resolver case，而是拆成两部分表达：

1. `hasUsableProviderEnvironment: Bool`
2. `selection state`
   - `missingSelection`
   - `valid`
   - `invalidOverride`

这两部分组合后的产品语义与上面的状态模型等价：

1. `hasUsableProviderEnvironment == false`
   - 等价于 `noUsableProviderEnvironment`
2. `hasUsableProviderEnvironment == true && state == .missingSelection`
   - 等价于 `missingSelection`
3. `hasUsableProviderEnvironment == true && state == .valid`
   - 等价于 `valid`
4. `state == .invalidOverride`
   - 等价于 `invalidOverride`

## 继承与回退规则

### 缺失 override

当某层 `override == nil` 时，向上继承。

规则：

1. Thread 缺失 -> 看 Project
2. Project 缺失 -> 看 App
3. App 缺失 -> 进入 `missingSelection`

### 无效 override

当某层存在显式 `override`，但该 override 无效时：

1. 不自动回退到上层
2. 直接进入 `invalidOverride`
3. 由用户手动决定：
   - 修复 Provider / Token
   - 改模型
   - 使用默认值

## Workspace 行为

### 进入 Full Chat

以下两种情况都允许进入可编辑聊天页：

1. `valid`
2. `missingSelection`
3. `invalidOverride`

对应行为：

1. `valid`
   - 正常 Full Chat
   - `Send` 可用
2. `missingSelection`
   - Full Chat
   - `Send` 禁用
   - 用户在 Chat 内修复模型选择
3. `invalidOverride`
   - Full Chat
   - `Send` 禁用
   - UI 明确显示当前 override 无效

### 无可用 Provider 环境

当状态为 `noUsableProviderEnvironment`：

1. 弹出 setup alert
2. 主按钮：`Setup`
3. 次按钮：`Read Only Chat`
4. 保留进入只读聊天的能力
5. 如果已存在 Provider 配置但当前 credential 全部不可用，alert 文案应明确引导“修复 credential”，而不是只像首次配置引导。

## Chat 行为

### 顶部状态展示

Chat 顶部需要明确展示来源或状态，但不能依赖过长的导航标题。

状态优先级：

1. `Invalid ...`
2. `Missing Model Selection`
3. `Using Project Default`
4. `Using App Default`
5. 普通有效线程选择

展示要求：

1. 不把长状态文案硬塞进 navigation title。
2. 当前实现使用 Chat 导航栏的 `prompt` 展示轻量状态文案。
3. 后续如果 prompt 空间不够，可以再替换成更明确的状态条或辅助标签。
4. 用户必须能看出“当前是无效 / 缺失 / 继承 / 显式选择”。

### Send 按钮

只有 `valid` 时允许发送。

以下状态均禁用发送：

1. `noUsableProviderEnvironment`
2. `missingSelection`
3. `invalidOverride`

### 无法发送时的修复路径

Chat 内必须存在明确修复入口。

至少支持：

1. 打开模型配置
2. `Use Default`
3. 修复 Provider / Token

当状态为 `missingSelection` 时：

1. 不自动弹窗
2. 允许进入 Chat
3. 用户可通过模型入口主动配置

### Chat 内 Provider 修复

聊天页内的模型配置页不能只依赖“当前可用 credential 列表”。

规则：

1. 模型配置页展示所有已配置 Provider，而不只是当前可用 Provider。
2. 对于 credential 不可用的 Provider，页面需要明确标记其当前不可用。
3. 页面内保留直接进入 Provider 管理的入口，供用户修复 Token / OAuth / API Key。

## 设置页行为

### App 默认模型页

入口：`设置 -> 默认模型`

规则：

1. 可以设置全局默认模型
2. 可以通过 `Not Set` 清除 App override
3. 如果当前 App 默认无效，页面要明确显示 `Invalid App Default`

### Project 默认模型页

入口：`项目设置 -> 默认模型`

规则：

1. 可以设置项目默认模型
2. 可以通过 `Use App Default` 清除 Project override
3. 如果当前 Project 默认无效，页面要明确显示 `Invalid Project Default`

### Thread 模型页

入口：聊天页模型配置

规则：

1. 可以设置当前 Thread 的显式模型
2. 可以设置当前 Thread 的 `reasoning / thinking`
3. 可以通过 `Use Default` 删除 Thread override
4. 当当前 Thread override 无效时，仍要显示 `Use Default`

## 无效状态下打开模型页的默认落点

当用户从 Chat 进入模型配置页时：

1. 如果当前无效 override 的 Provider 仍存在：
   - 默认停留在该 Provider
2. 如果当前无效 override 的 Provider 已不存在：
   - 默认落到第一个可用 Provider

当前实现约定：

1. “仍存在”指 Provider 配置记录仍存在，即使当前 credential 不可用，也要停留在该 Provider。
2. 只有当 Provider 配置本身已经被删除时，才回退到第一个现存 Provider。
3. 如果 Provider 仍存在但当前 `modelRecordID` 已不存在，页面保留该无效 model ID 的显式状态，不自动勾选第一个可用模型。
4. 在上述无效 model 状态下，`reasoning / thinking` 参数区隐藏，直到用户显式改成一个有效模型或点 `Use Default`。

## 参数行为

### Reasoning / Thinking

不参与 `App -> Project -> Thread` 三层继承。

规则：

1. 只对当前 Thread 生效
2. 切换到新模型时，回到该模型默认值
3. 只有用户在当前 Thread 显式修改后，才形成 Thread 级参数 override

## 旧数据容错

旧版 Thread 选择数据可能仍然以多 map 结构存在。

当前策略不是做正式迁移，而是做安全容错：

1. 读取旧结构时，只尝试提取“当前 provider + 当前 model + 当前参数”。
2. 任意字段缺失、格式错误或脏数据，不应导致崩溃。
3. 单条坏的 Thread 选择数据，不应拖垮整份 `thread_selections.json`。
4. 旧数据一旦被用户重新保存，就会被新的单条 override 结构覆盖。
5. `thread_selections.json` 的读取应按 entry 独立解码，坏 entry 直接跳过，不影响其他线程。

对于 `App / Project` 默认模型页：

1. 无效 override 仍按“显式但无效”处理，不伪装成 `Not Set / Use App Default`。
2. 页面通过轻量状态文案（如导航栏 `prompt`）明确显示 `Invalid App Default / Invalid Project Default`。

## Project 默认变更传播

规则固定为：

1. 没有 Thread override 的线程，立即继承新的 Project 默认
2. 有 Thread override 的线程，不受影响

## 恢复默认语义

三层统一定义如下：

1. Thread 页的 `Use Default`
   - 删除 Thread override
2. Project 页的 `Use App Default`
   - 删除 Project override
3. App 页的 `Not Set`
   - 删除 App override

禁止通过“把上层值抄下来”表示恢复默认。
即使当前 Thread override 的 Provider / Model 与继承结果完全相同，只要用户没有点 `Use Default`，该 Thread override 仍应继续保留。

## 非目标

当前版本不支持：

1. Thread 记住每个 Provider 的历史模型选择
2. `reasoning / thinking` 的 App / Project 默认值
3. 无效 override 的自动 silent fallback
