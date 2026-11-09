# Design — Herdr pane 只读终端视口

父任务 `10-13-herdr-mobile-render/design.md` 是权威设计（§2 架构选择、§3.1 契约）。
本文件给出实现级细节与**已核实的 xterm API 事实**。

## 1. 为什么这条路可行（已核实的事实）

以下全部来自实际阅读 `third_party/xterm` 源码（xterm.dart 4.0.0 vendored）：

| 事实 | 位置 | 含义 |
| --- | --- | --- |
| `Terminal.write(String data)` | `src/terminal.dart:227` | 接受原始字符串，交给 `EscapeParser` 做完整 ANSI 解析 |
| `Terminal.resize(...)` | `src/terminal.dart:353` | 调用 `_mainBuffer.resize(...)` / `_altBuffer.resize(...)`，**内部触发 reflow** |
| `Buffer.resize(...)` → `reflow(...)` | `src/core/buffer/buffer.dart` + `src/core/reflow.dart:163` | `_LineReflow(oldWidth, newWidth)` 按旧宽度下的满行判断续行，正确重排软折行 |
| `TerminalView(readOnly: true)` | `src/terminal_view.dart:49` | 只读渲染；现有 `terminal_pane.dart` 已用同一参数 |
| `TerminalView(autoResize: true)` 默认 | `src/terminal_view.dart:34` | **必须改为 `false`**，由我们自己控制列数，否则视口会用布局尺寸二次 resize，与我们的 reflow 冲突 |
| `char_metrics.dart` | `src/ui/char_metrics.dart` | 已有字符宽度测量，复用它而不是自己写 `TextPainter` |
| `shortcuts.dart` ohos 补丁 | `README.cloudterminal.md` | 该 vendored 版本已处理 `TargetPlatform.ohos` |

**结论**：不需要新依赖、不需要改 vendored 源码、不需要平台通道。

## 2. 组件契约

`lib/widgets/herdr_pane_viewport.dart`（新增）

```dart
/// 渲染模式。
enum HerdrViewportMode {
  /// 按手机可视宽度重排（默认）。
  fitWidth,

  /// 保留桌面原始列宽，横向平移。
  rawColumns,
}

class HerdrPaneViewport extends StatefulWidget {
  const HerdrPaneViewport({
    super.key,
    required this.outputKey,
    required this.text,
    this.mode = HerdrViewportMode.fitWidth,
    this.sourceColumns,
    this.fontSize = 12,
    this.scrollController,
  });

  /// 标识一次完整的 pane read。变化 = 新内容，需要 reset。
  final String outputKey;

  /// 原始屏幕文本（来自 HerdrOutput.text），不做任何改写。
  final String text;

  final HerdrViewportMode mode;

  /// 桌面原始列数；只在 rawColumns 模式下使用。null → 由内容推断。
  final int? sourceColumns;

  final double fontSize;
  final ScrollController? scrollController;
}
```

关键设计决策：

- **传 `text` 而不是 `HerdrOutput`**：widget 不应知道协议模型，便于测试直接注入
  固定文本。
- **传 `outputKey` 而不是依赖 `text` 比较**：同一 pane 两次 read 可能返回完全
  相同的文本（GUI 无变化），用文本相等判断会漏掉"需要 reset"的语义。key 由
  调用方构造，例如 `'${paneId}:${source}:${lines}:${DateTime.now()}'` 不可取
  —— 见 §4。

## 3. 列数计算与 resize

```dart
@override
Widget build(BuildContext context) {
  return LayoutBuilder(
    builder: (context, constraints) {
      final metrics = _metrics(constraints);   // 见 §3.1
      final (cols, rows) = _targetGrid(metrics, constraints);
      _applyGrid(cols, rows);                  // 只在变化时 resize
      ...
    },
  );
}
```

### 3.1 字符宽高测量

复用 vendored 的 `TerminalMetrics`（`src/ui/char_metrics.dart`）：

```dart
final metrics = TerminalMetrics(style: _terminalStyle);
final charWidth = metrics.charWidth;
final lineHeight = metrics.height;
```

若该 API 的实际签名与预期不符，**回退方案**：用 `TextPainter` 测量单个
`'M'`（等宽字体下字符宽一致）与行高。回退实现必须放在一个私有方法里并注释
说明原因。

### 3.2 目标网格

```dart
int cols;
if (widget.mode == HerdrViewportMode.rawColumns) {
  cols = widget.sourceColumns ?? _inferColumns(widget.text);
} else {
  cols = (constraints.maxWidth / charWidth).floor();
}
cols = cols.clamp(20, 500);      // 与 terminal_pane.dart 的 clamp 保持一致
final rows = (constraints.maxHeight / lineHeight).floor().clamp(4, 300);
```

### 3.3 `_applyGrid` — 避免每帧 reflow

```dart
void _applyGrid(int cols, int rows) {
  if (cols == _cols && rows == _rows) return;   // 关键：否则每帧 reflow，卡顿
  _cols = cols;
  _rows = rows;
  _terminal.resize(cols, rows, 0, 0);           // pixel 参数传 0，与 terminal_pane.dart 一致
}
```

> `_applyGrid` 在 `build` 期间被调用（不 setState），只做终端状态更新；
> 渲染由 `TerminalView` 自行监听 `Terminal` 的可观察变化完成。

### 3.4 `rawColumns` 模式的横向平移

`TerminalView` 内部用自己的滚动处理（`scroll_handler.dart`、`infinite_scroll_view.dart`），
没有公开的横向滚动参数。因此 `rawColumns` 模式下：

- 固定 `cols = sourceColumns`（不做 fitWidth 计算）
- 外层裹 `InteractiveViewer(constrained: false, ...)` 或双向
  `SingleChildScrollView`（`scrollDirection: Axis.horizontal` 包一个固定高度
  的子 widget）
- **实现时优先尝试 `InteractiveViewer`**，因为它同时提供缩放与平移；若与
  `TerminalView` 的手势冲突（终端自身吃滚动事件），退回双向
  `SingleChildScrollView`。
- 手势冲突的具体结论必须写入完成记录——这是"未验证项"最可能出现的地方。

## 4. 写入策略（最容易出错的地方）

```dart
@override
void didUpdateWidget(HerdrPaneViewport old) {
  super.didUpdateWidget(old);
  if (old.outputKey != widget.outputKey) {
    _resetAndWrite(widget.text);       // 新的一次 read
  }
  // outputKey 相同 → 什么都不做。
  // 绝不追加：否则同一份文本会被反复写入，内容成倍叠加。
}

void _resetAndWrite(String text) {
  // Terminal 没有 public reset()，换实例是语义最干净的做法：
  // 旧网格、滚动位置、alt buffer 状态全部丢弃，不会残留。
  final fresh = Terminal(maxLines: _maxLines);
  fresh.write(text);
  setState(() => _terminal = fresh);
  _applyGrid(_cols, _rows);            // 新实例需要重新 resize 才能触发 reflow
}
```

### `outputKey` 由调用方如何构造

调用方（`herdr_pane_screen.dart`）在每次 `_load()` 成功后**生成一个新的 key**，
例如把自己维护的递增计数器或 `HerdrOutput` 实例的 `identityHashCode` 编码进去：

```dart
int _loadGeneration = 0;
// _load() 成功后：
_outputKey = '${widget.pane.paneId}#${++_loadGeneration}';
```

**不要**用 `DateTime.now()`（同一毫秒内的两次 read 会撞 key），也不要直接用
`text`（内容不变时会被误判为无变化，但用户确实点了刷新）。

### `maxLines`

`Terminal(maxLines: ...)` 决定回滚缓冲上限。取 `2000`（足够覆盖 UI 的
1000 行选择器上限，且内存可控）。**注意**：`maxLines` 过小会截断用户选择的
1000 行输出。

## 5. 与父任务 design §4.3 的关系

父任务提到用 `HerdrScroll` 显示"电脑端回看了 N 行"。本子任务**不重复实现**
该提示（那是子任务 1 的交付物），但需要：

- 接受调用方传入的 `scrollController`，让"跳到最新"能控制 App 内部视口
- 不与子任务 1 的回看标签在视觉上重叠

协同约定：回看标签由子任务 1 放在 `_sourceBar` 与视口之间（视口**之外**），
本视口不绘制任何提示条。

## 6. 屏幕层改动（`herdr_pane_screen.dart`）

```dart
// 替换 _outputView 的 SelectableText 分支
Expanded(
  child: HerdrPaneViewport(
    outputKey: _outputKey,
    text: output?.text ?? '',
    mode: _viewMode,
    sourceColumns: _sourceColumns,
    fontSize: _fontSize,
    scrollController: _scroll,
  ),
),
```

新增状态：

- `HerdrViewportMode _viewMode = HerdrViewportMode.fitWidth;`
- `double _fontSize = 12;`
- `String _outputKey = '';`
- `int? _sourceColumns;` ← 从 `HerdrController.layout(paneId)?.area.width` 取，
  取不到则 `null` 让视口自行推断

`_sourceBar` 增加：模式切换（`SegmentedButton` 或 `ChoiceChip`）与字号选择。

`rawColumns` 模式所需的 layout 数据：调用
`widget.herdr.loadLayout(pane.paneId)`（已存在，带缓存），**不新增协议请求**。

## 7. 测试策略

全部为 widget 测试，不依赖真机与真实 Herdr。

`test/herdr_viewport_test.dart`（新增）：

```dart
testWidgets('fitWidth resizes the terminal to the available columns', (tester) async {
  await tester.pumpWidget(_host(text: 'a' * 200, width: 400));
  final viewport = tester.state<HerdrPaneViewportState>(find.byType(HerdrPaneViewport));
  expect(viewport.debugCols, lessThan(200));   // 发生了重排
  expect(viewport.debugCols, greaterThan(20));
});

testWidgets('repeated build with the same outputKey does not duplicate content',
    (tester) async {
  await tester.pumpWidget(_host(text: 'hello', key: 'k1'));
  await tester.pumpWidget(_host(text: 'hello', key: 'k1'));
  final viewport = tester.state<HerdrPaneViewportState>(find.byType(HerdrPaneViewport));
  expect(viewport.debugBufferText, 'hello');   // 不是 'hellohello'
});

testWidgets('a new outputKey resets and rewrites', (tester) async {
  await tester.pumpWidget(_host(text: 'first', key: 'k1'));
  await tester.pumpWidget(_host(text: 'second', key: 'k2'));
  expect(viewport.debugBufferText, 'second');
});

testWidgets('handles empty, whitespace-only and very long single-line text',
    (tester) async {
  for (final text in <String>['', '   \n\n', 'x' * 6000]) {
    await tester.pumpWidget(_host(text: text, key: text));
    expect(tester.takeException(), isNull);
  }
});

testWidgets('parses ANSI colour instead of showing the escape sequence',
    (tester) async {
  await tester.pumpWidget(_host(text: '\x1b[31mRED\x1b[0m', key: 'k'));
  expect(viewport.debugBufferText, 'RED');       // 不含 ESC
});
```

> 为测试暴露 `debugCols` / `debugBufferText` 这类 `@visibleForTesting` 访问器，
> 从 `Terminal.buffer` 读取重构文本。不要为了测试把内部状态改成 public 字段。

`test/herdr_test.dart` 追加屏幕层测试：

- 刷新时旧内容仍可见
- 模式切换不抛异常

## 8. 非回归

- 不修改 `third_party/xterm` 任何文件。
- 不修改 `lib/widgets/terminal_pane.dart`（它有自己的 `Terminal` 实例与
  `onResize` 回调，与视口无关）。
- `HerdrController`、`HerdrActions`、协议帧零改动。
- 现有 `test/herdr_test.dart` 的模型/控制器/UI 用例保持通过。

## 9. 回滚

删除 `lib/widgets/herdr_pane_viewport.dart`，把 `_outputView` 恢复为
`SelectableText(output.text, ...)` 版本（注意：保留子任务 1 的 `text` 用法，
**不要**退回 `display`）。无协议与持久化影响。

## 10. ohos 注意事项（实现时必须遵守）

- 不使用 `Platform.isXxx` 做分支；如必须按平台区分，用
  `defaultTargetPlatform` 并显式包含 `TargetPlatform.ohos`。
- 不引入任何 `.ohos` 平台通道插件。
- `InteractiveViewer` 的手势在 ohos 上**未验证**，必须在完成记录中标注。
- `flutter test` 默认在 host 平台运行，**不能**证明 ohos 运行时行为；这一点
  必须在验收说明中如实写明。
