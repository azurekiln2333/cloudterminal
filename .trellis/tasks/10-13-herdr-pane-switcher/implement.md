# 实施计划：Pane 切换 UI + 等比缩放渲染

## 前置

- 父任务：`10-13-herdr-mobile-render`
- 用户已定：
  - 第一行 Tab 栏，第二行 Pane chips，内容区 PageView 左右滑动
  - 一次只显示一个 pane，全屏
  - 必须适配手机屏幕（不错位、不截断）→ 用等比缩放
- 范围：`lib/screens/herdr_pane_screen.dart`、`lib/widgets/herdr_pane_viewport.dart`、`test/`

## 有序检查清单

### A. 渲染：新增 scaledToFit

- [ ] A1. `herdr_pane_viewport.dart`：`HerdrViewportMode` 增加 `scaledToFit`
      （label `整屏缩放`，hint 说明布局与电脑一致、可双指放大）。
- [ ] A2. 该模式下：列数 = `sourceColumns ?? _inferColumns(text)`（不按手机宽度），
      行数按内容行数取足，`TerminalView(autoResize: false)` 放进固定尺寸
      `SizedBox`，外层 `FittedBox(fit: BoxFit.contain)`。
- [ ] A3. 外层包 `InteractiveViewer(panEnabled: false, minScale: 0.5, maxScale: 4)`
      以便双指放大；确认不与 PageView 横向手势冲突。
- [ ] A4. `herdr_pane_screen.dart`：`_viewMode` 默认改为 `scaledToFit`；
      模式切换 chip 支持三态循环。

### B. 切换 UI

- [ ] B1. `HerdrPaneScreen` 增加 `_selectedTabId` / `_paneIndex` /
      `_lastPaneOfTab`，由构造参数 `pane` 初始化（保持从列表进入的行为）。
- [ ] B2. 派生 `_tabs` / `_tabPanes` / `_currentPane`，处理空 tab、空 pane、
      无 tab 列表三种退化情况。
- [ ] B3. 加 `_TabBar`（`_tabs.length > 1` 才渲染）：chip 显示 label/状态色/focused。
- [ ] B4. 加 `_PaneChips`（`_tabPanes.length > 1` 才渲染）：显示 terminalTitle/agent/
      状态色/focused，选中项高亮并自动滚到可见。
- [ ] B5. 内容区改为 `PageView.builder`，`PageController` 与 chips 双向联动；
      切 tab 用 `jumpToPage`。
- [ ] B6. **把所有写操作与读取的目标从 `widget.pane` 改为 `_currentPane`**：
      `_send` / `_sendKey` / `_runCommand` / `_controls` / `_startAgent` /
      `_confirmClose` / `_load` / `_sourceColumns` / `outputKey`。
      `_currentPane == null` 时禁用输入栏。

### C. 测试与验证

- [ ] C1. widget 测试：切 tab → chips 与内容同步。
- [ ] C2. widget 测试：点 chip 切换 pane；滑动后 chip 高亮跟随。
- [ ] C3. widget 测试：单 tab 不渲染 tab 行；单 pane 不渲染 chip 行。
- [ ] C4. widget 测试：`scaledToFit` 的列数等于桌面列数（用 `debugCols`）。
- [ ] C5. widget 测试：写操作作用于当前选中的 pane（断言请求里的 paneId）。
- [ ] C6. `flutter analyze` 干净。
- [ ] C7. `flutter test` 全绿。
- [ ] C8. 构建 hap 并安装到 14u，手工验证切 tab / 切 pane / 滑动 / 双指放大。

## 验证命令

```powershell
cd D:\MyNewProjects\cloudterminal
flutter analyze
flutter test
flutter build hap --release
& "D:\ProgramFiles\Huawei\OpenHarmony\Sdk\23\toolchains\hdc.exe" install -r build\ohos\hap\entry-default-signed.hap
& "D:\ProgramFiles\Huawei\OpenHarmony\Sdk\23\toolchains\hdc.exe" shell aa start -a EntryAbility -b com.azurekiln.cloudterminal
```

## 审阅闸口

- 闸口 A（A1-A4 后）：三种模式都能渲染，默认模式为 `scaledToFit`，
      与 PageView 手势不冲突。
- 闸口 B（B1-B6 后）：所有写操作路径都经 `_currentPane`（grep 确认没有
      残留的 `widget.pane.` 直接用于请求）。
- 闸口 C（C1-C7 后）：analyze 与 test 全绿。
- 闸口 D（C8）：真机可见改进，用户确认。

## 回滚点

任一闸口失败 → `git checkout -- lib/screens/herdr_pane_screen.dart lib/widgets/herdr_pane_viewport.dart test/`。

## 明确不做

- 不改 server 端与协议。
- 不重写 xterm。
- 不做多 pane 平铺/缩略图。
- 不改 pane 的创建/关闭/移动菜单（沿用现有）。
