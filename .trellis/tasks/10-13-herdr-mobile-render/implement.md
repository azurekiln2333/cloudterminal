# Implement — Herdr 移动端渲染修复（父任务）

父任务**不直接改代码**。它的职责是：维护需求集、维护三个子任务的地图、
定义跨子任务验收标准、做最终集成复核。

## 执行顺序（含依赖）

```
子任务 1: 10-13-herdr-output-fidelity      ← 先做（其它两个依赖它的输出契约）
子任务 2: 10-13-herdr-pane-viewport        ← 依赖 1
子任务 3: 10-13-herdr-list-ux              ← 与 1、2 无依赖，可并行
   │
   ▼
父任务最终集成复核
```

依赖的**理由**（不是树结构能表达的，必须显式说明）：

- 子任务 2 的视口接收"未经改写的原始文本"，并依赖子任务 1 确定的
  `HerdrOutput` 数据契约（`text` 为唯一真源、`display` 的处理方式）。
  若先做 2，`display` 的破坏性改写仍在链路上，视口会拿到已被裁剪的文本，
  重排结果依然错误。
- 子任务 3 只动列表布局，与数据契约无关。

## 跨子任务验收标准（父任务负责）

任一子任务单独通过不算完成，以下必须整体成立：

| # | 条件 | 验证方式 |
| --- | --- | --- |
| X1 | `pane read` 原始文本在到达渲染层前**零改写** | 端到端：模型 → 视口的输入断言的同一份文本 |
| X2 | 默认视图按手机列宽重排，box-drawing 边框连续 | Android 真机目视 + widget 测试列数 |
| X3 | 提供原始列宽平移模式 | 模式切换可用且不崩 |
| X4 | 刷新不清屏 | widget 测试 |
| X5 | 列表在 360dp 无 overflow | `tester.takeException()` |
| X6 | `flutter analyze` 干净、`flutter test` 全绿 | 命令输出 |
| X7 | ohos 结论如实标注（含未验证项） | 任务记录 |

## 验证命令

```powershell
cd D:\MyNewProjects\cloudterminal
flutter analyze
flutter test
```

聚焦运行（实现期间用）：

```powershell
flutter test test/herdr_test.dart
```

> 注意：不要运行 `cd server && npm test` —— 本任务不改 `server/`。
> 若 `flutter test` 中的 `test/node_integration_test.dart` 因环境原因跳过，
> 记录实际结果而不是声称通过。

真机验证（子任务 1 与 2 完成后）：

```powershell
flutter devices                 # 确认 MEIZU 21 已连接
flutter run -d <android-device-id>
```

真机上必须实际打开一个真实 Herdr pane，对照修复前的错误折行现象。

## 子任务 1 — `10-13-herdr-output-fidelity`

1. 移除 `HerdrOutput.display` 的 `RegExp(r'\s+$')` 改写（见 design §4.1）
2. 处理其消费者（`herdr_pane_screen.dart`、`test/herdr_test.dart`）
3. 修正 `_outputView` 的 loading 清屏（design §4.2）
4. 接入 `HerdrScroll` 回看提示（design §4.3）
5. 更新/新增模型与 widget 测试

**验证**：`flutter test test/herdr_test.dart` 通过；断言原始文本保真。

## 子任务 2 — `10-13-herdr-pane-viewport`

1. 新增 `lib/widgets/herdr_pane_viewport.dart`（design §3.1 契约）
2. `Terminal` 生命周期与 `outputKey` 驱动的写入策略
3. `LayoutBuilder` + `char_metrics` 计算列数 → `resize` 触发 reflow
4. `fitWidth` / `rawColumns` 两种模式
5. `herdr_pane_screen.dart` 用视口替换 `SelectableText`
6. widget 测试

**验证**：`flutter test` 通过；Android 真机上边框连续、颜色正确。

## 子任务 3 — `10-13-herdr-list-ux`

1. 工作区标题软折行策略（design §4.4）
2. `HerdrPath` 中段省略
3. pane 行分两行布局，消除窄屏 overflow
4. widget 测试：360dp 无 overflow

**验证**：`flutter test` 通过；`tester.takeException()` 为 null。

## 复核闸门（每步都要过，不是只在最后过）

- **每个子任务做完立刻**：`flutter analyze` + 该子任务的聚焦测试
- **每个子任务开始前**：读父任务 `design.md` 的对应小节，不要自行重新设计
- **全部子任务完成后（父任务最后一次复核）**：
  1. 按跨子任务验收表 X1–X7 逐条核对
  2. 用 `python ./.trellis/scripts/get_context.py --mode packages` 列出受影响
     包，加载其 spec 索引的 Quality Check 段
  3. 交叉检查：三个子任务是否在 `HerdrOutput` / `herdr_pane_screen.dart` 上
     产生了相互冲突的修改
  4. 真机跑一遍完整路径：连接 → Herdr 工作区 → 展开 → 打开 pane → 切换模式
     → 刷新

## 回滚点

- 子任务 1 之前：无风险（尚未改代码）
- 子任务 1 之后 / 子任务 2 之前：可单独保留子任务 1 的修复（数据保真本身
  就是净收益，即使视口未换）
- 子任务 2 之后：回滚 = 恢复 `_outputView` 的 `SelectableText` 版本，
  删除 `herdr_pane_viewport.dart`
- 无数据库/协议/持久化状态需要回滚

## 提交策略

按子任务分批提交，消息用 Conventional Commits，只包含本任务改动的文件：

```
fix(app): preserve raw herdr pane output and scroll position
feat(app): render herdr panes in a read-only terminal viewport
fix(app): make herdr workspace list fit narrow phone widths
```

**不提交**工作区中已有的 125 个无关改动（其他任务/文档）。每个 commit 前用
`git status --porcelain` 确认暂存范围只含 `lib/` 与 `test/` 下本任务涉及文件。
