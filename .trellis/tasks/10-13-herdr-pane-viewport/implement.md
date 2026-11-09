# Implement — Herdr pane 只读终端视口

先读父任务 `10-13-herdr-mobile-render/design.md` §2–§3，再读本目录
`design.md`（含已核实的 xterm API 事实与写入策略）。

## 硬性前置

- [ ] 子任务 `10-13-herdr-output-fidelity` 已完成。确认
      `lib/models/herdr.dart` 的 `HerdrOutput.text` 不再被改写，
      且 `herdr_pane_screen.dart` 已用 `output.text`。
      未完成则**不要开工**——视口会拿到被裁剪的文本。

## 步骤

- [ ] **1. 核实 xterm API**

```powershell
Select-String -Path third_party/xterm/lib/src/ui/char_metrics.dart -Pattern "class|charWidth|height"
Select-String -Path third_party/xterm/lib/src/ui/terminal_view.dart -Pattern "autoResize|readOnly|scrollController"
```

确认 `TerminalMetrics` 的实际签名。若与 `design.md` §3.1 不符，用 `TextPainter`
回退方案并在代码注释说明。

- [ ] **2. 新增 `lib/widgets/herdr_pane_viewport.dart`**
  - `HerdrViewportMode` 枚举（`fitWidth` / `rawColumns`）
  - `HerdrPaneViewport` widget，契约见 `design.md` §2
  - `_applyGrid`：仅在 cols/rows 变化时 `resize`（`design.md` §3.3）
  - `didUpdateWidget` + `_resetAndWrite`：`outputKey` 驱动（`design.md` §4）
  - `@visibleForTesting` 访问器 `debugCols` / `debugBufferText`

- [ ] **3. `fitWidth` 模式**（`design.md` §3.2）
  - `LayoutBuilder` + 字符宽高 → 列数
  - `clamp(20, 500)`，行数 `clamp(4, 300)`
  - `TerminalView(readOnly: true, autoResize: false)`

- [ ] **4. `rawColumns` 模式**（`design.md` §3.4）
  - 优先 `InteractiveViewer`，手势冲突则退回双向 `SingleChildScrollView`
  - 原始列数来源：`widget.sourceColumns` → `_inferColumns(text)` → `fitWidth` 回退
  - **把最终选择与手势冲突的实测结论写进 `notes.md`**

- [ ] **5. 改 `lib/screens/herdr_pane_screen.dart`**（`design.md` §6）
  - 用 `HerdrPaneViewport` 替换 `SelectableText` 分支
  - 新增 `_viewMode` / `_fontSize` / `_outputKey` / `_sourceColumns` 状态
  - `_load()` 成功后递增 `_loadGeneration` 并重建 `_outputKey`
  - `_sourceBar` 增加模式切换与字号选择
  - 用 `widget.herdr.loadLayout(pane.paneId)` 取 `area.width`
    （复用缓存，**不新增协议请求**）

- [ ] **6. 测试**

新增 `test/herdr_viewport_test.dart`，覆盖 `design.md` §7 的全部五个用例：
列数重排、同 key 不重复、新 key reset、边界文本不崩、ANSI 解析。

在 `test/herdr_test.dart` 追加屏幕层用例（刷新不清屏、模式切换不抛异常）。

- [ ] **7. 验证**

```powershell
cd D:\MyNewProjects\cloudterminal
flutter analyze
flutter test
```

- [ ] **8. Android 真机验证**

```powershell
flutter devices
flutter run -d <android-device-id>
```

实际打开一个真实 Herdr pane（例如 `wJ:p2`），对照 `.build/pi-herdr/live-probe-final.txt`
中约 76 列的原始输出：

- 边框是否连续
- 表格是否对齐
- 颜色是否生效
- 切换 `rawColumns` 后能否横向平移

把真机观察结果写入 `notes.md`。

## 输出记录（`notes.md` 必须包含）

1. `TerminalMetrics` 实际签名 / 是否走了 `TextPainter` 回退
2. `rawColumns` 最终用的平移方案，以及手势是否冲突
3. 真机观察结果（含未验证项，例如 ohos 未测）
4. `outputKey` 的构造方式

## 回滚

删除新 widget 文件，`_outputView` 恢复 `SelectableText(output.text, ...)`。
**不要**退回 `output.display`。

## 完成标准

- `flutter analyze` 无警告
- `flutter test` 全部通过（含五个视口用例）
- 真机验证已执行并记录
- ohos 部分明确标注为静态核查 / 未验证
