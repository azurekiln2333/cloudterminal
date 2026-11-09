# Notes — Herdr 工作区列表移动端自适应

任务：`.trellis/tasks/10-13-herdr-list-ux`。范围严格为移动端 `lib/` + `test/`，
未改 `server/`、未加协议请求、未改 `HerdrController`。

## 1. `ellipsizePath` 放在哪里，为什么

放在 **`lib/util/format.dart`**（不是某个 widget 文件，也不是 `herdr_status.dart`）。

理由：

- `format.dart` 已经是全部路径/显示格式化的公共归属（`baseName`、`shortenPath`、
  `formatCost`…）。`ellipsizePath` 与既有 `shortenPath`（纯尾部截断）是同一类
  函数、同一层关注点，放一起让"路径怎么截断"只有一个 owner、两个策略可对比。
- 该函数是纯函数，放在无 Flutter 依赖的 `format.dart` 里可以直接单测
  （`test/format_test.dart`），不必为了测一个字符串函数而把整个 widget 依赖链
  拖进测试。
- design.md §2 允许两种落点：仅一处使用则留在原文件，两处以上则进
  `lib/util/format.dart`。虽然当前渲染侧只有 `HerdrPath` 一个调用点，但把纯函数
  和它的单测放在 `format.dart` 是既有 `shortenPath` 已经确立的约定；把它塞进
  `herdr_status.dart` 会让一个可单测的纯函数依赖 `package:flutter/material.dart`。

行为：保留头部（盘符/根）与末段，中段用 `…` 省略；`\` 与 `/` 都识别为分隔符
（PC 常为 Windows，手机为 ohos/Android）；单段超长或末段本身就超过预算时退回
尾部截断（`…<tail>`），因为此时无法同时保住首尾。中间段从靠近末段的一侧向外
保留——紧邻项目名的那一段上下文信息量最大。

`shortenPath`（原尾部截断）**保留未动**，仍被 `session_card.dart` 使用；
`HerdrPath` 改用 `ellipsizePath`（默认 `maxChars = 44`）。

## 2. 实测的最窄宽度

用 360dp 复现测试 + 一个临时 probe（已删除）在修复后的布局上逐档验证：

| 宽度 | 修复后 `takeException()` |
| --- | --- |
| 360dp | null |
| 320dp | null |
| 300dp | null |
| 280dp | null |
| 260dp | null |
| 240dp | null |

**验证到的最窄宽度：240dp**（内容：超长工作区标签 + 长 Windows 路径 +
`/home/ohos/...` 正斜杠路径 + 长 agent 名 + 长 pane 标题）。

**复现先于修复**：在 360dp 展开工作区的旧布局上，`tester.takeException()`
返回
`FlutterError: A RenderFlex overflowed by 170 pixels on the right.`
（`_PaneRow` 内层元信息 `Row`）。把内层 `Row` 换成 `Wrap` 并将工作区标题
改为两行后，同一测试通过。复现记录见下方第 4 节。

## 3. 是否改动了既有测试断言

**没有删除或改写任何既有断言。** 既有两个 Herdr UI 测试
`lists real workspaces with counts and status` 与
`expands a workspace to reveal panes and agents` 原文未动、仍然通过。

新增内容（`test/herdr_test.dart`）：

- fixture `tabJson(...)`；`paneJson(...)` 增加可选 `tabId` / `cwd` /
  `terminalTitle` 参数（默认值保持原行为，不破坏既有调用）。
- 测试 harness `_pumpHerdr` / `_scriptHerdrSocket` 增加可选 `tabs` 参数；
  原来 `herdr_tabs` 分支硬编码返回空数组，现在默认仍为空数组，只有显式传
  `tabs` 才返回标签——既有用例行为不变。
- 新增 3 个 UI 测试：
  - `workspace list fits a 360dp phone without overflow` — 360dp、长标题、
    长路径，折叠与展开后都断言 `tester.takeException()` 为 null。
  - `expanding a workspace groups panes under their tabs` — 断言 `标签页` 标题、
    各 tab 文案与面板数、tab 下的 pane。
  - `falls back to a flat pane list when no tabs are reported` — tabs 为空时
    显示 `面板` 平铺、不出现 `标签页` 标题。
- 新增 `test/format_test.dart`：`ellipsizePath` 单测（短路径原样、Windows 长
  路径保首尾、正斜杠长路径、混合分隔符、单段超长、末段超预算的兜底）+
  `baseName` / `shortenPath` 回归。

## 4. 实现摘要（P1–P4）

- **P1 标题**：`_WorkspaceTile` 标题由 `Row(Flexible(Text(maxLines:1)))` 改为
  直接 `Text(maxLines: 2, softWrap: true)`；焦点图标 `电脑焦点` 移入下方已有的
  `Wrap`，成为 `_MetaChip`（不再挤压标题）。
- **P2 路径**：`HerdrPath` 使用 `ellipsizePath`，中段省略、保留末段；
  同时处理 `\` 与 `/`。
- **P3 pane 行**：`_PaneRow` 内层元信息 `Row` 改为 `Wrap`，标题一行、元信息
  （paneId / agent / 状态 chip）另起一行（`runSpacing: 4`）。
- **P4 标签层级**：`_WorkspaceTile._details` 读取 `herdr.tabs(workspaceId)`；
  tabs 非空时渲染 `标签页` 标题，每个 tab 一个 `_TabHeading`
  （图标 + 标签名 + `(N 面板)` + 状态 chip + 可选焦点标记），其下按
  `pane.tabId` 分组渲染该 tab 的 pane；tabId 不在标签列表中的 pane 仍会在标签
  分组之后平铺渲染，避免数据消失。tabs 为空时退回原有平铺 pane 列表，不显示
  `标签页` 标题。Agents 分组语义未改（仍跨标签汇总）。

## 5. 影响面 / 回滚

改动文件：

- `lib/util/format.dart`（新增 `ellipsizePath` + `_middleSegments`）
- `lib/widgets/herdr_status.dart`（`HerdrPath` 使用中段省略）
- `lib/screens/herdr_screen.dart`（标题 / pane 行 / `_details` / 新增
  `_TabHeading`、`_MetaChip`）
- `test/herdr_test.dart`（fixture / harness / 新增测试）
- `test/format_test.dart`（新增）

回滚 = 恢复这四个文件；无持久化状态、无协议改动、无 `HerdrController` 改动。

## 6. 验证结果（实际命令输出）

```
$ flutter analyze
Analyzing cloudterminal...
No issues found! (ran in 3.0s)

$ flutter test
00:03 +109: All tests passed!
```

（`flutter test` 期间 `node_integration_test.dart` 正常连接本地 Node agent 并
打印预期的 `bad credentials` / `pane_not_found` 脚本化警告；全部 109 个测试
通过。）

## 7. 未验证 / 限制

- 真机目视确认未做（无 Android/ohos 设备接入）。证据为 widget 测试 +
  `flutter analyze`，未声明真机渲染。
- 并行子任务 `10-13-herdr-pane-viewport` / `10-13-herdr-output-fidelity` 在
  本次实现期间同时编辑了 `test/herdr_test.dart` 与 `lib/models/herdr.dart`，
  出现过短暂的编译中间态；最终三方收敛后上述全套测试通过。
