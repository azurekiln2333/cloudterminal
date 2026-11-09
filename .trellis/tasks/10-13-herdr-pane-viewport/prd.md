# Herdr pane 只读终端视口（子任务）

父任务：`10-13-herdr-mobile-render`。**这是本次修复的核心**。只改移动端
`lib/` 与 `test/`。

## 背景

用户投诉的"强制把电脑的窗口拉伸给手机看、自适应能力极差"，根因就在这一层：
`lib/screens/herdr_pane_screen.dart` 用 `SelectableText` 渲染终端输出。

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

`SelectableText` 是文本控件，不是终端控件：没有列宽概念、没有 ANSI 解析、
没有字符网格、没有 reflow。桌面 `pane read` 输出是**约 76 列的硬折行**，
塞进约 40 列的手机竖屏后，box-drawing 边框、进度条、表格全部错位。

## 问题

### P1 — 无终端语义，软折行与硬换行不可区分

`pane read` 纯文本不区分"因到达列宽而换行"和"程序显式输出换行"。因此：

- 按手机宽度软折行 → 76 列表格被当作 76 个独立短行，仍然错位
- 不折行 → 就是当前的"拉伸电脑窗口"

**纯文本层面无解，必须使用终端模拟器。**

### P2 — 无 ANSI 颜色

agent 返回的原始文本含 ANSI 转义序列，`SelectableText` 会原样显示为乱码或
丢失全部颜色属性。

### P3 — 无可选渲染模式

用户无法在"按手机宽度重排"与"保留桌面原始列宽横向平移"之间选择。

### P4 — 无缩放，无回看定位

无法调整字号以容纳更多列；无法知道当前是否在看最新内容。

## 目标

### G1 — 真实终端渲染

- 使用 vendored `third_party/xterm` 的 `Terminal` 作为渲染后端。
- 完整的 ANSI 解析：颜色、粗体、反显、光标属性。
- `TerminalView(readOnly: true)` 渲染，**不允许**通过视口输入（输入仍走
  现有底部输入栏）。

### G2 — 按手机列宽重排（默认）

- 用 `LayoutBuilder` 得到可用宽度，按等宽字符宽度计算列数。
- `Terminal.resize(cols, rows, ...)` 触发 `reflow()`，让终端按**真实终端语义**
  正确重排 76 列的桌面输出。
- 重排后 box-drawing 边框连续、表格列对齐。

### G3 — 原始列宽模式

- 提供 `rawColumns` 模式：保留桌面原始列数，横向平移查看未重排的版面。
- 原始列数优先从 `HerdrLayout.area.width` 取得（复用
  `HerdrController.loadLayout`，不新增协议请求）；取不到时按内容最大行宽
  推断；两者都失败时回退到 `fitWidth` 且**不阻塞渲染、不报错**。

### G4 — 生命周期与写入正确

- `Terminal` 实例跨 `build` 复用，不重建。
- 一次新的 `pane read` 结果 → reset 后全量写入；**绝不**把同一份文本重复
  append（否则内容会重复叠加）。
- 宽度变化才 `resize`，避免每帧 reflow。

### G5 — 缩放与定位

- 字号可调（影响列数计算，触发 resize 与 reflow）。
- 回看提示与"回到最新"入口（与子任务 1 的回看提示协同，不冲突）。

### G6 — ohos 优先

- 只用 Flutter 框架稳定 API 与 vendored xterm，无平台通道、无新依赖。
- 不使用 Flutter 3.27.5-ohos-1.0.1 不存在的 API。

## 非目标

- 不修改 vendored xterm 源码（`third_party/xterm`）。
- 不实现 Herdr 交互式 TUI 接管。
- 不通过视口发送输入。
- 不改协议、不改 agent 端。
- 不改列表层（那是 `10-13-herdr-list-ux`）。

## 依赖

**必须先完成 `10-13-herdr-output-fidelity`。** 否则视口拿到的仍是被
`HerdrOutput.display` 裁剪过的文本，重排结果依然错误。

## 验收标准

1. `fitWidth` 模式下，给定约 76 列的桌面输出，终端列数等于手机可用列数，
   box-drawing 边框在渲染结果中连续（widget 测试断言列数；真机目视断言外观）。
2. ANSI 颜色生效（用含 `\x1b[31m` 等序列的固定样本断言属性被解析，或在真机
   用带颜色的真实 pane 目视确认）。
3. `rawColumns` 模式可横向平移到未重排内容的右侧边界。
4. 同一份输出重复 `build` **不**产生重复内容叠加（widget 测试）。
5. 宽度变化（旋转/分屏/字号变更）触发 `resize` 且不抛异常。
6. 空文本、仅空白文本、超长单行（>5000 字符）均不崩溃。
7. 渲染层输入 === `HerdrOutput.text`（子任务 1 的产物），无正则改写。
8. `flutter analyze` 干净；`flutter test` 全绿。
9. Android 真机（MEIZU 21）上实际打开真实 Herdr pane 验证。
10. ohos 结论如实标注验证方式与未验证部分。

## 已定与仍需确认

已定：

- 用 `Terminal` + `TerminalView(readOnly: true)`，不用 `SelectableText`。
- 默认 `fitWidth`，可选 `rawColumns`。
- 不通过视口输入。

仍需确认（保守默认）：

1. reset 方式：默认**换新 `Terminal` 实例**（`Terminal` 无 public reset），
   语义最干净、不残留旧网格。
2. 字号档位：默认 10 / 11 / 12 / 13 / 14，默认 12（与现有
   `AppTheme.mono(12)` 一致）。
