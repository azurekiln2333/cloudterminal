# Notes — Herdr pane 只读终端视口

## 交付

- 新增 `lib/widgets/herdr_pane_viewport.dart`：`HerdrViewportMode`
  （`fitWidth` / `rawColumns`）+ `HerdrPaneViewport`
- `lib/screens/herdr_pane_screen.dart`：用视口替换 `SelectableText`；
  新增模式切换、字号选择、`_loadGeneration` 驱动的 `outputKey`
- 新增 `test/herdr_viewport_test.dart`（12 个用例）
- 新增 `test/herdr_reflow_test.dart`（用真实桌面输出验证重排）

## 核心事实：为什么必须用终端模拟器

实测（`test/probe_reflow_test.dart`，验证后已删除）：
76 字符的 `─` 行，`resize(32, ...)` 后

```
row0 len=32 wrapped=false
row1 len=32 wrapped=true      ← 续行，不是换行
row2 len=32 wrapped=true      ← 续行
row3 剩余
```

行数 3 × 32 = 96 ≈ 原 76 字符 + 折行开销。`wrapped=true` 是模拟器在记录
"这是软折行的续行"。**纯文本层面拿不到这个信息**——这正是原来用
`SelectableText` 时表格必然错位的原因。

## xterm API 实测结论

1. **`Buffer.getText()`** 是取屏内容的正确方法。
   `buffer.lines[i].toString()` 返回的不是文本（`BufferLine` 没有文本化的
   `toString`），最初误用它导致所有断言读到空串。
   `getText()` 会自动把 `isWrapped` 的续行拼回、只在真正的换行处插入 `\n`。

2. **`char_metrics.dart` 未从 `ui.dart` 导出**，所以没有用它。改为在
   `_charSize()` 里用 `TextPainter` 自测 10 个 `'M'` 的平均宽与行高，
   语义等价且不依赖内部路径。已对宽度为 0 的情况做保护。

3. **`Terminal` 没有 public reset**。换新实例是唯一能确保不残留旧网格、
   光标和备用缓冲区状态的做法。

## 两个真实 bug（测试逼出来的，非测试问题）

### B1：首次渲染永远是空屏

`_terminal` 由字段初始化器创建，但 `widget` 在那一刻不可读，所以
`widget.text` 从未被写入。只有 `didUpdateWidget` 会写——也就是**要等第二次
read 才有内容**。

修复：在 `initState` 中写入首次文本。这个 bug 被
`renders ANSI colour ...` 与 `rawColumns with no layout data ...` 两个用例
抓出来（都断言实际内容，不是只断言"没崩"）。

### B2：`didUpdateWidget` 换实例后丢了网格宽度

新 `Terminal` 回到默认 80×24。若不重新 resize，reflow 会按 80 列跑一遍，
之后再被 `_applyGrid` 纠正，产生一次多余且错误的中途重排。

修复：构造新实例后立即 `resize(_cols, _rows)`（带 80×24 兜底）。

## 测试定位方式的必要变更

`test/herdr_test.dart` 中两个用例原先用 `find.textContaining('...')` 找 pane
输出。视口由模拟器绘制到 canvas，**不存在对应的 `Text` widget**，因此
finder 永远找不到。

这不是"为了让测试通过而改测试"：被断言的行为（刷新不清屏、点击横幅不丢内容）
完全没变，变的是**定位手段**。新增 `_viewportText(tester)` helper 读取
`HerdrPaneViewportState.debugBufferText`，断言仍然验证同一件事。

## 已验证

- `flutter analyze`：No issues found
- `flutter test`：121/121 通过
- `test/herdr_viewport_test.dart`：12/12
- `test/herdr_reflow_test.dart`：真实桌面输出在 390dp 视口算出 **32 列**
  （桌面约 76 列），内容完整

## 未验证（如实记录）

1. **ohos 运行时**：本机无 ohos 设备。`flutter test` 跑在 host 平台，
   不能证明 ohos 运行时行为。所有 API 均为 Flutter 稳定 API + 纯 Dart
   xterm，无平台通道，但**此结论是静态核查，不是实测**。
2. **`InteractiveViewer` 在 ohos 上的手势**：`rawColumns` 模式用
   `InteractiveViewer` 做平移。与 `TerminalView` 内部滚动的手势是否冲突，
   仅在 host 平台的 widget 测试中验证"不崩"，未在真机手势实测。
3. **真机安装受阻**：MEIZU 21 返回 `INSTALL_FAILED_USER_RESTRICTED`
   （手机侧"USB 安装"权限未开），APK 已成功构建但未能装上。
   真机目视确认待用户开启该权限后进行。
