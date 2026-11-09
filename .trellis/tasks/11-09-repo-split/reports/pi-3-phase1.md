# pi-3 第 1 阶段报告

## 结论

**完成**（只做了准备工作，主仓库未改动一个字节）。有 3 处需要协调者拍板，见最后一节。

工作目录：`D:\MyNewProjects\_scratch\repo-split-pi3`。里面除了草稿，还有一个 `_validation/` 目录，是我用来在本地验证草稿的沙盒（`typecheck/` 是从主仓库 `server/` **只读复制**出来的副本 + 草稿；`fake-relay/` 是假的服务端仓库）。`_validation/` 不是草稿，第 2 阶段不需要它。

对主仓库只做了读操作：`Get-Content` / `Select-String` / `git status` / `git ls-files` / `Copy-Item`（单向复制出来）。没有在主仓库跑 `npm install`、`npm test`、`flutter`，没有建 junction/symlink，没有改 git 状态。

## 一、引用检查（第 1 项）

要移走的：`src/relay/{api,tenancy,key,show-key,main}.ts`、`src/db/**`（8 个文件）、`src/oauth/**`（6 个文件）。

会留下的（agent、scripts、留下的测试）**没有任何一个 import 了要移走的文件**。逐条核对结果：

| 留下方 | 引用情况 | 处理 |
|---|---|---|
| `src/agent/**`（22 个文件） | 只 import `../relay/relay.ts`、`../shared/{protocol,protocol-account,pairing,crypto,log}.ts` | 不需要改 |
| `src/relay/relay.ts`（副本） | 当前 import `./tenancy.ts`（第 17 行）和 `../db/pool.ts`（第 18 行）；这两处正是 design §2 要解耦掉的 | 第 2 阶段用服务端仓库解耦后的版本整个覆盖 |
| `scripts/{demo-agent,e2e,herdr-smoke}.ts` | 只 import `../src/relay/relay.ts`（`createRelay`） | 不需要改 |
| `scripts/tunnel-relay.ps1` | 以 `--local-relay` 启动 `src/agent/main.ts`，不碰 `relay/main.ts` | 不需要改 |
| `start.cmd` / `start.sh` / `start-windows.cmd` | 不引用 `src/relay/**`、`src/db/**`、`src/oauth/**`，也没有 `npm run relay` | 不需要改 |
| `server/test/helpers.ts` | **没有 db 相关代码**：`startRelay` 只把 opts 透传给 `createRelay` | **不需要改**（见「与设计不一致」第 3 条） |
| `server/test/relay.test.ts`（保留） | import `../src/relay/relay.ts` + `helpers.ts`；全文没有 `relayToken`/`account`/`bindingCache` 字样 | 解耦后仍能编译，不需要改 |
| `server/test/relay-sidecar.test.ts`、`link.test.ts`、`setup-cli.test.ts`、`core/terminal/normalize/pairing/bootstrap/desktop-terminal/sidecar/herdr*/fake-query` | 只用 `createRelay`/`helpers`/`protocol`/agent | 不需要改 |
| `server/test/deployment.test.ts` | 第 109 行的"relay startup"用例 `launch('src/relay/main.ts')` 与 `launch('src/relay/show-key.ts')` | 该用例整体搬去服务端仓库；本地草稿已删除（见第 2 项） |
| `server/test/setup.test.ts` | 第 8 行 `import { registrationKey } from '../src/relay/key.ts'`，第 74 行用例用 `registrationKey` | 删 import + 删用例（见第 2 项） |
| `server/package.json` | 第 11 行 `"relay": "node src/relay/main.ts"` | 删该脚本（见第 2 项） |

补充两条 `grep` 事实：

- 全仓库（排除 `node_modules`/`build`/`.dart_tool`）搜 `relay/main|show-key|src/db|src/oauth|npm run relay|relay/api|relay/tenancy`，命中的**全部**是要移走目录内部的自引用，或上面表格里已处理的 3 处（`deployment.test.ts`、`setup.test.ts`、`package.json`），以及 `.github/workflows/image.yml:175`（这个文件整体搬去服务端仓库）。没有任何文档/脚本写 `npm run relay`。
- `src/shared/protocol.ts` 是唯一被大量引用的共享文件，它的外部消费者（`agent/link.ts:10-12`、`relay.ts:8-11`、`test/link.test.ts:11`、`test/terminal.test.ts:7`）全部从 `../shared/protocol.ts` 导入，所以 design §4 的「`protocol.ts` 改成 `export * from './relay-protocol.ts'`」对这些调用方是透明的。

## 二、草稿文件清单（第 2 项）

全部按主仓库相对路径放在工作目录下：

| 草稿路径 | 说明 |
|---|---|
| `server/scripts/sync-relay.ts` | 新增。`npm run sync-relay -- <服务端仓库目录>` 复制 5 个副本文件并重写 `relay-core.json`；`--check` 只比对、非 0 退出。sha256 先 CRLF→LF 再算。用 `import.meta.dirname` 定位于 `server/`，不依赖 cwd。 |
| `server/test/relay-core-sync.test.ts` | 新增。重算哈希与 `relay-core.json` 比对；同时校验清单里的文件集合与副本文件集合一致（漏登记文件也会失败）。失败信息写明"先改服务端仓库，再跑 sync-relay"。 |
| `server/test/deployment.test.ts` | 改。删掉第 109 行起的 relay startup 用例；去掉随之无用的 `readFile` 与 `TestSocket` import，并加两行注释说明用例去向。剩余 109 行，只留原第 49、92 行两个 agent 用例。 |
| `server/test/setup.test.ts` | 改。删掉第 8 行 `registrationKey` 的 import（换成注释说明已移到服务端仓库的 `relay-key.test.ts`）和第 74 行的 relay key 用例。`readFile`/`writeFile` 仍被 config reset 用例使用，import 保留。 |
| `server/test/herdr.test.ts` | 改。`describe('herdr probe fixtures')` 的用例改成 `async (t)`，两个 fixture 文件缺失时 `t.skip('<原因>')` 后 return；import 增加 `existsSync`。原因文字里写明 `.build/` 不提交、fresh clone 没有录制文件、需要时怎么重录。 |
| `server/package.json` | 改。删 `mysql2` 依赖和 `relay` 脚本，加 `sync-relay` 脚本。`description` 改为"PC agent + 进程内局域网中继"。 |
| `README.md` | 改。① 开头架构列表里的 Relay 一条改为"公网中继独立在 cloudterminal-relay-server 仓库，本仓库保留中继核心副本供 Agent 提供局域网入口"。② 「公网中继服务器（推荐外出使用）」整节重写为 5 段：指向服务端仓库及其 README、说明本仓库只留哪 5 个副本文件、说明副本以服务端仓库为准且 `npm test` 会检查、说明镜像由服务端仓库 CI 发布且首次发布前不存在、部署完成后电脑填什么。原来指向 `.github/workflows/image.yml`、`.cnb.yml`、`server/compose*.yml`、`server/deploy/Caddyfile`、`server/README.md` 的链接与命令**全部移出**该节，改指服务端仓库；末尾指向 `server/TUNNEL.md`。 |
| `server/TUNNEL.md` | 改。开头新增两仓库分界说明（服务器上的中继 = 服务端仓库；本机 `--local-relay` = 本仓库的 `server/scripts/tunnel-relay.ps1`）。原来 4 处指向 `./README.md`（即 `server/README.md`，已搬走）的链接改指服务端仓库 README；方式 A 的第 3 步从"上传 `server/` 目录"改为 `git clone` 服务端仓库根目录。 |
| `delete-list.txt` | 第 3 项要求的删除清单，一条一行带理由；末尾带一组"不要删除"的兜底行，防止第 2 阶段手滑删掉副本文件。 |

`server/test/helpers.ts` **没有出草稿**：主仓库版本本来就没有 db 代码（只有"服务端仓库的版本需要接受 `{db, bindingCacheMs}` 并内部组装 tenancy"），所以按 implement.md 的条件"如果有 db 相关代码就去掉"，这里不成立。

## 三、关键命令和结果

### 1) 草稿类型检查

把主仓库 `server/`（`src` + `tsconfig.json` + `package.json` + `test/helpers.ts` + `test/fake-query.ts`）**复制**到 `_validation/typecheck/server/`，覆盖上草稿，用主仓库已装好的 tsc 编译（`node_modules` 没有复制、也没有链接）：

```
D:\MyNewProjects\_scratch\repo-split-pi3\_validation\typecheck> tsc -p tsconfig.json
```

结果：与草稿相关的错误 **0 条**（用 `Select-String -Pattern "sync-relay|relay-core-sync|deployment.test|setup.test|herdr.test"` 过滤，输出为空）。剩下的错误全部是沙盒里没有第三方包导致的既有噪声，与草稿无关：

```
server/src/agent/pty.ts(1,23): error TS2307: Cannot find module 'node-pty' ...
server/src/agent/sdk.ts(3,57): error TS2307: Cannot find module '@anthropic-ai/claude-agent-sdk' ...
server/src/db/accounts.ts(7,36): error TS2307: Cannot find module 'mysql2' ...
server/src/db/bindings.ts(7,36): error TS2307: Cannot find module 'mysql2' ...
server/src/db/devices.ts(7,36): error TS2307: Cannot find module 'mysql2' ...
server/src/db/migrate.ts(15,36): error TS2307: Cannot find module 'mysql2' ...
server/src/db/pool.ts(8,19): error TS2307: Cannot find module 'mysql2/promise' ...
server/src/db/tokens.ts(8,36): error TS2307: Cannot find module 'mysql2' ...
server/src/oauth/flows.ts(17,36): error TS2307: Cannot find module 'mysql2' ...
server/src/agent/sdk.ts(24,26): error TS7006: Parameter 's' implicitly has an 'any' type.  ← 由 SDK 缺失连带
```

### 2) 改过的两个测试真的能跑

```
> node --test test/setup.test.ts
✔ setup persists connection, directories, terminal preference and identity (19.1151ms)
✔ setup validates addresses and never carries key to a different relay (4.2276ms)
✔ config reset preserves preferences and malformed configuration never replaces identity (18.1925ms)
ℹ tests 3   ℹ pass 3   ℹ fail 0
```

```
> node --test test/herdr.test.ts
✔ AgentCore herdr routing (20.4759ms)
▶ herdr probe fixtures
  ﹣ parses every recorded live probe file (0.2219ms) # no recorded probe fixtures under ...\_validation\typecheck\.build\pi-herdr\herdr-probe (..\.build\pi-herdr\herdr-probe is not committed)
✔ herdr probe fixtures (0.2821ms)
ℹ tests 62   ℹ suites 9   ℹ pass 61   ℹ fail 0   ℹ skipped 1   ℹ duration_ms 215.2634
```

（主仓库里 `.build/pi-herdr/herdr-probe/` 现在确实存在，包含 `workspace-list.json`、`agent-list.json` 等 12 个文件，并且 `.gitignore:8` 已忽略 `.build/`。所以本机跑这个用例仍然照常执行，只有 fresh clone 才跳过。）

`deployment.test.ts` 改后**没有运行**：它 spawn 真实的 `src/agent/main.ts`，需要 `node-pty` 原生模块，沙盒里没有。改动只是删除 + 去 import，已通过类型检查；行为验证交给第 2 阶段 `npm test` / pi-1 的全量检查。

### 3) `sync-relay.ts` 与 `relay-core-sync.test.ts` 的契约验证

在 `_validation/fake-relay`（`git init -b main` + 一个提交，5 个副本文件，`relay-protocol.ts` 先用占位内容）上跑：

```
> node scripts/sync-relay.ts ../../fake-relay
copied 5 files from https://github.com/azurekiln2333/cloudterminal-relay-server@71ebca3e97d4
wrote relay-core.json
exit=0

> node scripts/sync-relay.ts ../../fake-relay --check
relay core is in sync with https://github.com/azurekiln2333/cloudterminal-relay-server@71ebca3e97d4
exit=0

# 故意改动本地副本 src/shared/crypto.ts 后
> node scripts/sync-relay.ts ../../fake-relay --check
relay core is out of sync:
  src/shared/crypto.ts: c8dea8db... != 92228b0c...
The relay core copy must match the relay server repo.
Fix it in the relay server repo first, then run:
  npm run sync-relay -- <path-to-cloudterminal-relay-server>
exit=1

> node --test test/relay-core-sync.test.ts
✖ the relay core copy matches relay-core.json ...  AssertionError [ERR_ASSERTION]: relay core copy is out of sync: ...
ℹ tests 1   ℹ pass 0   ℹ fail 1

# 还原（重新 sync）后
> node --test test/relay-core-sync.test.ts
ℹ pass 1   ℹ fail 0

# 副本换成 CRLF 换行（模拟 Windows checkout）
> node scripts/sync-relay.ts ../../fake-relay --check
relay core is in sync ...
exit=0

# relay-core.json 里多登记一个不在副本集合里的文件
> node scripts/sync-relay.ts ../../fake-relay --check
relay core is out of sync:
  src/shared/protocol.ts: listed in relay-core.json but not a copy file
exit=1
```

结论：正向复制、`--check` 通过、内容漂移失败、清单漂移失败、CRLF 不误报，五项都符合 design §3。

## 四、删除清单（第 3 项）

清单写在 `delete-list.txt`，共 **38 条删除项**，分组：

- `src/relay/`：`api.ts`、`tenancy.ts`、`key.ts`、`show-key.ts`、`main.ts`（5）
- `src/db/`：全部 8 个文件
- `src/oauth/`：全部 6 个文件
- `test/`：`db-bindings`、`db-config`、`db-migrate`、`db-tokens`、`db-helpers`、`fake-db`、`oauth-config`、`oauth-discovery`、`oauth-flows`、`oauth-verify`、`relay-api`、`relay-tenancy`、`deployment-image`（13）
- 部署与文档：`Dockerfile`、`.dockerignore`、`.env.example`、`compose.yml`、`compose.tls.yml`、`compose.build.yml`、`deploy/`、`README.md`（8）
- CI：`.github/workflows/image.yml`、`.cnb.yml`（2）

另附 7 条"**不要**删除"的兜底行：`protocol.ts`（只改内容）、`protocol-account.ts`、`relay.ts`（用副本覆盖）、`helpers.ts`、`relay.test.ts`、`TUNNEL.md`、`scripts/tunnel-relay.ps1`。

需要知道的两条现状：

- `.github/workflows/image.yml` 和 `.cnb.yml` 目前在主仓库是**未跟踪**文件（`??`）。pi-1 的 C3 组会把它们提交进主仓库，第 2 阶段再删掉——历史里会留下它们，这符合 design §8「主仓库保留完整历史」，且不含密钥。
- `server/deploy/` 里已跟踪的是 `deploy/relay/package.json` 与 `package-lock.json`（Dockerfile 装中继依赖用），未跟踪的还有 `deploy/Caddyfile`。design §5 说 `deploy/relay/package.json` 的去留"不在本任务范围内，原样保留"——我理解是**保留在服务端仓库**，因此整目录从主仓库删除。请确认（见下一节第 3 条）。

## 五、第 2 阶段应用步骤（给未来的我/协调者）

顺序重要，先把副本抄回来再删，否则 `relay.ts` 会被删掉。

1. `cd D:\MyNewProjects\cloudterminal`，确认 pi-1 已完成第 1 阶段提交（`git status --short` 只剩 `?? .trellis/tasks/11-09-repo-split/`）。
2. 等 pi-2 报告服务端仓库的 5 个副本文件已就位且 `npm run check`/`npm test` 通过。
3. 抄回副本（覆盖）：把服务端仓库的 `src/relay/relay.ts`、`src/shared/{relay-protocol,protocol-account,crypto,log}.ts` 复制到 `server/` 同名路径。**先抄再删。**
4. 改 `server/src/shared/protocol.ts`（design §4，这一步不在我第 1 阶段的草稿清单里，见下一节第 4 条）：删掉第 7 行 `MAX_FRAME_BYTES` 和「Relay envelope」区段（第 9–77 行，除 `RelayFrame` 外，见不一致第 1 条），改为 `export * from './relay-protocol.ts';`。
5. 应用我的草稿：`server/scripts/sync-relay.ts`、`server/test/relay-core-sync.test.ts`（新增）；`server/test/{deployment,setup,herdr}.test.ts`、`server/package.json`、`README.md`、`server/TUNNEL.md`（覆盖）。
6. 按 `delete-list.txt` 删除（用明确路径，逐条删，不用 `git rm -r .`）。
7. 生成 `server/relay-core.json`：`cd server && node scripts/sync-relay.ts ../..\cloudterminal-relay-server`（第 1 阶段草稿里没有这个文件，它是生成物，必须由第 2 阶段生成，不要手写哈希）。然后 `node scripts/sync-relay.ts <dir> --check` 应为 0。
8. `cd server && npm install`（更新 `package-lock.json`：去掉 mysql2），再 `npm run check && npm test`。
9. `git add -- <明确路径>` 分组提交（沿用 pi-1 的提交前两条安全 grep）。
10. 交给 pi-1 跑主仓库全量检查（含 flutter），pi-4 跑 fresh-clone 与"故意改副本"的验证。

## 六、和 design.md / implement.md 不一致的地方

**1) design §4：要移走的区段引用了区段外的符号（需要决定）**

design §4 说"动手前先确认这个区段不引用区段外的东西（例如 `PROTOCOL_VERSION`）"。检查结论：

- `PROTOCOL_VERSION` 在区段外（第 4 行），但区段内**没有**引用它 → 这条没问题。
- **但 `RelayFrame`（第 59 行）的两个 `msg` 变体引用了 `ClientMessage`（第 347 行）和 `AgentMessage`（第 387 行），这两个类型在 "Agent protocol" 区段里，属于区段外。** 服务端仓库没有完整的 `protocol.ts`，所以机械照 §4 搬会让服务端仓库的 `relay-protocol.ts` 类型不完整（编译报 `Cannot find name 'ClientMessage'`）。

可选修法（我倾向 A）：

- **A. 把 `RelayFrame` 留在主仓库 `server/src/shared/protocol.ts`**，`relay-protocol.ts` 只搬 `MAX_FRAME_BYTES`、`AgentHello`/`ClientHello`/`PairHello`/`Hello`、`PAIR_CODE_ALPHABET`/`PAIR_CODE_LENGTH`/`normalizePairCode`、`RelayErrorCode`。依据：`grep -rn RelayFrame server/src server/test` 只有 `protocol.ts:59` 一处定义，**没有任何消费者**（`protocol-account.ts:41` 的 `AccountRelayFrame` 是独立的类型）；服务端仓库不需要 `RelayFrame`。代价：design §4 的"区段"描述要改一句话。
- B. 把 `ClientMessage`/`AgentMessage` 一起搬过去（不行：它们是 agent 载荷，服务端仓库不需要，而且会与"服务端仓库只有 relay-protocol.ts"冲突）。
- C. `relay-protocol.ts` 里把 `msg` 变体写成 `data: unknown`（能编译，但主仓库会丢掉 `RelayFrame` 的类型精度）。

**2) `server/TUNNEL.md` 留在主仓库，但它的"方式 A"整段是服务器部署（需要决定）**

按 implement.md 我只把链接改指服务端仓库，并在开头加了"两个仓库分别管什么"的分界说明。方式 A（`docker compose -f compose.tls.yml`、Caddy、`git clone` 服务端仓库）现在用的是服务端仓库的文件，放在主仓库文档里读起来是跨仓库的。如果希望更干净，可以把方式 A 整段搬到服务端仓库 README，主仓库 `TUNNEL.md` 只留方式 B/C。我没有擅自搬，因为那会改变 pi-2 对服务端 README 的内容决定。

**3) `server/test/helpers.ts` 不需要改**

implement.md 写"`server/test/helpers.ts`：如果有 db 相关代码，就去掉"。主仓库版本本来就没有 db 代码（`startRelay(opts)` 直接透传 `createRelay`），所以草稿里没有这个文件。解耦后主仓库的 `RelayOptions` 没有 `db`/`bindingCacheMs`，这个 helpers 依然正确。**只有服务端仓库的 helpers 需要接受 `{db, bindingCacheMs}` 并在内部组装 tenancy**（那是 pi-2 的范围）。

**4) 我的草稿清单里缺两件东西（已写进应用步骤）**

- `server/src/shared/protocol.ts` 的改法不在 pi-3 第 1 阶段的 9 条草稿清单里，但 design §4 要求主仓库 `protocol.ts` 删掉区段并 re-export。我在第五节第 4 步给了确切行号与做法，但没有生成草稿文件（避免和 pi-2 对 `relay-protocol.ts` 的边界决定打架）。
- `server/relay-core.json` 是 sync 脚本生成物（含服务端仓库 commit），第 1 阶段不可能有正确内容，必须第 2 阶段生成。

**5) 主仓库历史里会保留服务端代码**

第 2 阶段的删除只影响工作树，主仓库的 git 历史仍会包含 `server/{Dockerfile,compose*,README.md,deploy/}`、`src/db/**`、`src/oauth/**`、`.github/workflows/image.yml`、`.cnb.yml`。这些都不含密钥（design §8 已扫描），但意味着"主仓库里搜不到服务端代码"这句话对历史不成立。如果验收标准是这样理解的，需要澄清。

## 七、需要协调者决定的事

1. **design §4 的 `RelayFrame` 怎么处理**（第六节第 1 条，我倾向方案 A：`RelayFrame` 留在主仓库 `protocol.ts`，不进 `relay-protocol.ts`）。这会影响 pi-2 的 `relay-protocol.ts` 内容与 `deployment-image.test.ts` 的期望，最好在 pi-2 提交前定下来。
2. **`server/TUNNEL.md` 的方式 A 是否整段移到服务端仓库**（第六节第 2 条）。
3. **`server/deploy/` 是否整体从主仓库删除**（含已跟踪的 `deploy/relay/package.json` 与 `package-lock.json`）。design §5 说"去留不在本任务范围内，原样保留"，我理解为保留在服务端仓库，但字面上也可能是"留在主仓库"。`delete-list.txt` 里我是按"从主仓库删除"写的。
4. **`server/package.json` 删掉 `relay` 脚本后，是否还保留一个"本机跑独立中继"的入口**。现在删了以后，想在服务器上手动跑中继就只能去服务端仓库（这是设计意图）。如果有人习惯 `cd server && npm run relay`，会失效；全仓库已确认没有任何脚本/文档依赖它。
5. **本机垃圾文件不删但要交代**：`server/server.zip`、`server/{ansi,check-herdr,hold}.cjs`、`server.zip`（仓库根）、`.build-apk.pid`、`build-apk.log`、`flutter_01.log`。按规则 2 我不删不属于我的文件，它们也按规则 4 不进提交（`.cjs` 走 `.git/info/exclude`，`*.pid` 走 `.gitignore`）。但 `server.zip`（根目录）和两个 `.log` 不在 pi-1 的忽略清单里；如果它们是未跟踪文件，`git status --short` 最终就不会只剩任务目录，pi-1 的第 3 步会看到多余条目。请确认这些是否也要加进 `.gitignore`。
6. **主仓库 README 里关于镜像的表述**：我保留了"首次发布之前镜像还不存在，需要按那份 README 自行构建"这一句，以延续原来的诚实表述。但 `docs never claim an unpublished image exists` 用例（design §5）是服务端仓库的测试，扫的是服务端仓库的文档，主仓库这句不参与该用例。如果协调者希望主仓库完全不提镜像，我可以删掉那半句。
