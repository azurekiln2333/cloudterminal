# Herdr pane 输出保真：停止破坏原始屏幕文本（子任务）

父任务：`10-13-herdr-mobile-render`。只改移动端 `lib/` 与 `test/`。

## 背景

Herdr pane 的原始输出在到达渲染层之前被两处代码改写，导致终端版面信息丢失。
本子任务先把"数据保真"这条链路修正，为视口子任务提供正确的输入契约。

## 问题

### P1 — `HerdrOutput.display` 用正则改写整段输出

`lib/models/herdr.dart`：

```dart
String get display => text.replaceAll(RegExp(r'\s+$'), '');
```

`\s+$` 会吃掉结尾所有空白与换行。终端的垂直空白是版面的一部分：屏幕底部
状态行、提示行的位置信息被抹掉，空行被压缩。

### P2 — 刷新时清屏

`lib/screens/herdr_pane_screen.dart` 的 `_outputView`：

```dart
if (_loading && output == null) {
  return const Center(child: CircularProgressIndicator());
}
```

每次 `_load()` 触发 `setState` + `_loading = true` 时，已有内容被
loading 占位替换，视觉上闪屏并丢失阅读位置。

### P3 — 已有的滚动位置数据完全未被使用

`HerdrScroll`（`offsetFromBottom` / `maxOffsetFromBottom` / `viewportRows`）
已从 agent 端传输并被 `HerdrPane.scroll` 正确解析，但整个 UI 从未引用。
用户不知道电脑端当前是否处于回看状态。

## 目标

### G1 — 原始文本零改写

- `HerdrOutput.text` 是渲染的唯一真源，不得被正则改写。
- `display` 不得再作为渲染输入。
- 行尾空白、空行、硬折行位置在进入渲染层时保持完整。

### G2 — 刷新不清屏

- 已有内容在刷新期间保持可见。
- 仅当确实没有任何内容时显示 loading 占位。
- 刷新期间用细进度条（已有的 `LinearProgressIndicator` 模式）表达进行中。

### G3 — 诚实呈现电脑端滚动位置

- `HerdrScroll.offsetFromBottom > 0` 时，界面显示"电脑端回看了 N 行"这一事实。
- 提供触发重新读取的入口。
- **必须区分**：Herdr 侧的滚动位置 ≠ App 内部视口的滚动位置，不得混为一谈。

## 非目标

- 不实现终端视口（那是 `10-13-herdr-pane-viewport`）。
- 不改列表布局（那是 `10-13-herdr-list-ux`）。
- 不改协议帧、不改 agent 端。
- 不引入新依赖。

## 验收标准

1. `HerdrOutput` 以真实 `pane read` payload 为输入时，`text` 保留：
   - 行尾空格
   - 连续空行
   - 结尾换行
   - ANSI 转义序列（`\x1b[...m`）
2. `display` 不再被 `herdr_pane_screen.dart` 用于渲染。
3. 刷新（`_load()`）期间，已有输出**不**被 `CircularProgressIndicator` 替换。
4. `HerdrScroll.offsetFromBottom > 0` 时出现回看提示文案，包含具体行数。
5. `HerdrScroll` 为 null 或 `offsetFromBottom == 0` 时**不**显示回看提示。
6. `flutter analyze` 干净；`flutter test test/herdr_test.dart` 通过。
7. 新增测试覆盖 G1 与 G3；P2 由 widget 测试覆盖。

## 与其他子任务的关系

- 本子任务是 `10-13-herdr-pane-viewport` 的**前置**：视口依赖本任务确定的
  `HerdrOutput` 数据契约。
- 与 `10-13-herdr-list-ux` 无依赖。

## 已定与仍需确认

已定：

- `text` 为唯一真源，`display` 退出渲染路径。
- 刷新不清屏。
- 滚动位置如实呈现，不混淆 Herdr 侧与 App 侧。

仍需确认（保守默认）：

1. `display` 是删除还是保留为"是否为空"判断？
   默认：若 `isEmpty` 已能覆盖，则删除 `display` 并更新测试；否则保留但
   移除其改写行为并改名以免误导。
2. 回看提示的触发点：默认显示在视口右上角的小标签，点击触发重新读取。
