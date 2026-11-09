# Herdr 工作区列表移动端自适应（子任务）

父任务：`10-13-herdr-mobile-render`。只改移动端 `lib/` 与 `test/`。

## 背景

用户投诉"自适应能力极差"。除了 pane 输出（由 `10-13-herdr-pane-viewport`
处理），工作区/标签/面板列表层也有多个在窄屏上挤压、截断或溢出的问题。

## 问题

### P1 — 工作区标题被单行省略截断

`lib/screens/herdr_screen.dart` 的工作区标题：

```dart
Flexible(
  child: Text(
    workspace.displayLabel,
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    ...
  ),
),
```

真实工作区标签包含较长的中文名与项目名（例如
`qfli_studio_core`、`vaultwarden-backup`）。窄屏下 `maxLines: 1` 会把
有辨识度的部分直接切掉，用户无法区分同类工作区。

### P2 — 路径按尾部截断

`HerdrPath`（`lib/widgets/herdr_status.dart`）与 pane 行中的 cwd 展示。
真实路径例如：

```
D:\MyNewProjects\cloudterminal
```

长路径的**末段（项目名）最有信息量**，尾部截断恰好丢掉它。

### P3 — pane 行信息挤压

`_PaneRow` 在一行内同时放：图标、标题、paneId、agent 名、状态 chip。
窄屏下这些元素互相挤压，可能产生 `RenderFlex overflowed`。

### P4 — 标签页层级不可见

`HerdrController.tabs(workspaceId)` 与 `HerdrTab` 已完整可用
（`tabCount`、`tabId`、`label`、`focused`、`agentStatus` 都解析了），
但 `_WorkspaceTile._details` **只渲染 panes 和 agents，完全没有渲染 tabs**。
用户看到"N 标签"却看不到标签本身。

## 目标

### G1 — 窄屏不溢出

- 360dp 宽度（典型手机竖屏）下不产生 `RenderFlex overflowed`。
- 用 `tester.takeException()` 断言。

### G2 — 长文本有明确策略

- 工作区标题：`maxLines: 2` + `softWrap: true`，允许两行而不是直接省略。
- 路径：中段省略，保留盘符/根与末段；或分两行展示。
- pane 行：标题一行、元信息（paneId / agent / 状态）另起一行。

### G3 — 标签页层级可见

- 展开工作区后展示 tab 列表（label / 编号 / 面板数 / 焦点 / 状态）。
- 已有数据全部可用，**不需要新的协议请求或控制器改动**。

## 非目标

- 不改 pane 输出的渲染（那是 `10-13-herdr-pane-viewport`）。
- 不改 pane 输出的保真与刷新（那是 `10-13-herdr-output-fidelity`）。
- 不新增 Herdr 协议请求。
- 不改 `HerdrController` 的缓存逻辑（`tabs()` 已可用）。
- 不改抽屉导航结构与既有目的地的语义。

## 验收标准

1. 360dp 宽度的 widget 测试中，工作区列表（含长标题、长路径）不产生
   `RenderFlex overflowed`：`tester.takeException()` 为 null。
2. 长工作区标题最多显示两行且不截断单词中部。
3. 长路径在窄屏显示时仍能看到末段（项目名）。
4. 展开工作区后能看到其标签页列表，包含标签名与面板数。
5. 面板行的标题与元信息分两行，窄屏不挤压。
6. `flutter analyze` 干净；`flutter test` 全绿。
7. 现有 Herdr 列表测试（`lists real workspaces with counts and status`、
   `expands a workspace to reveal panes and agents`）仍通过。

## 依赖

与另外两个子任务**无依赖**，可并行进行。

## 已定与仍需确认

已定：

- 不用新协议请求，标签数据来自已有的 `herdrTabs` / `HerdrController.tabs()`。
- 不做激进重设计，只修自适应与信息缺失。

仍需确认（保守默认）：

1. 标签页是平铺列表还是可折叠分组？默认**平铺**，每个标签作为一个分区标题，
  其下的 pane 归入该标签，保持与现有 `_details` 结构最小的改动量。
2. 路径展示：默认中段省略（保留首尾），实现一个私有 helper，不引入依赖。
