# Design — Herdr pane 输出保真

父任务 `10-13-herdr-mobile-render` 的 `design.md` 是权威设计。本文件只记录
本子任务的具体改动点与理由，不重新设计。

## 1. `HerdrOutput` 数据契约

### 现状

```dart
class HerdrOutput {
  final String text;
  String get display => text.replaceAll(RegExp(r'\s+$'), '');
  bool get isEmpty => display.isEmpty;
}
```

### 目标契约

```dart
class HerdrOutput {
  /// agent 返回的原始屏幕文本，含 ANSI 转义与原始折行。
  /// 这是渲染的唯一真源，任何消费者都不得改写它。
  final String text;

  /// 是否没有任何可见内容。仅用于空状态判断。
  /// 明确不再提供「改写后的文本」——那正是本任务要消除的缺陷。
  bool get isBlank => text.trim().isEmpty;
}
```

### 迁移步骤

1. 搜索 `display` 的全部引用：
   ```powershell
   Select-String -Path lib,test -Pattern "\.display\b" -Recurse
   ```
2. 对每个引用分类：
   - 用作**渲染输入**（`SelectableText(output.display, ...)`）→ 改为
     `HerdrOutput.text`；若该处最终会被视口取代，本任务先改为 `text` 以保证
     保真，视口子任务再替换 widget。
   - 用作**空状态判断**（`output.isEmpty`）→ 改为 `isBlank`。
3. `isEmpty` 的语义变化：原实现基于 `display`（已裁剪），新实现基于
   `text.trim()`。两者对"仅含空白"的输入行为一致，对"含内容但行尾空白"
   的输入更准确。**检查 `herdr_test.dart` 中 `parses pane output and trims
   the trailing newline`（约 222 行）用例**，它断言的正是被移除的行为，
   必须改写为"保留行尾换行"。

## 2. 刷新不清屏

`herdr_pane_screen.dart` 的 `_outputView`：

```dart
Widget _outputView(BuildContext context) {
  final output = _output;
  if (_loading && output == null) {          // 仅真正无内容时占位
    return const Center(child: CircularProgressIndicator());
  }
  if (output == null || output.isBlank) { ...空状态... }
  return ...渲染...;
}
```

关键改动：判断条件从 `_loading && output == null` 语义上保持不变（它本来就
要求 `output == null`），但当前代码在 `_load()` 中先 `setState(_loading=true)`
再 await，**`_output` 未被清空，所以实际上不会闪**——真正会闪的是首次加载与
`_load()` 后 `output` 被替换导致的重建。

因此本项的实际落点是：

- 确保 `_load()` **不**把 `_output` 置空
- 刷新期间的进度展现用已有 `if (_sending) const LinearProgressIndicator(...)`
  同款做法，新增 `if (_loading && _output != null)` 的细进度条
- 视口子任务会进一步消除全量重建的成本

> 实现者注意：不要为了"修闪屏"而引入不必要的状态。先用测试复现，再改。

## 3. `HerdrScroll` 回看提示

```dart
final scroll = _pane.scroll;
final reviewing = scroll != null && scroll.offsetFromBottom > 0;
```

展示：

```
电脑端回看了 ${scroll.offsetFromBottom} 行        [重新读取]
```

用 `Icons.history_rounded` + `surfaceContainerHigh` 底色的紧凑标签，放在
`_sourceBar` 之下、视口之上。

**语义边界（必须遵守）**：

- `HerdrScroll` 描述**电脑端 Herdr pane**的滚动位置。
- App 内部视口的滚动位置由视口自己管理（`ScrollController`）。
- UI 文案必须写"电脑端"或"Herdr"，不能写成"你已回看"——那会误导用户以为
  是手机端的滚动状态。
- `onJumpToLatest` 触发 `_load()`（重新读取最新内容），**不**承诺改变电脑端
  的滚动位置（Herdr CLI 没有提供该能力，不许伪造）。

## 4. 测试

### 模型测试（`test/herdr_test.dart`）

```dart
test('preserves trailing whitespace, blank lines and ANSI from pane read', () {
  const raw = '\x1b[32mOK\x1b[0m  \n\n\n┌───┐\n│   │\n\n';
  final output = HerdrOutput.fromJson(<String, dynamic>{
    'paneId': 'wJ:p2',
    'source': 'visible',
    'text': raw,
  });
  expect(output.text, raw);              // 零改写
  expect(output.text.endsWith('\n'), isTrue);
  expect(output.isBlank, isFalse);
});

test('a whitespace-only pane read is blank', () {
  final output = HerdrOutput.fromJson(<String, dynamic>{
    'paneId': 'wJ:p2', 'source': 'visible', 'text': '   \n\n  ',
  });
  expect(output.isBlank, isTrue);
});
```

同时更新原有的 `trims the trailing newline` 用例——该断言正是被本任务移除
的行为。

### Widget 测试

- 刷新期间已有输出仍然可见（不出现 `CircularProgressIndicator`）
- `offsetFromBottom > 0` → 出现含行数的回看提示
- `offsetFromBottom == 0` 或 `scroll == null` → 不出现该提示

复用 `test/herdr_test.dart` 中既有的 `HerdrController` 测试脚手架与
`test/support/fake_relay.dart`。

## 5. 非回归

- `HerdrController` 不改。
- `HerdrActions` 不改。
- 协议帧不改。
- `herdr_screen.dart`（列表）不改（那是子任务 3）。
