# Herdr 移动端渲染修复（父任务）

## 背景

用户在真机上使用 CloudTerminal 的 Herdr 工作区功能，反馈：

> "herdr的渲染问题 各种bug 现在是强制把电脑的窗口拉伸给手机看 自适应能力极差"
> "你只负责移动端app 优先确保ohos平台"

这不是主观感受，是代码事实。经过代码审查与真实 Herdr 探针输出比对，确认问题
集中在 **移动端 App（`lib/`）的渲染层**，与 agent 端、relay 端无关。

### 证据

**证据 1 — 当前用 `SelectableText` 当终端用**

`lib/screens/herdr_pane_screen.dart` 的 `_outputView`：

```dart
return Scrollbar(
  controller: _scroll,
  child: SingleChildScrollView(
    child: SelectableText(
      output.display,
      style: AppTheme.mono(12, color: scheme.onSurface),
    ),
  ),
);
```

没有终端仿真器、没有列宽概念、没有颜色、没有横向平移。文字只能按手机宽度
强制软折行。

**证据 2 — 真实 pane 输出是桌面列宽的硬折行**

`.build/pi-herdr/live-probe-final.txt` 中 `pane read wJ:p2 --source
recent-unwrapped --lines 20` 的真实输出：

```
── ⠴ Working ─────────────────────────────────────────────────────────────

──────────────────────────────────────────────────────────────────────────
D:\MyNewProjects\cloudterminal (codex/general-terminal)
↓18k 0.1%/256k (auto)                                  deepseek-v4.1-flash
```

这些行约 76 列宽。手机竖屏以 12pt 等宽字体大约只能容纳 38–42 列。结果：

- box-drawing 边框、进度条、表格被折成多段，完全错位
- TUI 界面（agent 的对话界面、状态栏）看起来像乱码
- 右侧被截断或挤压，用户必须横向拖动（但当前根本没有横向滚动）

**证据 3 — `HerdrOutput.display` 主动破坏版面**

`lib/models/herdr.dart`：

```dart
/// Herdr returns a trailing newline for a prompt-ready screen.
String get display => text.replaceAll(RegExp(r'\s+$'), '');
```

`\s+$` 会吃掉结尾**所有**空白和换行，包括屏幕底部的状态行、提示行所在的
垂直位置信息。终端的垂直空白是版面的一部分，不能当作"可裁剪的噪音"。

**证据 4 — 已有可用的滚动位置数据，但 UI 完全没用**

`HerdrScroll`（`offsetFromBottom` / `maxOffsetFromBottom` / `viewportRows`）
已从 agent 端传到 App，`HerdrPane.scroll` 已经解析，但 UI 从头到尾没有引用。
用户无法知道"我在看历史还是最新"，也无法一键回到最新。

**证据 5 — 每次 `_load()` 整体重建**

`_outputView` 在 `_loading && output == null` 时返回
`Center(child: CircularProgressIndicator())`，也就是每次刷新会清屏闪一下；
`setState` 后整个 `SelectableText` 重新 layout 500 行 × 76 列。

## 关键约束（本任务范围）

| 约束 | 说明 |
| --- | --- |
| **只改移动端 App** | 只有 `lib/` 与 `test/`。不改 `server/`、不改 relay、不改协议帧 |
| **ohos 平台优先** | Flutter SDK 为 `3.27.5-ohos-1.0.1`（Dart 3.11.5），不可使用该版本没有的 API |
| **不使用新依赖** | 不能引入需要平台通道的包；只能复用已 vendored 的 `third_party/xterm` |
| **无 ohos 真机** | 当前只连了 Android 真机（MEIZU 21）。ohos 结论必须诚实标注为"静态验证" |

### 已确认的技术资产

`third_party/xterm` 是 vendored 的 xterm.dart 4.0.0，包含**完整 ANSI 解析器、
终端模拟器和 `reflow.dart`**，并且已经为 ohos 打过补丁
（`shortcuts.dart` 处理 `TargetPlatform.ohos`）。关键 API 已核实存在：

- `Terminal.write(String)` — 接受原始字节，做完整 ANSI 解析
- `Terminal.resize(...)` — 触发 `reflow()`，按新列宽重新折行
- `TerminalView(readOnly: true)` — 只读渲染，已用于现有终端页
- `Buffer.lines` / `Buffer.viewHeight` — 已有 `Snapshot` 机制

结论：**用 `Terminal` 做 Herdr pane 的渲染后端是可行且不需要新依赖的**。
`Terminal.resize` 到手机真实列数后，reflow 会自动把 76 列的桌面输出重排成
手机宽度，并保留颜色与属性。

## 目标

### G1 — pane 输出必须按手机列宽正确呈现

- 用真实终端仿真器渲染，而不是 `SelectableText`。
- 保留 ANSI 颜色与文本属性。
- 默认按手机可视列数重排（reflow），不再出现错位的伪折行。
- 提供**「适配宽度」与「原始列宽 + 横向平移」两种模式**，并说明差异。

### G2 — 不破坏原始数据

- `pane read` 的原始 payload 必须原样进入渲染层。
- 不得再用 `\s+$` 之类的正则改写整段输出。
- 行尾空白、空行、硬折行位置等版面信息在渲染前保持完整。

### G3 — 滚动与刷新体验

- 刷新不清屏：保留当前内容直到新内容就绪再替换。
- 使用已有的 `HerdrScroll` 显示"当前不在最新"并提供一键回到最新。
- 长输出滚动流畅，不因每次 `setState` 全量重建而卡顿。

### G4 — 列表层自适应

- 工作区/标签/面板列表在窄屏不挤压、不截断关键信息。
- 长标题、长路径（`D:\MyNewProjects\cloudterminal (codex/general-terminal)`）
  有明确的软折行/省略策略，而不是把布局撑坏。

### G5 — ohos 优先且可验证

- 所有改动只用 Flutter 框架 API 与已 vendored 的 xterm，无平台通道。
- `flutter analyze` 与 `flutter test` 通过。
- 在 Android 真机上验证渲染（已连接的 MEIZU 21）。
- ohos 平台结论如实标注：本次无 ohos 设备，只做静态兼容性核查。

## 非目标

- 不实现 Herdr 的交互式 TUI 接管（`attach`/`takeover`）。
- 不新增 Herdr 推送流（仍为请求/响应 + 显式刷新）。
- 不改 agent 端的 `pane read` 参数或返回结构。
- 不改 Herdr 协议帧格式（`PROTOCOL_VERSION` 不变）。
- 不引入需要平台通道的第三方渲染/字体依赖。
- 不改动终端页（`terminal_pane.dart`）与 Claude/Codex 相关界面。

> **Scope change (2026-10-15, user-approved).** The three 「不新增 Herdr 推送流 /
> 不改 agent 端 `pane read` / 不改协议帧」 lines above were written when Herdr was
> believed to have no change feed. That premise is false at the socket level:
> herdr 0.9.3 protocol 22 exposes `events.subscribe`, including
> `pane.output_changed`. The user explicitly approved replacing the poll-only
> design with an edge-triggered push, and moving this task's structure refresh
> onto the same channel.
>
> Superseded by `.trellis/tasks/10-15-herdr-live-push/`:
>
> - `pane read` request/response shape is **unchanged**; what is added is
>   *when* it is triggered (on an event instead of a timer).
> - Protocol frames are extended **additively** (`herdr_watch` request,
>   `herdr_pane_output` / `herdr_structure` pushes); `PROTOCOL_VERSION` stays 1.
> - The 「只改移动端 App」 constraint no longer holds: this task now spans
>   `server/` as well, by explicit approval. The ohos-first and no-new-deps
>   constraints still hold.

## 子任务划分

| 子任务 | 交付物 | 可独立验证 |
| --- | --- | --- |
| `10-13-herdr-output-fidelity` | 原始输出保真 + 滚动位置 + 无清屏刷新 | 模型与控制器单测 |
| `10-13-herdr-pane-viewport` | 只读终端视口 widget（核心渲染修复） | widget 测试 + 真机渲染 |
| `10-13-herdr-list-ux` | 工作区/标签/面板列表的自适应布局 | widget 测试 |

依赖关系（非树结构表达，需显式声明）：

- `herdr-pane-viewport` **依赖** `herdr-output-fidelity`：视口需要拿到未经改写的
  原始文本与滚动位置数据。先做 fidelity，再做 viewport。
- `herdr-list-ux` 与另外两个子任务**无依赖**，可并行。

## 验收标准

1. 打开一个当前列宽约 76 的 pane，在手机竖屏下默认视图**不再出现错位的
   折行**：box-drawing 边框保持连续，表格列对齐。（对比修复前的截图/文字）
2. 切换"原始列宽"模式后可以横向平移，看到完整未重排的桌面版面。
3. ANSI 颜色在渲染中生效（用带颜色的真实 pane 验证，或注入固定 ANSI 样本）。
4. `HerdrOutput` 不再改写原始文本：以真实 payload 断言行尾空白与空行被保留。
5. 下拉刷新时旧内容不被清屏替换；仅在新数据到达后更新。
6. 当 `HerdrScroll.offsetFromBottom > 0` 时界面显示"已回看"并提供回到最新。
7. 长工作区标题与长路径在 360dp 宽度下不溢出、不产生 RenderFlex 溢出警告。
8. `flutter analyze` 无警告，`flutter test` 全部通过（含新增测试）。
9. ohos 兼容性结论写入任务记录：说明验证方式与未验证部分。

## 已定与仍需确认

已定：

- 渲染后端使用 vendored xterm 的 `Terminal`，不用 `SelectableText`。
- 默认模式为"适配手机宽度重排"，另提供原始列宽平移模式。
- 只改移动端，ohos 优先。

仍需确认（选保守默认，不阻塞实现）：

1. 重排模式下，行尾换行符是否保留？默认保留，由终端模拟器自然处理。
2. 是否需要在视口内直接发送输入？**默认不做**——输入仍走现有底部输入栏，
   避免视口交互与只读语义冲突。
