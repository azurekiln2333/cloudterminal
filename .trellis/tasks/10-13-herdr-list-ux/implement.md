# Implement — Herdr 工作区列表移动端自适应

读父任务 `10-13-herdr-mobile-render/design.md` §4.4，再读本目录 `design.md`。

本子任务与另外两个子任务**无依赖**，可并行。

## 步骤

- [x] **1. 复现 overflow**

先写一个 360dp 宽度的 widget 测试，用长标签工作区与长路径，确认当前代码
确实产生 `RenderFlex overflowed`（`tester.takeException()` 非 null）。
失败复现成功后再改代码。

参考真实数据（来自 `.build/pi-herdr/live-probe-final.txt`）：

```
标签: qfli_studio_core, vaultwarden-backup, MyNewProjects
路径: D:\MyNewProjects\cloudterminal
```

- [x] **2. 工作区标题两行 + 焦点标记移位**（`design.md` §1）
  - `maxLines: 2` + `softWrap: true`
  - 焦点图标从标题 `Row` 移到下方 `Wrap`

- [x] **3. 路径中段省略**（`design.md` §2）
  - 实现 `ellipsizePath`，处理 `\` 与 `/` 两种分隔符
  - 决定它放哪：若仅一处使用则留在原文件；两处以上使用则放
    `lib/util/format.dart`（已存在）
  - 单测：短路径原样、单段超长、多段保留末段、混合分隔符

- [x] **4. 面板行分两行**（`design.md` §3）
  - 内层 `Row` 换 `Wrap`，这是消除 overflow 的关键
  - 标题一行，元信息（paneId / agent / chip）一行

- [x] **5. 标签页层级**（`design.md` §4）
  - 按 `pane.tabId` 分组 panes，每个 tab 一个分区标题
  - tabs 为空时退回平铺，不显示空标题
  - agent 列表保持现状（不改分组语义）
  - **不新增协议请求、不改 `HerdrController`**

- [x] **6. 跑验证**

```powershell
cd D:\MyNewProjects\cloudterminal
flutter analyze
flutter test
```

- [ ] **7. 真机确认（可选但推荐）**

`flutter run -d <android-device-id>`，在小屏/窄屏下目视确认列表不再溢出。

## 输出记录（`notes.md`）

1. `ellipsizePath` 最终放在哪个文件，以及理由
2. 实测的最窄可用宽度
3. 是否改动了既有测试断言，以及原因

## 回滚

恢复 `lib/screens/herdr_screen.dart`、路径展示处、`lib/util/format.dart`。

## 完成标准

- `flutter analyze` 无警告
- `flutter test` 全绿
- 360dp 无 overflow 的测试存在并通过
- 标签页列表可见的测试存在并通过
- 既有 Herdr UI 测试仍通过
