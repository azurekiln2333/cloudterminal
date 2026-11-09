# Herdr 工作区内的 Tab 栏 + Pane 切换

父任务：`10-13-herdr-mobile-render`
姊妹任务：`10-13-herdr-pane-viewport`（管「一个 pane 怎么画对」，本任务管「多个 pane 怎么切」，两者互补）

## 背景

用户原话：

> "我要手机能适配 herdr 啊 能随意切换各个 pane 啊 直接把单个 pane 展示在前台就好了
> 如果一个工作区开了多个 pane 在手机 ui 进行切换 我的想法是这样的 能不能实现？？？
> 如果在电脑一个工作区开了 4 个 pane 电脑肯定没问题啊 手机显示 4 个 pane 太小了啊"
>
> "herdr 每个工作区不是上面还有 tab 吗？？？你做一个 tab 栏读取当前工作区 tab
> tab1 tab2 然后 pane 就用 chip 来切换 我觉得没问题吧 一个 tab 栏切换 tab
> 然后往下一行切换 pane"
>
> "pane 可以做成 viewpager 那样左右滑动切换吧"

**核心诉求**：电脑上一个工作区可以有多个 tab、每个 tab 多个 pane。手机屏幕放不下平铺，
必须**一次只显示一个 pane**，并提供快速切换。

## 现状（已核实）

- `HerdrPaneScreen` **已经是单 pane 全屏**（`lib/screens/herdr_pane_screen.dart`），
  一次只渲染一个 pane。这部分已满足。
- **缺的是切换入口**：想换 pane 必须返回工作区列表再点进去，路径长且丢失上下文。
- 数据已齐备，无需改协议：
  - `HerdrController.tabs(workspaceId)` → `List<HerdrTab>`（含 `tabId/label/number/focused/paneCount/agentStatus`）
  - `HerdrController.panes(workspaceId)` → `List<HerdrPane>`（含 `tabId/paneId/terminalTitle/agent/agentStatus/focused`）
  - `HerdrTab.paneCount` 与 `HerdrPane.tabId` 足以做 tab→pane 归属

## 目标

### G1 Tab 栏（第一行）

- 在 pane 页面顶部显示**当前工作区**的 tab 列表。
- 每个 tab 显示：`label`（无 label 用 `t{number}`）、agent 状态色点、`focused` 标记。
- 只有 1 个 tab 时可折叠/隐藏该行，避免浪费垂直空间。
- 点击 tab：切换到该 tab，下面 pane 行与内容同步换到该 tab 的第一个 pane（或记忆该 tab 上次看的 pane）。

### G2 Pane chips（第二行）

- 显示**当前 tab 下的 pane**（按 `HerdrPane.tabId == 当前 tab` 过滤）。
- 每个 chip 显示：pane 标识（`terminalTitle` 优先，否则 `paneId`）、agent 名（若有）、
  agent 状态色点、`focused` 标记。
- 点击 chip：立即把内容区切到该 pane。
- 当前选中的 chip 要高亮，且横向列表自动滚动到可见位置。

### G3 左右滑动切换（PageView）

- 内容区用 `PageView`，左右滑动切换**当前 tab 下的 pane**。
- 滑动与 chip 选中状态**双向联动**：滑动后 chip 高亮跟随；点 chip 后页面滑过去。
- 边界：第一个 pane 再左滑不越界到别的 tab（tab 由 Tab 栏切换，避免误触）。

### G4 单 pane 全屏

- 内容区只渲染**一个** pane，占满剩余空间（减去 Tab 栏、chip 行、输入栏）。
- Tab 栏 + chip 行总高度要克制，不能挤掉内容；只有 1 tab 1 pane 时两行都不显示。

### G5 不改协议、不动渲染层

- 不改 `server/`、不改协议帧、不改 `lib/models/herdr.dart` 的解析。
- 渲染仍交给 `HerdrPaneViewport`（`10-13-herdr-pane-viewport` 的范围）。
- 本任务只做**导航/布局/切换交互**。

## 非目标

- 不重写 pane 渲染（reflow / xterm 那层是姊妹任务）。
- 不做 pane 的创建/关闭/移动（已有「面板操作」菜单，保持不变）。
- 不做多 pane 平铺或缩略图预览。
- 不改变从工作区列表进入 pane 的路径（保留，作为兼容入口）。

## 验收标准

1. 打开一个含 2 个 tab、每 tab 多 pane 的工作区：
   - 顶部显示 tab 行，点击可在 tab 间切换；
   - 第二行显示**当前 tab** 的 pane chips；
   - 切 tab 后 chips 与内容区同步更新为该 tab 的 pane。
2. 点击任一 chip，内容区立即显示该 pane；chip 高亮正确。
3. 内容区左右滑动可切换同级 pane；滑动后 chip 高亮跟随。
4. 只有一个 tab 时 tab 行不占位；只有一个 pane 时 chip 行不占位。
5. 从列表进入某个 pane 时，Tab 栏/chips 的初始选中态与该 pane 一致。
6. 内容区只渲染一个 pane，且占满除导航/输入外的全部高度。
7. `flutter analyze` 与 `flutter test` 通过；新增 widget 测试覆盖：
   - tab 切换改变 pane 列表；
   - 点 chip 切换 pane；
   - 单 tab / 单 pane 时对应行不渲染。
8. 不修改 `server/`、协议帧或 `herdr.dart` 的解析逻辑。

## 已定与仍需确认

已定（用户明确）：

- 结构：**第一行 Tab 栏，第二行 Pane chips，内容区 PageView 左右滑动**。
- 一次只显示一个 pane，全屏。
- 必须适配手机屏幕宽度（不做横向拖动的原始列宽作为默认）。

仍需确认（选保守默认，不阻塞实现）：

1. 切 tab 后落到哪个 pane：**记忆该 tab 上次查看的 pane**，无记忆则取该 tab 第一个。
2. 只有 1 个 tab 时：**隐藏** tab 行（而非显示单个不可点的 tab）。
3. 左右滑动是否循环：**不循环**（避免位置感丢失）。
