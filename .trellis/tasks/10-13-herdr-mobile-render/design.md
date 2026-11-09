# Design — Herdr 移动端渲染修复

只改移动端 App（`lib/` + `test/`）。ohos（Flutter `3.27.5-ohos-1.0.1`）优先。

---

## 1. 现状与缺陷定位

### 1.1 渲染链路（当前）

```
agent: herdr pane read ──▶ herdr_output {text: <原始文本+ANSI>}
   │
   ▼
HerdrOutput.fromJson → field text（原始，未改写）
   │
   ▼
HerdrOutput.display → text.replaceAll(RegExp(r'\s+$'), '')   ← 破坏版面
   │
   ▼
SelectableText(output.display)  ← 无列宽概念、无颜色、无重排
```

问题全部集中在最后两步。

### 1.2 为什么"适配宽度"在当前架构下不可能实现

`pane read` 返回的是**已按桌面 PTY 列宽硬折行**的文本。其中的换行符
（`\n`）在语义上分两类：

- **软折行**：终端因为到达列宽边界而自动换行，这个 `\n` 不是用户/程序输出的
- **硬换行**：程序显式输出 `\n`

`pane read` 的纯文本形式**不区分这两者**。所以：

- 把每行当作段落重排 → 软折行位置被当作硬换行，76 列的表格重排后变成
  76 个独立短行，仍然错位
- 不重排 → 就是现在的"拉伸电脑窗口给手机看"

**结论：纯文本层面无解。必须用终端模拟器。**

### 1.3 有解的原因

终端模拟器内部维护的是**字符网格 + 属性**，而不是文本行。当网格宽度变化时，
`reflow` 可以依据"这一行是否满行"来推断软折行，并正确重排。

vendored xterm 已经实现了这一点：

- `Terminal.resize(newWidth, newHeight, ...)` → `Buffer.resize` → `reflow()`
- `third_party/xterm/lib/src/core/reflow.dart` 中的 `_LineReflow(oldWidth, newWidth)`
  正是按"旧宽度下的满行"判断续行

因此正确做法是：**把原始输出喂给 `Terminal`，用手机列数 resize，让 reflow
按终端语义重排**。

---

## 2. 架构选择

### 2.1 方案对比

| 方案 | 重排正确性 | ANSI | 成本 | 结论 |
| --- | --- | --- | --- | --- |
| A. 保留 `SelectableText`，按手机宽度软折行 | ✗ 软/硬折行不可区分 | ✗ | 低 | **否决** |
| B. `\n` 启发式去折行（拼接短行） | ✗ 会错误合并硬换行 | ✗ | 中 | **否决** |
| C. 只读 `Terminal` + `TerminalView` 渲染 | ✓ 用 reflow 的真实语义 | ✓ | 中 | **采用** |
| D. 自建等宽网格 painter | ✓ | 需自写 | 高 | 否决，重复 xterm 已有能力 |

选择 **C**。理由：vendored xterm 已含完整解析器与 painter，已经为 ohos 打过
补丁，且现有终端页已在生产使用同一套代码路径。

### 2.2 为什么不需要新的协议字段

`pane read` 的原始文本已经包含渲染所需的全部信息（ANSI 序列 + 折行结构）。
`Terminal.write()` 接受的就是原始字节流。因此：

- **不改协议帧**，`PROTOCOL_VERSION` 保持 `1`
- **不改 agent 端**
- 子任务只需修正 App 侧"不要改写原始文本"这一处

`recent`（非 unwrapped）来源已经由 Herdr 去掉软折行，两种来源都能进
`Terminal`；对 `Terminal` 而言这只是不同内容的输入文本，无需特殊分支。

---

## 3. 分层设计

```
lib/models/herdr.dart
  HerdrOutput
    .text            原始（唯一真源，不改写）
    .display         ← 废弃/改名，见 §4.1

lib/widgets/herdr_pane_viewport.dart        【新增】
  HerdrPaneViewport            只读终端视口
    ├─ 拥有 Terminal 实例
    ├─ 随 LayoutBuilder 计算列数 → resize → reflow
    ├─ 模式：fitWidth | rawColumns
    └─ 暴露 latestOffset / jumpToLatest

lib/screens/herdr_pane_screen.dart
  _outputView  →  用 HerdrPaneViewport 替换 SelectableText
  新增：模式切换、缩放、回看提示条
  修正：刷新不清屏
```

### 3.1 `HerdrPaneViewport` 契约

```dart
enum HerdrViewportMode {
  /// 按手机可视宽度重排（默认）：把桌面 76 列的折行按手机列数重新折行。
  fitWidth,

  /// 保留桌面原始列宽，横向平移查看未重排的版面。
  rawColumns,
}

class HerdrPaneViewport extends StatefulWidget {
  const HerdrPaneViewport({
    super.key,
    required this.output,        // 原始文本；变化时增量写入
    required this.outputKey,     // 标识一次完整的 pane read（用于决定 reset）
    this.mode = HerdrViewportMode.fitWidth,
    this.fontSize = 12,
    this.scroll,                 // HerdrScroll? → 回看提示
    this.onJumpToLatest,
  });
}
```

关键实现点：

1. **Terminal 生命周期**：`State` 中持有 `Terminal(maxLines: ...)`，`dispose`
   时释放。跨 `build` 复用，不重建。
2. **写入策略**：`outputKey` 变化（一次新的 `pane read` 结果）时 **reset + 全量
   写入**；否则只写入增量。绝不能把同一次 read 的文本反复 append。
   - reset 方式：换一个新 `Terminal` 实例并 `setState`（xterm 的
     `Terminal` 没有 public reset），或用 `Terminal.write('\x1b[2J\x1b[H')`
     + 重新写入。**采用换实例**，语义最干净且不会残留旧网格。
3. **列数计算**：用 `LayoutBuilder` 拿可用宽度，按等宽字体的字符宽度算列数：
   ```dart
   final charWidth = TerminalMetrics(style: textStyle).charWidth; // 见下
   final cols = (constraints.maxWidth / charWidth).floor().clamp(20, 500);
   final rows = (constraints.maxHeight / lineHeight).floor().clamp(4, 300);
   ```
   仅在 `cols/rows` 真的变化时调用 `terminal.resize(...)`，避免每帧 reflow。
4. **字符宽度测量**：xterm 自带 `third_party/xterm/lib/src/ui/char_metrics.dart`，
   优先复用它而不是自己写 `TextPainter` 估算。
5. **fitWidth 模式**：`TerminalView(readOnly: true, autoResize: false)`，
   由我们自己控制 resize，保证列数严格等于手机列数。
6. **rawColumns 模式**：把 `cols` 固定为桌面原始列数（从内容推断或用户指定，
   见下），外层裹 `InteractiveViewer`/双向 `SingleChildScrollView` 实现平移。

### 3.2 “桌面原始列数”如何得到

`pane read` 不给列宽。可行的取值顺序：

1. `HerdrPane.scroll.viewportRows` 只有行数，没有列数 → 不可用
2. `HerdrLayout` 的 `area.width`（`pane layout` 返回，单位是单元格）→ **可用**
   但需要额外一次 `herdr_layout` 调用
3. 从内容推断：取所有行的最大长度并向上取整到常见列宽（80/100/120/…）

**采用 2 为优先，3 为回退**。`HerdrController` 已有 `loadLayout(paneId)` 与
`layout(paneId)` 缓存，直接复用，不新增协议请求。

> 实现者注意：若 layout 拿不到（例如 pane 已关闭），回退到按内容最大行宽推断，
> 并且**不要**因此报错阻塞渲染。

---

## 4. 逐项修复

### 4.1 `HerdrOutput.display` 的破坏性改写 — 移除

`lib/models/herdr.dart`：

```dart
String get display => text.replaceAll(RegExp(r'\s+$'), '');
```

- `text` 是唯一真源，渲染层直接用它。
- `display` 如仍被引用（`herdr_test.dart` 有断言），**改为不改变版面**的语义：
  仅用于"内容是否为空"的判断可以保留为 `isEmpty`（基于 `text.trim().isEmpty`），
  但**不得**作为渲染输入。
- 若 `display` 无其他消费者，删除并更新测试。

### 4.2 刷新不清屏

当前：

```dart
if (_loading && output == null) return const Center(child: CircularProgressIndicator());
```

改为：**保留已有视口**，仅在顶部显示细进度条（已有 `LinearProgressIndicator`
模式可复用）。仅当确实没有任何内容时才显示 loading 占位。

### 4.3 回看提示与回到最新

用 `HerdrScroll`：

- `offsetFromBottom > 0` → 视口右下显示浮动按钮"回看 N 行 ↓回到最新"
- 点击后滚动到底部；若 `onJumpToLatest` 提供，则同时触发重新读取

注意：`HerdrScroll` 描述的是 **Herdr 侧**的滚动位置，与 App 内部 `Terminal`
的滚动位置是两件事。实现时必须区分并如实标注，不能把两者混为一谈后给出
错误结论。**默认实现：用 `HerdrScroll` 显示"电脑端当前回看了 N 行"这一事实，
App 自己的滚动用 `TerminalView` 的 scrollController。**

### 4.4 列表层自适应（子任务 3）

- 工作区标题：`maxLines: 2` + `softWrap: true`，不再靠 `ellipsis` 切掉全部信息
- 路径 `HerdrPath`：中段省略（保留盘符与末段），而非尾部截断
- pane 行：标题与 id/agent 分两行，窄屏不产生 `RenderFlex overflowed`

---

## 5. ohos 兼容性

| 关注点 | 结论 |
| --- | --- |
| API 可用性 | 只用 `Terminal` / `TerminalView` / `LayoutBuilder` / `Scrollbar` / `InteractiveViewer`，全部在 Flutter 3.27 稳定 API 内 |
| 平台通道 | 无新增。xterm 是纯 Dart 渲染 |
| `TargetPlatform.ohos` | xterm 已在 `shortcuts.dart` 打过补丁；`TerminalView` 非 Apple 分支走默认快捷键 |
| 字体测量 | `char_metrics.dart` 用 `TextPainter`，ohos 引擎支持 |
| 验证方式 | 静态核查 + Android 真机运行；**无 ohos 设备，不做 ohos 运行时声明** |

`InteractiveViewer` 在 ohos 上的手势支持需归入"未验证"，在任务记录中如实写明。

---

## 6. 非回归

- `terminal_pane.dart` 与 `session_view.dart` 的 `Terminal` 用法**不受影响**
  —— 新视口是独立 widget，不修改 vendored xterm 源码。
- `HerdrScreen` 的导航、动作、确认对话框不变。
- `HerdrController` 的缓存与 `_inFlight` 守卫不变。
- 协议与 agent 端零改动。
- 现有 `test/herdr_test.dart` 中依赖 `display` 的断言按 §4.1 同步更新，
  其余保持通过。

## 7. 回滚

改动集中在移动端独立 widget 与两处模型/屏幕方法。回滚 = 恢复
`_outputView` 使用 `SelectableText` 版本，删除新 widget 文件。无持久化状态、
无协议影响、无 agent 影响。

## 8. 测试策略

- **模型层**：断言 `HerdrOutput` 原样保留行尾空白、空行、ANSI 转义序列。
- **视口层**（widget test）：
  - 给定含 ANSI 与满行的原始文本，`fitWidth` 下列数等于测试视口列数
  - 宽度变化触发 `resize` 且不抛异常
  - `outputKey` 不变时重复 build 不重复追加内容
  - 空文本、超长单行、仅含空白的文本不崩溃
- **屏幕层**：刷新时旧内容不被 `CircularProgressIndicator` 替换；
  `HerdrScroll.offsetFromBottom > 0` 时出现回看提示。
- **列表层**：360dp 宽度下无 overflow（用 `tester.takeException()` 断言）。
- 复用 `test/support/fake_relay.dart` 与现有 herdr 测试脚手架，不新建基础设施。
