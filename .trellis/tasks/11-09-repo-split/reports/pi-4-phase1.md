# pi-4 第 1 阶段报告

## 0. 结论

**部分完成。**

- 两个脚本按 implement.md 写完，`bash -n` 通过，并用临时小仓库跑通了"干净 / 脏 / 历史里删过"三种场景；没有在 `cloudterminal` 和 `cloudterminal-relay-server` 上跑 fresh-clone（按任务要求，第 1 阶段不跑）。
- 用 `scan-history.sh` 对主仓库实跑了一次（只读），历史扫描结果：检查 A、B 均为 PASS。
- 设计核对发现 **10 处问题**（D1–D10），其中 **3 处会让服务端仓库的测试直接失败**（D1、D2、D3）；**6 项需要协调者拍板**（Q1–Q6）。
- 没有改主仓库任何文件、没有运行 `task.py` / `/trellis-*` / `npm install` / `flutter`，没有 push，没有建 remote。对主仓库只有读操作，另外写了本报告。

## 1. 交付物

| 文件 | 说明 |
|---|---|
| `D:\MyNewProjects\_scratch\repo-split-pi4\scan-history.sh` | `scan-history.sh <仓库目录>`：对全部提交做 pi-1 第 4 步的两项扫描 + 隐私提示 |
| `D:\MyNewProjects\_scratch\repo-split-pi4\fresh-clone-test.sh` | `fresh-clone-test.sh <仓库目录> <main\|server>`：全新克隆后跑完整检查 |

两个脚本都是只读源仓库：`scan-history.sh` 只用 `git grep` / `git log` / `git rev-list` / `git for-each-ref`；`fresh-clone-test.sh` 只做 `git clone`（`--no-hardlinks`），所有安装和测试都在克隆目录里。

### 1.1 `scan-history.sh`

- 检查 A（会失败）：私钥头、`gh[pousr]_…`、`sk-ant-…`、`AKIA…`、明文 `storePassword` / `keyPassword`。命令形式与 implement.md 第 1 阶段 pi-1 第 4 步一字不差，只是把修订号按 100 个一批喂给 `git grep`，避免参数列表过长。
- 检查 B（会失败）：`git log --all --name-only` 里出现 `.signing/`、`*.p12/.p7b/.cer/.csr/.pfx/.jks`、`*.cjs`。
- 检查 C（只提示，不影响退出码）：全部提交里出现 `lichengyu`、`C:\Users`、`D:\` 的文件，按 `[路径]` / `[内容]` 分类，内容命中最多列 40 个并注明总数。
- 空仓库（还没有提交）时 A、B 记 PASS 并提示，退出码 0；扫描本身出错（`git grep` 退出码 > 1）记 FAIL。
- 退出码：0 = A、B 干净；1 = 有命中；2 = 参数错误。

### 1.2 `fresh-clone-test.sh`

- 克隆到 `${FRESH_BASE:-/d/MyNewProjects/_scratch}/fresh-$(date +%Y%m%d-%H%M%S)`，打印克隆的 HEAD 和提交标题，便于回溯"这批结果对应哪个提交"。
- 克隆后先做一次「不该提交的文件」检查（对应 implement.md 第 0 节第 4 条）：`.signing/`、`*.p12/.p7b/.cer/.csr/.pfx/.jks`、`server/**/*.cjs`、`ohos/build-profile.json5` 里的 `storePassword`/`keyPassword` 字段。命中即失败。这一项不是任务书要求的，是我加的，理由是它正好验证第 2 阶段"提交里没有签名材料"的结论；不需要的话删掉 `check_forbidden` 的调用即可。
- `server` 模式：`npm ci && npm run check && npm test`。
- `main` 模式：先 `server/` 的 `npm ci && npm run check && npm test`，再仓库根和 `apps/cloudterminal_windows` 各跑一遍 `flutter pub get && flutter analyze && flutter test`。
- 每条命令失败时打印失败的目录和命令（不只会输出一句 `set -e` 退出）。
- `KEEP=0` 跑完删除克隆，默认保留并打印路径。
- `main` 模式在开始前打印提醒："会连跑两次 flutter，确认没有别的 pi 在跑"。脚本**无法自动检测**别的 pi 是否在跑 flutter，只能靠人。

## 2. 关键命令和结果

### 2.1 语法检查（任务要求）

```
$ bash -n scan-history.sh
rc=0
$ bash -n fresh-clone-test.sh
rc=0
```

### 2.2 逻辑自测（用临时小仓库，不碰两个真仓库）

临时仓库建在 `_scratch/repo-split-pi4/_selftest/`，测完已删除。

- 干净仓库（1 个提交，只有 `a.txt`）：`PASS`，退出码 0。
- 脏仓库（`.signing/k.p12` + `ghp_` 令牌 + `C:\Users\lichengyu` 路径）：
  ```
  == 检查 A: 私钥/令牌/口令明文
  FAIL 命中 1 行（列出前 40 行）:
      <sha>:leak.ts:1:const k = "ghp_<自测用的假令牌，提交前已打码>";
  == 检查 B: 历史中的签名材料 / *.cjs
  FAIL 命中的路径:
      .signing/k.p12
  == 检查 C: 隐私提示（仅提示，不影响退出码）
  INFO 命中（路径命中 0 行，内容命中 1 个文件；内容命中最多列 40 个）:
      [内容] path.txt
  == 结论: FAIL   (退出码 1)
  ```
- 历史场景（先提交一个写有假签名口令的 storePassword 字段，再删掉该文件、提交一次）：仍然命中旧提交里的那一行，说明扫的是全部 `rev-list --all` 而不是工作区。

`fresh-clone-test.sh` 用 `PATH` 里塞了一个假 `npm`（只回显参数）+ 临时小仓库跑了完整流程：
- 干净源仓库 → 克隆、内容检查、`npm ci`/`npm run check`/`npm test`（假 npm）全过 → `PASS`，`KEEP=0` 后克隆目录已删除。
- 源仓库多提交一个 `server/ansi.cjs` → 内容检查报 `FAIL 克隆里存在本机调试脚本: server/ansi.cjs`，退出码 1。

### 2.3 对主仓库实跑 `scan-history.sh`（只读）

```
$ time bash scan-history.sh /d/MyNewProjects/cloudterminal
== 仓库: /d/MyNewProjects/cloudterminal
== 分支/引用: codex/general-terminal main
== HEAD: 927fc25
== 提交数: 21
== 远端:  (无)

== 检查 A: 私钥/令牌/口令明文
PASS 无命中
== 检查 B: 历史中的签名材料 / *.cjs
PASS 无命中
== 检查 C: 隐私提示（仅提示，不影响退出码）
INFO 命中（路径命中 2 行，内容命中 26 个文件；内容命中最多列 40 个）:
    [路径] .trellis/workspace/lichengyu/index.md
    [路径] .trellis/workspace/lichengyu/journal-1.md
    [内容] .trellis/tasks/*/task.json（15 个）
    [内容] .trellis/tasks/10-12-herdr-mobile/research/herdr-cli-0.9.3.md
    [内容] .trellis/workspace/lichengyu/index.md
    [内容] .trellis/workspace/lichengyu/journal-1.md
    [内容] server/test/herdr-live.test.ts
    [内容] server/test/herdr.test.ts
    [内容] test/herdr_direct_input_test.dart
    [内容] test/herdr_reflow_test.dart
== 结论: PASS
real  0m5.171s
rc=0
```

说明：
- 扫描时 HEAD 是 `927fc25`，**和本次会话开头看到的 `792ff8e` 不一样**，说明 pi-1 正在并行提交。我做的所有代码核对都是对当前工作区（不是某个固定提交）做的，结论里带行号，行号可能随 pi-1 的提交有轻微漂移。
- 检查 C 的 26 个内容命中里，除了 `.trellis/` 的 15 个 `task.json` 和 2 个 workspace 文件，就是 4 个测试文件（`server/test/herdr{,-live}.test.ts`、`test/herdr_{direct_input,reflow}_test.dart`）里有 `C:\Users` 或 `D:\` 的绝对路径。只是提示，不影响结论。
- 主仓库当前**没有任何 remote**（`git remote -v` 为空）。第 3 阶段推送前需要先 `git remote add`，这属于协调者/用户的工作，我没有做。

## 3. node-pty：全新 clone 后在 Windows 上 `npm ci` 需不需要 Visual Studio

**不需要。**

证据：

1. `server/node_modules/node-pty/package.json` 的 install 脚本是 `node scripts/prebuild.js || node-gyp rebuild`。
2. `node_modules/node-pty/scripts/prebuild.js` 做的事只有一件：检查 `prebuilds/<platform>-<arch>` 目录是否存在，存在就 `process.exit(0)`，**不联网、不编译**。只有目录不存在（或设置了 `npm_config_build_from_source=true`）才回落到 `node-gyp rebuild`。
3. 这个目录确实随 npm 包发布：`node-pty/package.json` 的 `files` 里有 `"prebuilds/"`，本机 `server/node_modules/node-pty/prebuilds/win32-x64/` 下有 `pty.node`、`conpty.node`、`conpty_console_list.node`、`winpty.dll`、`winpty-agent.exe`、`conpty/{conpty.dll,OpenConsole.exe}`。
4. 本机就是靠 prebuild 装的：`node_modules/node-pty/build/` 下**一个 `.node` 文件都没有**（`Get-ChildItem -Recurse -Filter *.node` 计数 0），只有 `build/Release/conpty/{conpty.dll,OpenConsole.exe}`（`post-install.js` 从 prebuilds 拷过去的）。如果当初走了 `node-gyp rebuild`，`build/Release/pty.node` 一定存在。

本机是 Node v24.15.0 / win32-x64，node-pty 1.1.0 用的是 `node-addon-api`（NAPI），所以预编译产物与 Node 大版本无关。

结论：第 2 阶段在全新克隆里 `npm ci` 不需要 Visual Studio / windows-build-tools，`prebuilds/win32-x64` 覆盖本平台。（若换 arm64 机器，`prebuilds/win32-arm64` 也在，同样不需要编译。）

## 4. 设计核对（只读，逐条对真实代码）

### D1（阻塞）§4 要搬的区段引用了区段外的类型：`ClientMessage` / `AgentMessage`

`server/src/shared/protocol.ts`：

- 第 59–77 行 `RelayFrame` 里，第 74 行 `| { t: 'msg'; clientId: string; data: ClientMessage }`、第 76 行 `| { t: 'msg'; data: AgentMessage; to?: string }`。
- 而 `ClientMessage` 定义在第 347 行、`AgentMessage` 在第 387 行，都在区段之外。

后果：
- 若 `relay-protocol.ts` 写 `import type { ClientMessage, AgentMessage } from './protocol.ts'`，主仓库里就是 `protocol.ts → relay-protocol.ts → protocol.ts` 的循环（仅类型，运行时无害，TS 能过）；**但服务端仓库没有 `protocol.ts`**，`tsc --noEmit` 会直接报 "Cannot find module './protocol.ts'"。design §4 说"服务端仓库只有 relay-protocol.ts，没有完整的 protocol.ts"，与它自己要求的"两仓库同名副本逐字节一致"（§3 一致性检查）冲突。
- 好消息：`RelayFrame` 目前**全仓库没有任何使用点**（grep 只命中定义处 `protocol.ts:59`），Dart 侧也没有镜像（`lib/`、`test/` 下 grep `RelayFrame` 无结果）。

建议（推荐 a）：
- a) `relay-protocol.ts` 里把两处 `data` 的类型改成 `unknown`（relay 从不解析 payload，只是转发），两仓库副本保持一致，哈希检查照旧；主仓库 `protocol.ts` 用 `export * from './relay-protocol.ts'` 后 `RelayFrame` 自动从那边来，语义上只是变宽，没有使用者受影响。
- b) 干脆不搬 `RelayFrame`（它是死代码，可从 `protocol.ts` 删掉）；但这样"移动了什么"就和 design §4 的清单不一致，需要同步改 design。
- c) 在服务端仓库再造一份精简 `protocol.ts` 只放这两个类型 —— 会打破"5 个副本文件全等"的前提。

### D2（阻塞）§5 改默认镜像地址会和 `deployment-image.test.ts:365` 直接冲突

`server/test/deployment-image.test.ts:360-367`：

```
362: assert.match(readme, /当前没有任何已发布的镜像/, ...);
363: assert.match(readme, /首次 CI 发布成功之前/, ...);
364: assert.match(readme, /RELAY_IMAGE/, ...);
365: assert.match(readme, /docker\.cnb\.cool\/azurekiln\/cloudterminal/, 'README must name the default image path');
366: assert.match(readme, /ghcr\.io\/<owner>\/<repo>/, 'README must describe the GitHub image path');
```

- design §5 要求把 `compose.yml:16`、`compose.tls.yml:12`、`.env.example:21`、"README" 里的默认 `RELAY_IMAGE` 改成 `ghcr.io/azurekiln2333/cloudterminal-relay-server:latest`（现为 `docker.cnb.cool/azurekiln/cloudterminal:latest`）。
- 改完之后 README 里如果不再出现 `docker.cnb.cool/azurekiln/cloudterminal`（README.md:15、29、161 三处），第 365 行断言会失败；第 366 行要求**字面**保留 `ghcr.io/<owner>/<repo>` 占位写法（现在在 README.md:16），改成真实 owner 也会让它失败。pi-2 的指令只说"改默认镜像地址"，没说这两条断言怎么办。
- 另外第 370 行（`.env.example` 必须有 `WARNING: nothing is published at the default path yet`）、第 375 行（`compose.yml` 必须有 `exists there yet`）也要一起保住，否则一样失败。

建议：design/指令里补一句 —— 改默认地址的同时，(1) 保留 `ghcr.io/<owner>/<repo>` 这行占位说明（作为"自己 fork 时"的写法），(2) 把第 365 行的断言改成匹配新的默认地址 `ghcr\.io\/azurekiln2333\/cloudterminal-relay-server`，(3) 三处"未发布"文案原样保留。

### D3（阻塞）§6 漏了 `TUNNEL.md`，服务端仓库会有 3 个用例失败

`deployment-image.test.ts` 有 3 处 `read('TUNNEL.md')`：第 137、377、384 行（"TUNNEL.md must not build by default"、"TUNNEL.md must mention the image override"、"README/TUNNEL.md 都不得声称镜像已发布"）。而 design §1 的服务端仓库清单、pi-2 的复制清单都**没有** `TUNNEL.md`（pi-3 的指令反而说"改好的 `server/TUNNEL.md`，把链接改到服务端仓库"，也就是它留在主仓库）。

后果：`deployment-image.test.ts` 搬到服务端仓库后，`read('TUNNEL.md')` 直接 ENOENT，部署契约测试整组失败（而 CI 的 `deployment-files` job 就是跑这个文件，等于 CI 红）。

建议：把 `TUNNEL.md` 也复制到服务端仓库（它是中继部署文档，天然属于服务端仓库），主仓库的 `server/TUNNEL.md` 改成一段短说明 + 指向服务端仓库的链接；或者删除这 3 处 TUNNEL 断言并同步改 design。推荐前者。

### D4 §6 把 `helpers.ts` 写成服务端仓库专属，实际两仓库都要

`server/test/helpers.ts` 只有 `startRelay` + `TestSocket`（第 4 行 import `createRelay`）。

- 主仓库留下的测试里，`deployment.test.ts:12`、`desktop-terminal.test.ts`、`link.test.ts:10`、`relay.test.ts:6`、`setup-cli.test.ts:9` 都 import `./helpers.ts`，所以主仓库必须保留一份。
- 服务端仓库的 `relay.test.ts`、`relay-api.test.ts`、`relay-tenancy.test.ts` 也要它。
- §2 说"主仓库的版本去掉 db"——**目前 helpers.ts 里根本没有 db 相关代码**（只有 `createRelay(opts)` 转发），所以这句是空操作，主仓库那份**不用改**；真正要改的只有服务端那份：接受 `{ db, bindingCacheMs }`，内部 `createTenancy({ pool: db ?? null, bindingCacheMs })` 再传给 `createRelay({ accounts })`（`relay-tenancy.test.ts` 第 32/82/108/130/151/174/196/234 行都靠这个签名）。

建议：§6 里 `helpers.ts` 改成"两个仓库各一份，内容不同（服务端版多一层 db→tenancy 组装）"；pi-3 的"去掉 db"改成"主仓库 helpers.ts 不动"。

### D5 §5 的目录推算其实只需改一行

`deployment-image.test.ts:21-22`：

```ts
const serverDir = path.resolve(import.meta.dirname, '..');   // test/ → server/
const repoDir = path.resolve(serverDir, '..');               // server/ → 仓库根
```

搬到服务端仓库后，`test/` 直接在仓库根，所以第 21 行算出来**已经是仓库根**（正确）；只有第 22 行的 `repoDir` 会跑到仓库根的上一级（错误）。`readRepo` 读的是 `.github/workflows/image.yml`（第 207 行）和 `.cnb.yml`（第 254 行），这两个文件在新仓库的根目录。

建议：只把第 22 行改成 `const repoDir = serverDir;`（或直接把 `readRepo` 删掉改用 `read`）。design 写"21-22 行的目录推算也跟着改"容易让人把两行都改坏。

### D6 §4 pi-2 第 3 步"把各测试里对 protocol.ts 的 import 都改成从它导入"没有目标

要搬去服务端仓库的测试是 `relay`、`relay-api`、`relay-tenancy`、`db-*`、`oauth-*`、`deployment-image`。对 `../src/shared/protocol.ts` 的 import 只有 4 个测试文件：`core.test.ts:8`、`herdr.test.ts:36`、`link.test.ts:11`、`terminal.test.ts:7`，**全部留在主仓库**。要搬走的文件里只有 `src/relay/relay.ts:7-14` 需要改成 `../shared/relay-protocol.ts`。

建议：把 pi-2 第 3 步改成"只改 `relay.ts`"，避免它去改主仓库的测试或误以为漏了什么。

### D7 §2 会造出两份同名类型

`tenancy.ts:24-34` 已经定义了 `AccountClientAuth` / `AccountClientDenied` / `AccountClientResult`（结构就是 design §2 里 `AccountClientResult` 的等价物）。design §2 又要求在 `relay.ts` 里定义一遍，`tenancy.ts` 改成 `import type { AccountClientResult } from './relay.ts'` —— 那 `tenancy.ts` 里原来的三个类型必须删掉，否则同一模块名出现两份（tsc 会报重复声明吗？不会，因为不同文件，但两处定义容易漂移）。

建议：design 补一句"`tenancy.ts` 删掉 `AccountClientAuth/Denied/Result` 三个类型，改为从 `relay.ts` 导入"。`Tenancy` 类型本身继续留在 `tenancy.ts`（`boundAccounts`、`stats` 服务端仓库还要用）。

### D8 §2 的行为核对：一致，可以照做

- `relay.ts` 里 `db` 只出现在第 18、39、87 行（`import type DbPool`、`RelayOptions.db`、`createTenancy({ pool: opts.db ?? null })`），删干净没有连带影响。
- 现在 `db=null` 时 `tenancy.available === false`（`tenancy.ts:85-87`：`opts.pool !== null && !opts.pool.closed`），`relay.ts:337-340` 记 `log.warn('account client rejected: tenancy unavailable', …)` 并回 `account_unavailable`；design §2 的内置"未启用"实现给出的正是同一结果。其余错误码映射（`unavailable`→`account_unavailable`、其它→`unauthorized`）在 `relay.ts:345-353`，不受改动影响。
- `bindingCacheMs` 的默认值 30 000 在 `tenancy.ts:48`，`main.ts:56` 从来没传过它，所以"把 `bindingCacheMs` 从 `RelayOptions` 移到 `createTenancy`"后线上行为不变。
- agent 侧只调用 `createRelay({ logger, relayKey })`（`src/agent/main.ts:164`、`src/agent/sidecar.ts:83`、`scripts/demo-agent.ts:105`），删 `db`/`bindingCacheMs` 不影响 agent。

### D9 `herdr.test.ts:970` 的 fixture 在全新克隆上**本来就会失败**（与拆分无关）

```
970:  const dir = path.resolve('..', '.build', 'pi-herdr', 'herdr-probe');
```

`.build/` 被 `.gitignore:8` 忽略，`git ls-files .build` 为空（0 个跟踪文件），本机只是因为 `.build/pi-herdr/herdr-probe/` 恰好存在（11 个文件，约 361 KB）才通过。任何全新克隆跑 `npm test` 都会在这个用例上 ENOENT —— 这是拆分之前就存在的问题，pi-3 的"目录不存在时跳过并写明原因"是正确且必要的。

建议：跳过理由写成"录制的 live probe 放在 `.build/`，该目录被 .gitignore 忽略，因此全新克隆里不存在；本机开发机有它时才会跑"，不要写成"拆分导致的临时跳过"。另外可以考虑把这 11 个文件（361 KB）纳入仓库（比如 `test/fixtures/herdr-probe/`），那这个用例就谁跑都过；这超出本任务范围，交给协调者定。

### D10 §1/§3 把 `protocol-account.ts` 列为"副本"，但 agent 侧并不使用

`grep -r protocol-account server/src server/scripts server/test` 只有 `src/relay/relay.ts:15` 一处。它不是"agent 与 relay 共用"，只是 relay 自己的扩展帧类型。放进副本清单无害（服务端仓库确实要用它），但 design §3 的动机描述（"agent 通过副本共享"）对这一个文件不成立；`relay-protocol.ts` 里的 `Hello`/`RelayErrorCode` 才是 agent 与 relay 共用的那部分。建议顺手把 §3 的描述改准确。

### CI 里其余的 `server/` 路径（§5 的核对结果）

`grep -n "server/" .github/workflows/image.yml .cnb.yml` 命中 5 处代码 + 1 处注释，全部在 pi-2 的改法覆盖范围内：

| 位置 | 内容 | 处理 |
|---|---|---|
| `image.yml:58` | `node --test server/test/deployment-image.test.ts` | 去掉 `server/` |
| `image.yml:127` | `context: ./server` | 改成 `context: .` |
| `image.yml:128` | `file: ./server/Dockerfile` | 改成 `file: ./Dockerfile` |
| `.cnb.yml:38` | `node --test server/test/deployment-image.test.ts` | 去掉 `server/` |
| `.cnb.yml:42` | `docker build -t cloudterminal-ci:build server/` | 改成 `.` |
| `.cnb.yml:12` | 注释 `# server/test/deployment-image.test.ts` | 同步改（不影响构建，但留着会误导） |

另外确认：

- `image.yml:175`、`.cnb.yml:73` 的 `node src/relay/show-key.ts` 是**容器内**路径，没有 `server/` 前缀，**不要**去加/去改。
- `image.yml` 没有 `paths:` 过滤，所以这个 workflow 搬走之后主仓库不会有残留触发。
- `deployment-image.test.ts:151` 用 `path.join(serverDir, 'src/relay/main.ts')` 走真实 import 图，搬到新仓库后等价，不用改。
- 主仓库里除 `.build/`（未跟踪、gitignored）之外，没有别的文件引用 `server/` 前缀：`start.cmd:3`、`start.sh:3` 只是 `cd` 进 `server/` 启动 agent，行为不变。

## 5. 和 design.md 不一致的地方（汇总）

| # | design 位置 | design 写的 | 实际代码 |
|---|---|---|---|
| D1 | §4 | 区段外引用"例如 PROTOCOL_VERSION"，若有就一起移 | 真正的区段外引用是 `ClientMessage`/`AgentMessage`（`protocol.ts:74,76`），且不能一起移（它们是 agent 协议主体） |
| D2 | §5 | 改默认镜像地址 | `deployment-image.test.ts:365/366` 会因此失败，design 未提 |
| D3 | §1/§6 | 服务端仓库文件清单 | 漏了 `TUNNEL.md`，而 `deployment-image.test.ts` 依赖它 |
| D4 | §2/§6 | `helpers.ts` 属于服务端仓库；主仓库版"去掉 db" | 主仓库多个测试依赖 helpers.ts；当前 helpers.ts 没有 db 代码，无需改 |
| D5 | §5 | 改 `deployment-image.test.ts:21-22` 的目录推算 | 只需改第 22 行 |
| D6 | §4 | 各测试改 import | 要搬的测试没有 import `protocol.ts`，只有 `relay.ts` 要改 |
| D7 | §2 | `relay.ts` 定义 `AccountClientResult` | `tenancy.ts:24-34` 已有同名类型，要一并删掉 |
| D10 | §3 | 副本清单的动机 | `protocol-account.ts` 只被 `relay.ts` 使用，不是 agent/relay 共用 |

## 6. 需要协调者决定（不要由我猜）

- **Q1（D1）**：`relay-protocol.ts` 里 `RelayFrame` 的 `data` 用 `unknown`（推荐），还是干脆删掉 `RelayFrame`，还是另造服务端专属 `protocol.ts`？
- **Q2（D2）**：README 里 `docker.cnb.cool/azurekiln/cloudterminal` 与字面 `ghcr.io/<owner>/<repo>` 这两行是保留、还是连断言一起改？改默认镜像地址的同时必须给 pi-2 的指令补上这一条，否则服务端 CI 必红。
- **Q3（D3）**：`TUNNEL.md` 复制到服务端仓库（推荐，主仓库留短说明 + 链接），还是删掉那 3 处 TUNNEL 断言？
- **Q4（D4）**：`helpers.ts` 两仓库各一份（内容不同）——确认这个理解，并据此改§6 和 pi-3 的指令（主仓库那份不动）。
- **Q5（D7）**：`tenancy.ts` 里那三个类型删掉、改从 `relay.ts` 导入，确认这样做？
- **Q6（D9）**：`herdr.test.ts:970` 的 fixture 只跳过就行（推荐，pi-3 已经这么写），还是顺手把 361 KB 的 11 个文件纳入仓库让这个用例在克隆里也能跑？

另外提醒协调者两件不属于我职责范围的事：
- 主仓库**没有配置 remote**，第 3 阶段推送前需要用户/协调者决定远端地址。
- 我核对时主仓库 HEAD 在动（`792ff8e` → `927fc25`），说明 pi-1 在并行提交；本报告里的所有行号基于 2026-11-09 22:00 左右的工作区。

## 7. 第 2 阶段我会怎么用这两个脚本（预告）

1. 两个仓库都提交完之后，各跑一次：
   - `bash scan-history.sh /d/MyNewProjects/cloudterminal`
   - `bash scan-history.sh /d/MyNewProjects/cloudterminal-relay-server`
   预期：A、B 都 PASS；C 只在主仓库有输出（`.trellis/` 里的用户名 + 4 个测试文件里的绝对路径），只作提示。
2. `bash fresh-clone-test.sh /d/MyNewProjects/cloudterminal-relay-server server`
   —— 覆盖服务端仓库"全新克隆 → `npm ci` → `tsc` → 测试"的完整路径，顺带验证第 2 阶段的提交里没有 `.signing/`、`*.cjs`。
3. `bash fresh-clone-test.sh /d/MyNewProjects/cloudterminal main`
   —— 只在确认没有别的 pi 在跑 flutter 时执行；它会先跑 `server/` 的 npm 检查，再跑两次 flutter。
4. 一致性检查的"故意改坏 → 确认失败 → 还原"：按 pi-4 第 2 阶段的指令，在服务端仓库工作区改一个副本文件后跑 `node --test server/test/relay-core-sync.test.ts`（或 `npm run sync-relay -- --check`），确认退出码非 0，再用 `git -C` 恢复到 HEAD 的内容（**不**用 `git checkout --`/`restore`，按第 0 节规则：直接 `git -C <dir> show HEAD:<file> > <file>` 写回，避免触发禁止命令）。
