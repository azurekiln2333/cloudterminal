# Design — Herdr 工作区列表移动端自适应

父任务 `10-13-herdr-mobile-render/design.md` §4.4 给出方向。本文件给实现细节。
本子任务无外部依赖，可并行。

## 1. 工作区标题（`_WorkspaceTile`）

现状：

```dart
Row(children: [
  Flexible(child: Text(workspace.displayLabel,
      maxLines: 1, overflow: TextOverflow.ellipsis, ...)),
  if (workspace.focused) ...<Widget>[Icon(Icons.visibility_rounded, ...)],
]),
```

问题：`Row` 内混排标题与焦点图标，标题被压缩到一行。真实标签较长
（`qfli_studio_core`、`vaultwarden-backup`）。

改为：

```dart
Text(
  workspace.displayLabel,
  maxLines: 2,
  softWrap: true,
  overflow: TextOverflow.ellipsis,
  style: ...,
),
```

焦点标记**移出标题行**，放进下方已有的 `Wrap`（与状态 chip、计数、id 同排）。
理由：`Wrap` 本身就会换行，不会挤压标题；而且焦点信息属于"元信息"，
与状态 chip 同类。

```dart
Wrap(spacing: 6, runSpacing: 6, children: [
  HerdrStatusChip(status: workspace.agentStatus),
  if (workspace.focused)
    _MetaChip(icon: Icons.visibility_rounded, label: '电脑焦点'),
  Text('${workspace.tabCount} 标签 · ${workspace.paneCount} 面板', ...),
  Text(workspace.workspaceId, style: AppTheme.mono(10.5, ...)),
]),
```

## 2. 路径中段省略

新增私有 helper（**放在使用它的文件内，不进 `lib/util/`**，除非被发现有两处
以上需要——目前只有 `herdr_screen.dart` 与 `herdr_status.dart`，若两者都要用
则放进 `lib/util/format.dart`，该文件已存在）：

```dart
/// 保留首尾、省略中段的路径。窄屏下末段（项目名）信息量最大。
String ellipsizePath(String path, int maxChars) {
  if (path.length <= maxChars) return path;
  final parts = path.split(RegExp(r'[\\/]'));
  if (parts.length <= 2) {
    // 单段超长路径：尾部保留，因为末尾通常是文件名/项目名。
    return '…${path.substring(path.length - maxChars + 1)}';
  }
  final head = parts.first;                 // 通常是盘符或根
  final tail = parts.last;
  final budget = maxChars - head.length - tail.length - 2;  // 2 = 分隔符与省略号
  if (budget <= 0) return '…${path.substring(path.length - maxChars + 1)}';
  return '$head…${_tailSegments(parts, budget)}$_sep$tail';
}
```

**实现要求**：

- ohos 与 Windows 的路径分隔符都要处理（`\` 与 `/`）—— 本项目同时跑 Windows
  与鸿蒙/Android，且展示的是**电脑的**路径（通常是 Windows）。
- 不做 `\\?\` 前缀等特殊处理。
- 必须写单测覆盖：短路径原样、单段超长、多段长路径保留末段、
  混合分隔符。

## 3. 面板行分两行（`_PaneRow`）

现状：一行内 `图标 + [标题 / (paneId, agent, chip)]`。

改为：

```dart
Row(children: [
  Icon(...),
  const SizedBox(width: 10),
  Expanded(child: Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(pane.terminalTitle.isEmpty ? pane.paneId : pane.terminalTitle,
          maxLines: 1, overflow: TextOverflow.ellipsis),
      const SizedBox(height: 3),
      Wrap(spacing: 6, runSpacing: 4, children: [
        Text(pane.paneId, style: AppTheme.mono(10.5, ...)),
        if (pane.hostsAgent) Text(pane.name ?? pane.agent!, ...),
        if (pane.agentStatus != null)
          HerdrStatusChip(status: pane.agentStatus!, compact: true),
      ]),
    ],
  )),
  Icon(Icons.chevron_right_rounded, ...),
]),
```

关键：把内层的 `Row`（元信息）换成 `Wrap`，这是消除 overflow 的主要手段。

## 4. 标签页层级（新增）

`HerdrController.tabs(workspaceId)` 已可用，`HerdrTab` 已有
`label` / `number` / `focused` / `paneCount` / `agentStatus`。

在 `_WorkspaceTile._details` 中，把现有结构从：

```
面板
  [pane rows...]
Agents
  [agent rows...]
```

改为：

```
标签页
  ▸ t1 标签名  (2 面板)  [状态]  [焦点]
      [该标签下的 pane rows...]
Agents
  [agent rows...]
```

实现要点：

- `pane.tabId` 已经解析（`HerdrPane.tabId`）。按 `tabId` 把 `panes` 分组即可
  —— **不需要新请求**。
- tabs 为空时（例如未加载）退回现有的平铺 pane 列表，不要显示空标题。
- agent 列表保持现状（跨标签汇总），因为 `HerdrAgent.tabId` 已有但现有
  UI 是有意汇总展示；**不要**在本任务里改 agent 分组语义。
- **重要**：`HerdrScreen.initState` 只调用了 `herdr.refresh()`；tabs/panes 是在
  `_toggle()` 展开时通过 `loadWorkspace` 拉取的。确认 `loadWorkspace` 已同时
  拉 tabs 与 panes（它确实调用了 `herdrTabs` 与 `herdrPanes`）——无需改动。

## 5. 测试

在 `test/herdr_test.dart` 的 UI group 中追加：

```dart
testWidgets('workspace list fits a 360dp phone without overflow', (tester) async {
  tester.view.physicalSize = const Size(360 * 3, 800 * 3);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(_hostWith(longLabelWorkspace, longPathPane));
  expect(tester.takeException(), isNull);
});

testWidgets('expanding a workspace shows its tabs', (tester) async {
  // 断言 tab 标签文案出现，且该 tab 下的 pane 出现在其分区内
});
```

`ellipsizePath` 的单测放在 `test/format_test.dart`（若该文件不存在则新建，
或放入 `test/herdr_test.dart` 的模型 group，视现有组织方式而定）。

## 6. 非回归

- `HerdrController` 零改动。
- `HerdrScreen` 的导航、动作、确认对话框、FAB、`_UnavailableBanner` 不变。
- 现有 UI 测试 `lists real workspaces with counts and status` 与
  `expands a workspace to reveal panes and agents` 必须仍然通过——若因结构
  变化失败，更新断言而不是删除。

## 7. 回滚

改动限于 `lib/screens/herdr_screen.dart`、可能的两处路径展示、以及
`lib/util/format.dart`（若新增 helper）。回滚即恢复这些文件。
