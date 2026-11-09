# 移动端调试设备

在让用户手动验证之前，先连上这里的设备实测。**不要用安卓设备冒充 ohos 验证**
——本项目的 OHOS 目标是硬性要求，两个平台的运行时行为必须分别确认。

```powershell
hdc tconn 192.168.68.207:46551   # 连接
hdc list targets                 # 应显示 192.168.68.207:46551
```

## HarmonyOS 实机（ohos 验证首选）

| 项 | 值 |
| --- | --- |
| 地址 | `192.168.68.207:46551` |
| 型号 | `MRT-AL10`（HUAWEI，用户称 "14U"） |
| 系统 | HarmonyOS `7.0.0.109(SP6C00E105R7P2)`，API 26 |
| 连接方式 | `hdc`（无线，固定端口） |
| hdc 路径 | `D:\ProgramFiles\Huawei\OpenHarmony\Sdk\23\toolchains\hdc.exe`（3.2.0c） |
| 用途 | **所有 ohos 运行时结论的唯一依据** |

已实测可用：`hdc tconn` → `Connect OK`，`hdc list targets` 能列出该地址。

### 装机

```powershell
flutter build hap --debug
hdc install -r build\ohos\entry\build\default\outputs\default\entry-default-signed.hap
```

> 实际产物路径以 `flutter build hap` 输出为准；上面是常见路径，别照抄。

### 约束

- 这是一台**真机**，不是模拟器：安装会改动用户手机上的应用状态。
  只安装本项目的包，不要动其他应用。
- 需要用户在设备侧开启"允许通过 hdc 安装"类的开关时，**停下来让用户操作**，
  不要反复重试安装命令。
- **不要在验证失败时把结论写成"已验证"**。ohos 上的任何结论都必须来自
  这台设备或另一台明确的 ohos 设备。

## Android 实机（次要，仅用于快速回归）

本项目还有一台安卓真机（MEIZU 21），可用于快速回归渲染逻辑，因为
`HerdrPaneViewport` 是纯 Flutter + 纯 Dart xterm，两个平台跑同一份代码。

**不记录地址**：安卓的 adb 无线调试端口由系统随机分配，写死会过期并误导
后来人。用的时候自己发现：

```powershell
adb devices          # 从输出里取当前地址
flutter devices
```

**安卓上的通过不等于 ohos 通过。** 安卓只能证明渲染逻辑本身没问题，
不能替代上面那台鸿蒙机的运行时确认。

## 本机不具备的条件

- 无 DevEco Studio 模拟器实例。
- `adb` 与 `hdc` 都能用，但 `hdc` 需要先 `tconn` 才看得到设备。
