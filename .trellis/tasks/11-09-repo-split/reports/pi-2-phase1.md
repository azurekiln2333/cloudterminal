# pi-2 第 1 阶段报告：在新目录搭服务端仓库并解耦

## 结论

**完成。** 服务端仓库 `D:\MyNewProjects\cloudterminal-relay-server` 已建好、已解耦、`npm run check` 与 `npm test` 全绿、已在本地提交 `0def841`，没有 remote，没有推送。主仓库全程只读。

## 做了什么

工作目录 `D:\MyNewProjects\cloudterminal-relay-server`（开工前确认不存在，现新建）。

1. **复制**（`server/` 根 → 新仓库根）
   - `src/relay/{relay,api,tenancy,key,show-key,main}.ts`
   - `src/db/*`（8 个）、`src/oauth/*`（6 个）
   - `src/shared/{protocol-account,crypto,log}.ts`
   - `test/`：`relay` `relay-api` `relay-tenancy` `db-bindings` `db-config` `db-migrate` `db-tokens` `oauth-config` `oauth-discovery` `oauth-flows` `oauth-verify` `deployment-image` 的 `.test.ts`，加 `helpers.ts` `fake-db.ts` `db-helpers.ts`
   - `Dockerfile` `.dockerignore` `.env.example` `compose.yml` `compose.tls.yml` `compose.build.yml` `deploy/`（Caddyfile + relay/package*.json）`README.md` `tsconfig.json`
   - `.github/workflows/image.yml`、`.cnb.yml`
   - 未复制：`node_modules`、`server.zip`、`*.cjs`、agent 代码与 agent 测试。
   - 逐字节核对：以上未改动的副本文件与主仓库 `server/` 下同名文件 SHA256 完全一致（仅 `.env.example`、`compose.yml`、`compose.tls.yml`、`tsconfig.json` 因下面的改动不同）。

2. **`package.json`**：`cloudterminal-relay-server`、`type: module`、`engines.node >=23.6`；依赖只留 `mysql2` `ws`，devDependencies 照抄；scripts 只有 `relay` / `check` / `test`。另建 `.gitignore`（`node_modules/`、`.env`、`.env.*`、`!.env.example`，另加 `*.cjs`/`*.pid`/`*.log` 防误提交）。

3. **拆协议文件**（design §4）：新建 `src/shared/relay-protocol.ts`，`MAX_FRAME_BYTES` + Relay envelope 区段（`AgentHello`/`ClientHello`/`PairHello`/`Hello`、`PAIR_CODE_*`、`normalizePairCode`、`RelayErrorCode`、`RelayFrame`）整段迁入。`relay.ts` 改为从 `../shared/relay-protocol.ts` 导入；不再导入 `../shared/protocol.ts`。

4. **解耦**（design §2）
   - `relay.ts`：新增导出 `AccountClientResult`、`AccountAuthorizer`；`RelayOptions` 删 `db`、`bindingCacheMs`，新增 `accounts?: AccountAuthorizer`；内置 `unavailableAccounts`（`available=false`，`authorizeClient → {ok:false,reason:'no_database'}`，`invalidate` 空）。`relay.ts` 现在**完全没有** `tenancy.ts` / `db/` 的 import（已 grep 确认，只剩注释和日志文案里出现 "tenancy" 字样）。
   - `tenancy.ts`：`import type { AccountAuthorizer, AccountClientResult } from './relay.ts'`；`Tenancy = AccountAuthorizer & { …boundAccounts / stats… }`；删掉本地重复的 `AccountClientAuth`/`AccountClientDenied`/`AccountClientResult` 定义。
   - `main.ts`：`createRelay({ relayKey, accounts: createTenancy({ pool: db, logger: log }), logger: log })`。
   - `test/helpers.ts`：`startRelay` 改成 `TestRelayOptions = RelayOptions & { db?, bindingCacheMs? }`，内部 `createTenancy({ pool: db ?? null, bindingCacheMs })` 组装后注入 `accounts`。
   - `test/relay-api.test.ts`：两处 `createRelay({ db … })` 改为 `createRelay({ accounts: createTenancy({ pool: db }) })`。

5. **新测试**（design §6，用例从主仓库移植、辅助函数一并带上）
   - `test/relay-startup.test.ts` ← `deployment.test.ts` 第 109 行的用例（含 `childEnv`/`launch`/`stop`/`waitFor`/`freePort`）。
   - `test/relay-key.test.ts` ← `setup.test.ts` 第 74 行的用例。

6. **CI 与镜像地址**（design §5）
   - `image.yml`：`context: ./server` → `context: .`，`file: ./server/Dockerfile` → `./Dockerfile`，`node --test server/test/deployment-image.test.ts` → `node --test test/deployment-image.test.ts`。
   - `.cnb.yml`：静态检查路径同上；`docker build … server/` → `docker build … .`；头部注释里的 `server/test/…` 一并改掉。
   - `deployment-image.test.ts`：`const repoDir = serverDir`（原来是 `resolve(serverDir,'..')`，在新仓库会指到 `D:\MyNewProjects`），并把最后一个用例改名为 `repository root stays self-contained for source deployments`、断言文案里的 `server/` 换成 `the repository`。
   - 默认镜像：`ghcr.io/azurekiln2333/cloudterminal-relay-server:latest`（`compose.yml`、`compose.tls.yml`、`.env.example`、`README.md`）。
   - `README.md` 开头加了「电脑端 agent 与 App 在 https://github.com/azurekiln2333/cloudterminal」；`cd /opt/cloudterminal/server` → `/opt/cloudterminal-relay-server`；`manifest inspect`、升级 `sed` 命令、构建上下文说明同步改。

## 关键命令和结果

```
$ node -v ; npm -v
v24.15.0
11.14.1

$ npm install            # 仅在新目录执行，未碰主仓库 server/
added 17 packages, and audited 18 packages in 10s

$ npm run check
> tsc --noEmit
（无输出，退出码 0）

$ npm test
ℹ tests 119
ℹ suites 22
ℹ pass 119
ℹ fail 0
ℹ cancelled 0
ℹ skipped 0
ℹ todo 0
ℹ duration_ms 1526.347
```
MySQL 相关套件按预期跳过（node 用 `﹣` 标记，不计入 pass/fail）：
```
﹣ bindings (0.3335ms) # no MySQL configured: set CT_TEST_MYSQL_URL (or DB_HOST/DB_USER/DB_NAME) to run this suite
﹣ migrations (0.5520ms) # 同上
﹣ tokens (0.3436ms) # 同上
﹣ api over MySQL (AC1/AC4) (0.0177ms) # 同上
```

`node --test test/deployment-image.test.ts` 单独跑：`ℹ tests 10 / pass 10 / fail 0`。

```
$ grep -rn "src/agent" src test      # 用 PowerShell Select-String 等价执行
no matches for src/agent
```

`git diff --cached --name-only | grep node_modules`：无输出。提交前禁入项检查（`.signing/`、`*.p12|p7b|cer|csr|pfx|jks`、`build-profile.json5`、`*.cjs`、`.env`、`*.pid`）无输出；`storePassword|keyPassword|PRIVATE KEY` 无输出。

### 5 个副本文件的 sha256（CRLF→LF 后计算，design §3 的命令）

```
c204a785e7f9dbbbed6d3046fb8d52d966bbb9d46fd47ec20cc0491ca8125ae6 src/relay/relay.ts
7ed809a73b8b933f7aac49bd3de139838de110a7ad095d218ebcafa629eba881 src/shared/relay-protocol.ts
6c93328d72e5c7deba01a04f52523fcad664baed5d58f2e29465f3ff6a67aad5 src/shared/protocol-account.ts
92228b0c03df673ef972591fb3fe99aaad93a468e09a3a7966fdacf1c6656700 src/shared/crypto.ts
43b235df066dc07cb27e734f1085a7f766ff09020eaaa7ee5982252496af0952 src/shared/log.ts
```

### git log

```
$ git log --oneline
0def841 feat: initial relay server (split from cloudterminal@43cc663)
```
（`git remote -v` 空；`git status --short` 空；58 files changed, 9100 insertions。）

## 和 design.md 不一致的地方

1. **§4 的区段其实引用了区段外的符号。** `RelayFrame` 的两条 `msg` 分支用了 `ClientMessage` / `AgentMessage`（它们在 `protocol.ts` 后半段）。服务端仓库里没有 `protocol.ts`，所以 `relay-protocol.ts` 把这两处 `data` 标成 `unknown` 并加注释说明「payload 是另一种协议，中继不看内容」。`RelayFrame` 目前全仓库无人使用（只有定义），因此没有类型损失；但如果主仓库将来要用它做类型约束，会失去 `data` 的具体类型。其余（`MAX_FRAME_BYTES`、hello 类型、PAIR_CODE_*、`normalizePairCode`、`RelayErrorCode`）都不依赖区段外的东西。
2. **多复制了 `TUNNEL.md`**（不在 pi-2 的复制清单里）。原因：`deployment-image.test.ts` 有两个用例会读 `TUNNEL.md`（`read('TUNNEL.md')`），不复制就 ENOENT，`npm test` 不可能全绿。我把里面两处路径改成指向本仓库 / 指向主仓库脚本。见下面待决定项 1。
3. **`deployment-image.test.ts` 改的不止「目录推算」。** 除 `repoDir` 外，最后一个用例的**名字和断言文案**从 `server directory` 改为 `repository root`（行为断言不变）。
4. **`tsconfig.json` 的 `include` 去掉了 `"scripts"`**，因为新仓库没有 `scripts/` 目录（留着也不报错，只是没必要）。
5. **`.gitignore` 除了要求的三项，另加了 `*.cjs` / `*.pid` / `*.log`**（本仓库里没有这些文件，纯属防御）。
6. **`README.md` 里 CNB 那行仍以 `docker.cnb.cool/azurekiln/cloudterminal` 开头**（写成 `docker.cnb.cool/azurekiln/cloudterminal-relay-server:<tag>`）。因为 `deployment-image.test.ts` 的正则 `/docker\.cnb\.cool\/azurekiln\/cloudterminal/` 是前缀匹配，这样既能通过用例，也符合「默认改成 GitHub 路径」的要求。若主仓库期望 CNB 用别的 slug，需要同步改这条断言。
7. **提交信息里的来源提交号是 `43cc663`**（我开工时主仓库的 HEAD，也是我复制文件时的内容）。pi-1 随后把工作提交到了 `927fc25`，所以现在主仓库 HEAD 已经不是 `43cc663`。我核对过：本次复制的未改动文件与主仓库 `server/` 当前工作区字节一致，内容没有落后。
8. **`git` 提示 `LF will be replaced by CRLF`**（本机 `core.autocrlf`）。工作区是 CRLF，仓库里存的是 LF。design §3 的哈希校验本来就先做 CRLF→LF，所以不受影响。

## 需要协调者决定的事

1. **`TUNNEL.md` 的去留。** 现在主仓库 `server/TUNNEL.md` 和本仓库 `TUNNEL.md` 各有一份（本仓库这份为让测试通过而复制）。三种做法：(a) 两边都留，主仓库那份改成「详见服务端仓库」的短页；(b) 服务端仓库留全份，主仓库删掉并在 README 里链接；(c) 服务端仓库不留，改 `deployment-image.test.ts` 去掉 `TUNNEL.md` 相关断言。我倾向 (b)，但这会让第 2 阶段 pi-3 的删除清单多一项，请拍板。
2. **`TUNNEL.md` 里 `pwsh -File server/scripts/tunnel-relay.ps1` 的指引**：该脚本留在主仓库（`server/scripts/`），我已把文案改成「主仓库配套的脚本」。如果最终选 (b)/(c)，这句还要再调整。
3. **主仓库 `server/src/shared/protocol.ts` 必须同步改**（design §4 的后半句）：删掉已迁走的区段、改成 `export * from './relay-protocol.ts'`，并新增 `server/src/shared/relay-protocol.ts`（内容 = 本仓库这份）。这属于第 2 阶段 pi-3 的活，我不越界动主仓库，但**指出来**：只删不改会让 `agent/link.ts`、`agent/core.ts`、`terminal.test.ts`、`link.test.ts` 找不到 `MAX_FRAME_BYTES` / `PAIR_CODE_*` / `PROTOCOL_VERSION`。
   另注意：主仓库那份 `relay-protocol.ts` 会带上 `data: unknown`，如果主仓库的 agent 侧将来需要 `RelayFrame` 的具体类型，得在主仓库的 `protocol.ts` 里重新声明一个更精确的 `RelayFrame`（用 `Omit`/映射），或在服务端仓库侧把这两条分支的 payload 泛型化。现在无人使用，可以先不管。
4. **`RELAY_IMAGE` 默认值从 CNB 换到 GitHub（ghcr.io/azurekiln2333/…）** 是按 design §5 做的。但 CNB 流水线仍然存在（`.cnb.yml` 保留备用），它的默认推送到 `docker.cnb.cool/<slug>`，和 Compose 默认值不再一致。如果第 3 阶段打算先发 CNB，记得在同一次 PR 里把默认值改回来或让用户显式设 `RELAY_IMAGE`。
5. **`deploy/relay/package.json` 的去留**：design §5 说不在本任务范围、原样保留。我原样复制了（`deployment-image.test.ts` 的「image never carries desktop agent dependencies」用例依赖它）。镜像构建时 `Dockerfile` 用的是它、不是新根目录的 `package.json`，所以两份依赖清单现在并存（内容上都是 `mysql2`+`ws`，但版本来源不同，将来可能漂移）。是否在第 2 阶段统一成一份，请协调者决定。
6. **服务端仓库没有 `.gitattributes`**，Windows 工作区会写 CRLF。为避免第 2 阶段的 `relay-core-sync.test.ts` 出伪差异，design 已经要求哈希前统一成 LF，所以可以不加；如果希望仓库内文件永远是 LF（便于 Docker/CI 一致），建议第 2 阶段补一个 `* text=auto eol=lf`。
