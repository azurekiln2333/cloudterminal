# 拆分仓库：主项目与中继服务端

## Goal

把现在的单个仓库拆成两个 GitHub 仓库，并安全地完成第一次推送：

- **主项目** `github.com/azurekiln2333/cloudterminal`：跑在用户设备上的东西，包括手机 / Web / Windows 的 Flutter 应用、电脑上的 Node agent（含局域网入口）和启动脚本。
- **服务端** `github.com/azurekiln2333/cloudterminal-relay-server`：只跑在公网服务器上的中继，包括转发、账号与设备绑定、数据库、OAuth、Docker 镜像与部署文件，以及出镜像的 CI。

用户价值：
- 服务端仓库单独出镜像，服务器直接拉取部署。
- 平时"手机 + 电脑"一起改的功能都在主仓库里，一次改完。

## Background（2026-11-09 核对）

**仓库现状**

- 两个目标仓库都已存在，公开且为空：匿名 `git ls-remote` 返回成功，没有任何 ref。旧的 `azurekiln2333/cloudterminal-relay` 也仍可访问，可能是旧仓库还在，也可能是改名后的跳转。
- 本地仓库没有配置 remote。分支 `codex/general-terminal` 比 `main` 多 2 个提交，可以快进合并。
- 2026-10-13 之后的工作全部未提交：已跟踪文件 +7609 / −2269 行，另有新建的源码和测试约 1.7 万行。
- 现有 12 个提交的历史经全量扫描，没有密钥文件、私钥块或令牌。

**推送风险（工作区）**

- `.signing/` 下有 p12 / csr / cer / p7b 文件，没有被 `.gitignore` 忽略。
- `ohos/build-profile.json5` 的改动加入了 `signingConfigs`，含 `storePassword` / `keyPassword` 和本机绝对路径；HEAD 中这一项为 `[]`。
- `server/ansi.cjs`、`server/check-herdr.cjs`、`server/hold.cjs` 是含本机路径的临时调试脚本，未跟踪。
- `ohos/entry/src/main/resources/rawfile/`（flutter_assets、buildinfo.json5）是构建产物，未跟踪。

**代码耦合**

- 电脑端 agent 内嵌中继，作为局域网入口：`server/src/agent/main.ts:164`、`server/src/agent/sidecar.ts:83-84` 调用了 `createRelay`。
- `server/src/relay/relay.ts`（506 行）在 `relay.ts:17` 引入 `tenancy.ts`；`tenancy.ts:12-13` 在运行时又引入 `db/bindings.ts` 和 `db/tokens.ts`。
- 服务端代码对 `shared/protocol.ts` 只用到 `relay.ts:7-14` 里的几个常量和类型，另外用到 `shared/crypto.ts`、`shared/log.ts`、`shared/protocol-account.ts`。
- agent 只用到 `relay/relay.ts` 和 `shared/crypto|log|protocol`，不用 `db/`、`oauth/`、`relay/api.ts`。
- Windows 助手按 `<repo>/apps/cloudterminal_windows` → `<repo>/server/src/agent/main.ts` 的路径定位 agent（`apps/cloudterminal_windows/lib/main.dart:60-75`）。
- Flutter 集成测试会检查 `server/node_modules`（`test/node_integration_test.dart:18`、`apps/cloudterminal_windows/test/sidecar_ipc_test.dart:15`）。

**CI 与测试**

- 出镜像的 CI 放在仓库根并引用 `server/`：`.github/workflows/image.yml`、`.cnb.yml`。`server/test/deployment-image.test.ts:21-22` 会读取仓库根的文件。
- `server/test/deployment.test.ts` 混合了两类用例：agent 用例（第 49、92 行）和中继用例（第 109 行）。
- `server/test/herdr.test.ts:970` 读取被忽略的 `.build/pi-herdr/herdr-probe`，新 clone 后这条用例会失败。

**发布惯例与环境**

- 你在 `D:\My2KProjects\cnb2api-panel` 的发布惯例：
  - 代码推 GitHub（origin）+ CNB（`cnb.cool/azurekiln/...`）+ Gitee / GitCode / GitLab。
  - 镜像默认用 `docker.cnb.cool/azurekiln/cnb2api-panel`，GitHub 侧的 `ghcr.io/azurekiln2333/cnb2api-panel` 备用。
  - 用 `nickfedor/watchtower` 自动更新。
- 本机没有 Docker（`docker: command not found`），镜像构建只能由 CI 验证。

## Requirements

- **R1 推送前安全**：
  - 签名材料、签名密码、本机调试脚本和构建产物，都不能进入任何一个仓库的任何提交。
  - 本机仍能用现有的签名配置构建鸿蒙包。
- **R2 先备份**：拆分前，先在主仓库把现有的全部工作按主题提交，不丢任何文件。
- **R3 解耦**：
  - 中继核心不再直接依赖账号和数据库代码，账号部分改为在服务端启动时接入。
  - 中继的对外行为不变。
- **R4 服务端仓库可独立运行**：
  - 包含中继、账号 / 数据库 / OAuth、部署文件、出镜像的 CI 和对应测试。
  - 单独 clone 后就能安装依赖、做类型检查、跑测试，并由 CI 构建和发布镜像。
- **R5 主仓库只留设备端**：
  - 移除只属于服务端的代码、部署文件和 CI。
  - 保留 agent 和局域网入口需要的那份中继核心副本。
  - `server/` 目录暂不改名，Windows 助手和测试里的路径保持不变。
- **R6 两份中继核心保持一致**：要有一致性检查。副本被单独改动，或者与服务端不一致时，检查要失败。
- **R7 新 clone 可测**：两个仓库的测试都不依赖被忽略的本地文件。
- **R8 文档**：
  - 服务端仓库的 README 说明部署方法，内容来自现在的 `server/README.md`。
  - 主仓库 README 里的部署部分改为指向服务端仓库。
- **R9 推送**：
  - 两个仓库都推送到 `main` 分支。
  - 推送前要再次征得你的同意。
- **R10 镜像先只发 GitHub**（2026-11-09 你的决定："你先发GitHub"）：
  - 镜像发布到 `ghcr.io/azurekiln2333/cloudterminal-relay-server`，compose 的默认镜像地址改成它。
  - 第一个正式版本打 `v0.1.0` 标签发布。
  - 首次发布后，需要你在 GitHub 上把这个镜像设为公开（设为公开后不能再改回私有），服务器才能不登录直接拉取。
  - `.cnb.yml` 保留在服务端仓库，路径改好，以后接 CNB 时直接可用。

## Acceptance Criteria

- [x] 两个仓库的所有提交中，都找不到这些内容（扫描命令写进 implement.md，可复现）：
  - `.signing/` 下的文件
  - 签名密码字段
  - `ansi.cjs` / `check-herdr.cjs` / `hold.cjs`
  - `rawfile/flutter_assets`
- [x] 主仓库以下检查全部通过：
  - 根目录的 `flutter analyze` 和 `flutter test`
  - `apps/cloudterminal_windows` 的 analyze 和 test
  - `server` 的 `npm run check` 和 `npm test`
- [x] 服务端仓库的 `npm ci`、`npm run check`、`npm test` 全部通过。
- [x] 两个仓库各自新 clone 到临时目录后，测试同样全部通过。
- [x] 故意改动一份中继核心副本时，一致性检查失败；还原后检查通过。
- [ ] 两个 GitHub 仓库推送后，内容与本地一致，`main` 是默认分支。
- [ ] 镜像：`ghcr.io/azurekiln2333/cloudterminal-relay-server:v0.1.0` 和 `:latest` 由 CI 发布成功，并且不登录就能拉取。本机没有 Docker，用镜像仓库的匿名接口来验证。

## Out of Scope

- 把主仓库的 `server/` 目录改名（比如改成 `agent/`）。
- 在服务端仓库初始化 Trellis。规范和任务记录继续留在主仓库的 `.trellis/`。
- 同步到 Gitee / GitCode / GitLab 等其它代码托管站。
- 主仓库的 CI。
- 11-02 系列任务：账号登录、配对简化、UI 统一、服务端自动更新。
- 删除旧的 `azurekiln2333/cloudterminal-relay` 仓库，由你自己在 GitHub 上处理。
- CNB 仓库与 CNB 镜像发布：以后需要时再接，`.cnb.yml` 已经预留好。
