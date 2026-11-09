# 运行 CloudTerminal Windows 客户端

`apps/cloudterminal_windows` 是一个 Flutter Windows 桌面工程。它本身只负责“连接助手”界面，真正的后台逻辑由 Node sidecar（`server/src/agent/main.ts --sidecar`）提供。

## 前置条件

| 依赖 | 版本 | 用途 | 检查命令 |
| --- | --- | --- | --- |
| Flutter SDK | 见 `pubspec.yaml`（`sdk: ^3.11.5`） | 构建 / 运行 | `flutter --version` |
| Node.js | 24 LTS（`>= 23.6`） | 启动后台 sidecar | `node --version` |
| server 依赖 | — | sidecar 运行所需 | `cd server; npm ci` |
| Visual Studio 2022 + “使用 C++ 的桌面开发”工作负载 | — | **仅**构建/运行 Windows 桌面目标需要 | `flutter doctor -v` |

> 运行 `flutter run -d windows` 前，请先在仓库根目录执行一次 `cd server; npm ci`，否则客户端会提示“找不到后台服务或 Node.js”。

## 方式 (a)：已安装 Visual Studio C++ 工作负载 —— 运行桌面版

确认 VS 已就绪：

```powershell
flutter doctor -v
```

输出中应出现：

```text
[√] Visual Studio - develop Windows apps
```

然后运行：

```powershell
cd apps/cloudterminal_windows
flutter run -d windows
```

这是**完整功能**的形态：客户端能 `Process.start` 启动 Node sidecar，因此中继连接、配对码/二维码、工具探测、会话列表等全部可用。

## 方式 (b)：未安装 Visual Studio —— 用 Chrome 预览界面

当前机器 `flutter doctor` 显示：

```text
[X] Visual Studio - develop Windows apps
    X Visual Studio not installed; this is necessary to develop Windows apps.
```

此时 `flutter build windows` / `flutter run -d windows` 会失败。可以先用 **web 目标**预览 UI：

```powershell
cd apps/cloudterminal_windows
flutter run -d chrome
```

### 这个形态下会发生什么（重要）

- **界面可以正常查看**：布局、主题、导航、各页面骨架都能看到。
- **后台服务无法启动**：客户端用 `dart:io` 的 `Process.start` 拉起 Node sidecar，而该 API 在 web 目标上不可用。因此界面会出现类似
  > 找不到后台服务或 Node.js。请确认已安装 Node.js 24 LTS，并且 server/ 依赖已安装（npm ci）。

  的状态提示，配对码、工具列表、会话等**都会是空的**。
- 这是 **预期行为**，不是 bug。web 预览只用于确认界面，不代表功能验收通过。
- 换句话说：**要验证真实连接/配对，必须走方式 (a) 或用真机（Windows 桌面构建）。**

## 安装 Visual Studio C++ 工作负载（不静默安装，需手动执行）

用 winget 安装 **Build Tools**（体积小于完整 VS IDE，已足够构建 Flutter Windows 应用）：

```powershell
winget install Microsoft.VisualStudio.2022.BuildTools --override "--add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"
```

- 该命令**不会自动运行**，需要你在自己的终端里显式执行。
- 安装完成后**重开终端**，再运行 `flutter doctor -v` 确认 `[√] Visual Studio - develop Windows apps`。
- 如果已装完整版 Visual Studio，只需在 *Visual Studio Installer* 中勾选“使用 C++ 的桌面开发”工作负载即可，无需重装。
- `--includeRecommended` 已包含所需 SDK 与 CMake 工具。

## 一条命令启动

`run.cmd` 会先检查 Flutter 与 Visual Studio，再自动选择方式 (a) 或 (b)：

```powershell
apps\cloudterminal_windows\run.cmd
```

逻辑：

1. 找不到 `flutter` → 打印安装指引并退出。
2. 检测到 Visual Studio Windows 工作负载 → `flutter run -d windows`。
3. 未检测到 → 打印如何安装 C++ 工作负载的指引，然后 `flutter run -d chrome` 作为 UI 预览。

脚本**不会静默安装任何东西**。加 `RUN_LAUNCHER_DRY_RUN=1` 可以只打印将要执行的分支而不真正启动 Flutter（用于自检）。

## 常见问题

- **`flutter run -d windows` 报缺 VS / C++ 工具链**：按上面的 winget 命令安装，或改走方式 (b) 预览。
- **界面提示找不到后台服务**：确认在仓库根 `cd server; npm ci` 已执行，且 `node --version` >= 23.6。
- **web 预览里功能不可用**：符合预期，web 无法 spawn Node sidecar；请安装 VS 后用 `-d windows`。