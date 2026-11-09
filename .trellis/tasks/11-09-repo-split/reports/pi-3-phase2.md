# pi-3 第 2 阶段（2b）报告

## 结论

**完成**。主仓库清理完毕，3 个本地提交已落盘，未推送、未加 remote、未跑 flutter、未运行 task.py。

服务端仓库基线：`fcd073d`（`feat: initial relay server (split from cloudterminal@927fc25)`）。主仓库起点：`927fc25`。

## 做了什么（按 implement.md 2b 的 11 步）

### 1. 复制中继核心

从 `D:\MyNewProjects\cloudterminal-relay-server` 原样复制 5 个文件到 `server/` 同名路径：

`src/relay/relay.ts`、`src/shared/{relay-protocol,protocol-account,crypto,log}.ts`

复制后立即按 design §3 的方式（先 CRLF→LF 再 sha256）逐文件比对，5 个全部一致：

```
OK  c204a785e7f9dbbb   src/relay/relay.ts
OK  7ed809a73b8b933f   src/shared/relay-protocol.ts
OK  6c93328d72e5c7de   src/shared/protocol-account.ts
OK  92228b0c03df673e   src/shared/crypto.ts
OK  43b235df066dc07c   src/shared/log.ts
```

### 2. 改 `server/src/shared/protocol.ts`

按 design §10 第 1 条：删掉原第 7 行 `MAX_FRAME_BYTES`（含其文档注释）和整个 Relay envelope 区段（原第 9–77 行，**包括 `RelayFrame`**），在原位置写成：

```ts
// The relay envelope lives in its own file so the relay server repo can carry
// it without the agent payload types below. Kept byte-identical with
// `cloudterminal-relay-server`; see `scripts/sync-relay.ts`.
export * from './relay-protocol.ts';
```

`PROTOCOL_VERSION` 保留在原处（第 4 行），未动。文件从 457 行减到 390 行，换行仍是 CRLF（`CRLF: 389, LF-only: 0`，与改前同风格）。

### 3. 应用草稿

从 `D:\MyNewProjects\_scratch\repo-split-pi3` 照搬：

- 新增 `server/scripts/sync-relay.ts`、`server/test/relay-core-sync.test.ts`、`server/src/shared/relay-protocol.ts`（副本）
- 覆盖 `server/test/deployment.test.ts`、`server/test/setup.test.ts`、`server/test/herdr.test.ts`、`server/package.json`、`README.md`、`server/TUNNEL.md`

`server/test/helpers.ts` 按 design §10 第 3 条**未动**。

### 4. 删除文件

按 `delete-list.txt` 用 `git rm -- <明确路径>` 逐条删；`server/deploy` 用 `git rm -r -- server/deploy`（顺带删掉了未跟踪的 `deploy/Caddyfile`，该文件在服务端仓库里已存在）。空的 `.github/` 目录随后从磁盘移除。

**删除集合与清单完全一致**：清单 41 条 → 实际删除 44 个文件（`server/deploy/` 展开为 `Caddyfile`、`relay/package.json`、`relay/package-lock.json` 三个文件）。用 `git diff --name-status 927fc25..HEAD --diff-filter=D` 与清单做集合比对，差异项只有这 3 个展开文件，无遗漏、无多余。

### 5. 生成校验文件

```
cd server && node scripts/sync-relay.ts D:/MyNewProjects/cloudterminal-relay-server
copied 5 files from https://github.com/azurekiln2333/cloudterminal-relay-server@fcd073d04e18
wrote relay-core.json                                    exit=0

node scripts/sync-relay.ts D:/MyNewProjects/cloudterminal-relay-server --check
relay core is in sync with ...@fcd073d04e18              exit=0
```

`server/relay-core.json` 记录 `commit: fcd073d04e183c24ac7236d388099ff0cf27d714` 与 5 个哈希。

### 6. 更新依赖锁文件

`cd server && npm install` 成功。`git diff --stat -- server/package-lock.json`：

```
 server/package-lock.json | 105 ++---------------------------------------------
 1 file changed, 3 insertions(+), 102 deletions(-)
```

**锁文件里少掉的包**（10 个，全部是 mysql2 及其独占依赖）：
`mysql2`、`aws-ssl-profiles`、`denque`、`generate-function`、`is-property`、`long`、`lru.min`、`named-placeholders`、`seq-queue`、`sqlstring`。

**唯一的 3 行新增**是两个幸存包的 `"peer": true` 标记，**没有任何版本变化**：

- `node_modules/iconv-lite`（仍是 `0.7.3`）加了一行 `"peer": true`
- `node_modules/safer-buffer`（仍是 `2.1.2`）`"license": "MIT"` 后加了一行 `"peer": true`

这两个包原本由 mysql2 以常规依赖引入，删掉 mysql2 后它们仍被其他依赖链（Claude SDK 那条）需要，npm 于是把它们重新标记为 peer。按 2b 第 6 步的判据（只允许少掉 mysql2 和只被它用到的包；其他包**版本**变了就要停），这里版本没变，所以继续。这一点请协调者留意：它属于 npm 的元数据重算，不是依赖升级。

### 7. 跑检查

```
cd server && npm run check     →  无输出（通过）
cd server && npm test          →  exit 0
```

测试数字（提交前）：

```
ℹ tests 168
ℹ suites 29
ℹ pass 168
ℹ fail 0
ℹ cancelled 0
ℹ skipped 0
ℹ todo 0
ℹ duration_ms 75545.4643
```

三个提交落盘后**又跑了一遍**（提交后复验）：`npm run check` 通过，`npm test` 仍是 `tests 168 / pass 168 / fail 0 / skipped 0 / duration_ms 75630.6548`。

`herdr.test.ts` 的那条 fixture 用例在本机仍然**执行**（`.build/pi-herdr/herdr-probe` 存在），只有 fresh clone 才会跳过；所以本机数字里是 `skipped 0`。

### 8. 查遗留引用

命令（按 implement.md 原样）：

```
git grep -nE "server/README\.md|server/compose|server/Dockerfile|server/deploy|workflows/image\.yml|\.cnb\.yml|src/relay/(api|tenancy|key|show-key|main)\.ts|src/(db|oauth)/" -- ':!.trellis/tasks' ':!.trellis/workspace'
```

**改规范前**命中 9 处，逐条标注：

| # | 位置 | 判断 | 处理 |
|---|---|---|---|
| 1 | `.trellis/spec/backend/deployment.md:5` | 第 9 步列出的规范文件，属于例外 | 按第 9 步只加开头段落，正文不动 |
| 2 | `.trellis/spec/backend/deployment.md:16` | 同上 | 同上 |
| 3 | `.trellis/spec/backend/deployment.md:25` | 同上 | 同上 |
| 4 | `.trellis/spec/backend/deployment.md:37` | 同上 | 同上 |
| 5 | `.trellis/spec/backend/logging-guidelines.md:18` | **不在第 9 步清单里，指向已删除的 `server/src/relay/main.ts`，属于"需要处理"** | **已改**：改为 "The relay entrypoint in `cloudterminal-relay-server` (`src/relay/main.ts`) reports relay-key state as required/off, never its value." |
| 6 | `server/TUNNEL.md:57` | `docker compose -f compose.tls.yml exec relay node src/relay/show-key.ts`，是**在服务端仓库里**执行的命令 | 指向服务端仓库，可以留 |
| 7 | `server/test/setup.test.ts:10` | 我写的注释："key 用例随 `src/relay/key.ts` 搬到 `relay-key.test.ts`" | 描述性文字，可以留 |

**改规范后**再跑一次，只剩 6 处：deployment.md 的 4 处（第 9 步明确例外）、logging-guidelines.md:18（已改成指向服务端仓库的写法，正则仍会命中 `src/relay/main.ts` 这个字符串）、TUNNEL.md:57、setup.test.ts:10。后两条都不是"需要处理"的引用。

补充验证（等价于 pi-1 的第 3 步）：

```
git grep -nE "from '\.\./(db|oauth)/|relay/(api|tenancy|key|show-key|main)\.ts" -- server
→ 只命中 server/TUNNEL.md:57（shell 命令）与 server/test/setup.test.ts:10（注释）
→ 没有任何源码 import
```

### 9. 改规范

在 `.trellis/spec/backend/` 的 `index.md`、`directory-structure.md`、`deployment.md`、`database-guidelines.md` 标题下方各加一段（英文，与规范语言一致），写明三点：

1. 公网中继服务器及其账号 / 数据库 / OAuth、容器镜像、Compose/Caddy 部署文件、出镜像的 CI 已移到 `cloudterminal-relay-server`；
2. 本仓库只保留 5 个中继核心副本（`server/src/relay/relay.ts` 与 `server/src/shared/{relay-protocol,protocol-account,crypto,log}.ts`），供 Agent 进程内提供局域网入口；
3. 要改副本：先改服务端仓库，再 `cd server && npm run sync-relay -- <服务端仓库目录>`；`server/test/relay-core-sync.test.ts` 在副本与 `server/relay-core.json` 不一致时失败。

`deployment.md` 与 `database-guidelines.md` 的段落各多一句，说明"下文描述的容器 / Compose / `server/deploy/` / 镜像 CI / MySQL schema"现在属于服务端仓库，避免正文与开头自相矛盾。四个文件的**其余内容一字未动**。

另外（第 8 步的要求）改了 `logging-guidelines.md` 的那一行，见上表第 5 条。

### 10. 三次提交

每次提交前都跑了第 1 阶段 pi-1 的两条安全检查。本机没有 `grep`（PowerShell 环境），用等价的 `Select-String` 执行，语义相同，并额外加了一条私钥 / 令牌扫描：

- 危险路径检查：`.signing/`、`*.p12|p7b|cer|csr|pfx|jks`、`build-profile.json5`、`*.cjs`、`.env`、`*.pid` → 三次都无输出
- 密钥字段检查：`storePassword|keyPassword` → 三次都无输出
- 附加：`-----BEGIN ... PRIVATE KEY-----`、`gh[pousr]_...`、`sk-ant-...`、`AKIA...` → 无输出

三组文件互不重叠，暂存区每次都只含目标路径（C2 前用 `git diff --cached --name-only` 数出正好 54 个，且不含 docs / spec / 任务目录；C3 前正好 7 个）：

| 提交 | 内容 | 数字 |
|---|---|---|
| `b1d30e1` `test(agent): skip recorded herdr probes when the fixtures are absent` | 仅 `server/test/herdr.test.ts` | 1 file, +11 −1 |
| `2cd0ec5` `refactor(server)!: move the public relay to cloudterminal-relay-server` | 其余代码改动与删除，含 `relay-core.json`、`package.json`、`package-lock.json` | 54 files, +331 −7743 |
| `beed231` `docs: point relay deployment at the server repo` | `README.md`、`server/TUNNEL.md`、`.trellis/spec`（5 个文件） | 7 files, +26 −35 |

`git log --oneline -4`：

```
beed231 docs: point relay deployment at the server repo
2cd0ec5 refactor(server)!: move the public relay to cloudterminal-relay-server
b1d30e1 test(agent): skip recorded herdr probes when the fixtures are absent
927fc25 docs(trellis): record the current specs, tasks and workspace journals
```

`git status --short` 现在是：

```
?? .trellis/tasks/11-09-repo-split/
```

符合 2b 第 10 步的预期，没有多余文件。

### 11. 其他自检

- Agent 入口仍在原位（Windows 助手与 Flutter 集成测试按这个路径找）：`server/src/agent/main.ts` 存在，`Test-Path` = True。
- `server/package.json` 现在是：scripts = `agent`、`check`、`test`、`e2e`、`demo`、`sync-relay`（无 `relay`）；dependencies = `@anthropic-ai/claude-agent-sdk`、`node-pty`、`ws`（无 `mysql2`）。
- 设备端未受影响：`lib/`、`apps/`、`test/`、`pubspec.yaml` 在 `927fc25..HEAD` 之间**零改动**。
- `server/src/relay/` 现在只有 `relay.ts`；`server/src/shared/` 有 `crypto.ts`、`log.ts`、`pairing.ts`、`protocol-account.ts`、`protocol.ts`、`relay-protocol.ts`。

## 和 design.md / implement.md 不一致的地方

1. **锁文件多了 3 行 `"peer": true`**（第 6 步已详述）。没有任何版本变化，按 2b 第 6 步的字面判据不需要停下，但它是"少掉 mysql2"带来的连带走私，提前说明避免 pi-1 / pi-4 复核时误判。
2. **`deployment.md` 的 4 处命中保留未改**。第 8 步说"需要处理的就改掉，第 9 步提到的规范文件例外"，第 9 步又说"文件其余内容不动"。我按"例外"处理：只加开头段落，正文那 4 处（以及 `database-guidelines.md` 正文里的 MySQL 描述）原样保留，靠开头段落说明它们现在属于服务端仓库。如果协调者希望正文也改写，需要另派一次指令。
3. **`logging-guidelines.md` 我改了一行**。它不在第 9 步清单里，但第 8 步的检查命中了它、且它指向已删除的文件，属于"需要处理"，所以按第 8 步处理。
4. **`git rm -r -- server/deploy` 删掉了未跟踪的 `server/deploy/Caddyfile`**。这是 design §10 第 5 条"从主仓库整个删除"的直接结果，且该文件在服务端仓库已存在（已核实 `Test-Path` = True），没有内容丢失。
5. **`server/src/relay/key.ts` 与 `show-key.ts` 在 HEAD 里是已跟踪文件**（第 1 阶段报告里我按 `??` 记为未跟踪，那是当时的快照；pi-1 的提交已把它们纳入）。所以 `git rm` 对它们是正常删除，删除记录出现在 `2cd0ec5` 里。

## 需要协调者决定的事

1. **`deployment.md` / `database-guidelines.md` 的正文是否也要按新边界改写**（现在只有开头段落声明了归属，正文仍是旧描述）。
2. **锁文件那 3 行 `"peer": true` 是否接受**。我判断接受（无版本变化）。如果不接受，替代方案是回退锁文件再手工删 mysql2 段落，但那会让 `npm ci` 与手改内容不一致，不推荐。
3. 主仓库 `server/` 下仍有本机垃圾文件：`server.zip`、`ansi.cjs`、`check-herdr.cjs`、`hold.cjs`（`.cjs` 走 `.git/info/exclude`，未进任何提交）。它们不在我的删除权限内，第 2 阶段也没要求处理，留给第 3 阶段或用户自行清理。
4. `server/TUNNEL.md:57` 与 `server/test/setup.test.ts:10` 仍会命中第 8 步的正则。两者都不是"需要处理"的引用（一个是服务端仓库里执行的命令，一个是说明性注释）。如果 pi-1 复核时按"必须零命中"判定，需要明确放宽这条。
