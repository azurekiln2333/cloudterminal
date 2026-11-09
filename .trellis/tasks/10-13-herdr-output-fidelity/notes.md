# Notes — Herdr pane 输出保真（子任务 1）

供子任务 `10-13-herdr-pane-viewport` 使用的输出契约。

## 1. `HerdrOutput` 的最终形态（`lib/models/herdr.dart`）

```dart
class HerdrOutput {
  final String paneId;
  final HerdrReadSource source;

  /// agent 返回的原始屏幕文本，含 ANSI 转义与原始折行。
  /// 唯一真源，任何消费者都不得改写它。
  final String text;

  /// 是否没有任何可见内容。仅用于空状态判断，不提供改写后的文本。
  bool get isBlank => text.trim().isEmpty;
}
```

- `display` **已删除**。`RegExp(r'\s+$')` 改写不再存在。
- `isEmpty` **已删除**，替换为 `isBlank`（`text.trim().isEmpty`）。语义等价于旧的
  `isEmpty`，但不再经过任何文本改写。
- `text` 保留行尾空白、连续空行、结尾换行与 ANSI 转义序列，零改写。
- 视口子任务应把 **`HerdrOutput.text`** 直接喂给 `Terminal.write()`。

## 2. `herdr_pane_screen.dart` 传入渲染的表达式

- 渲染输入：**`output.text`**（`SelectableText(output.text, ...)`）。
  代码中带注释说明「原始文本，永不改写」。
- 视口子任务会把 `SelectableText` 换成只读 `TerminalView`，但输入仍必须是
  `output.text`，不得回退到任何裁剪版本。
- 刷新（`_load()`）**不清空 `_output`**：只在 `herdr.read()` 返回后才
  `setState(() => _output = output)`。刷新期间旧内容保持可见。
- 刷新进行中（`_loading && _output != null`）显示细 `LinearProgressIndicator`，
  与 `_sending` 进度条复用同一行。仅在 `output == null` 时显示
  `CircularProgressIndicator` 占位。

## 3. 空状态判断

- **`output.isBlank`**（`output == null || output.isBlank` → 空状态视图）。
- 不再使用 `output.isEmpty` 或任何基于 `display` 的判断。

## 4. 回看提示（P3）

- 触发：`_pane.scroll != null && _pane.scroll!.offsetFromBottom > 0`。
- 文案：`电脑端回看了 N 行`，配 `Icons.history_rounded`，底色
  `surfaceContainerHigh`，位于 `_sourceBar` 与视口之间。
- 语义边界：`HerdrScroll` 描述**电脑端 Herdr pane** 的滚动位置，不是 App 内部
  视口的滚动位置。文案明确写「电脑端」。
- 点击「重新读取」触发 `_load()`，**不**声称改变电脑端滚动位置。
- `scroll == null` 或 `offsetFromBottom == 0` 时不显示该提示。

## 5. 测试

- `test/herdr_test.dart`：
  - `Herdr models`：`parses pane output and preserves the trailing newline`、
    `preserves trailing whitespace, blank lines and ANSI from pane read`、
    `a whitespace-only pane read is blank`。
  - `Herdr pane screen`：刷新不清屏、回看提示 `>0` / `==0`、点击重新读取不清屏。
- 验证结果：`flutter analyze` 干净；`flutter test test/herdr_test.dart` 45 passed；
  `flutter test` 152 passed。
