# Herdr 入口死锁：首次连接无法进入 Herdr 工作区

## 背景

用户报告（真实设备，已配对成功的局域网连接）：

> "怎么手机端还是显示 herdr 工作区电脑端未启用接入？？"
> "不是你常驻提醒是什么jb脑回路 而且按钮灰色的怎么进入herdr工作区 有毛病吧"

Agent 端一切正常，启动日志证明：

```
herdr binary resolved found=true path=herdr.exe
herdr available version=0.9.3 protocol=22
agent online agentId=a_zXL7R7uxtBWh70mJ
client joined clientId=bOCHpdMU0jqj ip=192.168.68.207
```

但手机端 Herdr 入口**按钮是灰的、无法点击**，且侧边栏常驻一行
「电脑端未启用 Herdr 接入」。

## 根因（死锁，代码自相矛盾）

**入口可用性**（`lib/widgets/workspace_sidebar.dart:74`）：

```dart
NavigationDrawerDestination(
  label: const Text('Herdr 工作区'),
  enabled: herdr.canControl,        // 灰/可点由这个决定
),
```

**canControl 的定义**（`lib/state/herdr_controller.dart:44`）：

```dart
bool get canControl =>
    _remote.isOnline && (_availability?.available ?? false);
                                          // availability 为 null → false
```

**`_availability` 的唯一赋值点**是 `refresh()` → `_remote.herdrInfo()`
（`herdr_controller.dart:99`）。

**`refresh()` 的触发点**只有：

- `herdr_screen.dart:35`（`initState` —— **进入 Herdr 页时**）
- `herdr_screen.dart:236/252/260`（页内按钮 / 下拉刷新 / 重试 —— **都在页内**）
- `herdr_controller.dart:run()` 动作成功后（`refreshAfter` —— 同样在页内）

于是形成环路：

> 进入 Herdr 页 → 需要 `canControl == true`
> → 需要 `_availability` 非 null
> → 需要 `refresh()` 被调用
> → 需要先进入 Herdr 页

**首次使用（全新安装 / 清除数据 / 未探测过）时 `_availability` 恒为 null，
按钮恒为灰，用户永远无法进入页面触发探测。** 这不是用户操作问题，是阻塞级缺陷。

## 次生缺陷：把"未知"说成"未启用"

`_herdrHint()`（`lib/widgets/workspace_sidebar.dart:188-197`）：

```dart
return herdr.availability?.summary ??          // null 时走兜底
    (controller.agent == null
        ? '连接电脑后读取 Herdr 工作区'
        : '电脑端未启用 Herdr 接入');            // ← 把 null 当成"未启用"
```

`availability == null` 的语义是**尚未探测**（或探测未完成），
但文案把它断言成"电脑端未启用 Herdr 接入"——与事实相反，
且该提示常驻在**不可点击的按钮**旁，无法自助恢复。

## 目标

### G1 首次连接即可进入

- App 已连接到 agent（`isOnline`）后，Herdr 入口**必须可点击**，无论是否探测过 Herdr。
- 未探测/探测中时显示"正在检测"类中性文案，不得显示"未启用"。
- 进入页面后自动完成探测并渲染真实工作区列表，**无需用户手动刷新**。

### G2 分离"可浏览"与"可写操作"

- `enabled`（能否进入）只依赖**连接状态**。
- 写操作（prompt / sendKeys / run / act / 关闭等）仍按 `canControl` 禁用，
  即 Herdr 真正不可用时不允许下发变更。
- 只读能力（列表、pane read、layout）在 Herdr 可用时应能正常工作。

### G3 连接状态变化自动同步

- agent 连接建立（`isOnline` false→true）时自动探测一次 Herdr 状态，
  不依赖用户打开页面。
- 断线时清理状态（现有 `_onRemote` 已有部分逻辑，需确保与探测状态一致）。

### G4 文案诚实

- `availability == null` + 已连接 → "正在检测 Herdr…"（或等价中性文案）。
- `availability == null` + 未连接 → "连接电脑后读取 Herdr 工作区"（保留现有）。
- `availability.available == false` → 显示 `availability.summary`（真实原因）。
- 不在按钮不可用的情况下常驻错误结论。

## 非目标

- 不改 agent 端 Herdr 探测逻辑（`resolveHerdrBinary` 不查 PATH 的问题另案处理）。
- 不改 Herdr 协议帧格式。
- 不新增 Herdr 推送流（仍为请求/响应 + 显式刷新）。
- 不重构 Herdr 页面 UI 结构。

## 验收标准

1. **死锁消除**：全新状态（清 App 数据或首次安装）下，配对连接成功后，
   抽屉里的「Herdr 工作区」入口**可点击**，无需任何手动刷新。
2. 进入页面后无需手动操作即显示真实工作区列表（对应 agent 侧 `herdr_workspaces`）。
3. Herdr 真正不可用时（agent 报 `available == false`）：
   - 入口仍可进入（能看到真实原因），或按明确规则禁用**且**给出真实原因文案；
   - 写操作被禁用，只读展示可用。
4. 文案断言：`availability == null` 时**不出现**"电脑端未启用 Herdr 接入"。
5. 断线后状态清理正确；重连后自动恢复可用，无需手动刷新。
6. `flutter analyze` 与 `flutter test` 通过；新增/更新 widget 或 controller 测试
   覆盖"未探测时入口可用"与"null 不显示未启用文案"。
7. 既有 Herdr 操作（prompt/sendKeys/run/act/read）行为不变，且仍受 `canControl` 保护。

## 已定与仍需确认

已定：

- 死锁是本任务核心，必须修。
- 浏览能力不应被写能力门禁。
- 文案必须区分"未知"与"不可用"。

仍需确认（不阻塞实现，选保守默认）：

1. Herdr 真正不可用时，入口是"可进入并显示原因"还是"禁用 + 原因提示"？
   倾向**可进入并显示原因**（与 `herdr_screen.dart:255` 的 `_UnavailableBanner` 一致，
   且用户能据此自助排查）。
2. `attentionCount` 徽标在未探测时的行为（默认 0，不显示）。
