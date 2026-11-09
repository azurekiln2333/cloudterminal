# pi-1 第 2 阶段（2c）报告

## 结论

**完成（1 处判据需要协调者确认）。** 第 1–5 步全部执行，只读，没有改任何文件、没有改 git 状态、没有跑 flutter、没有 push、没有跑 task.py。

- 第 1 步（删除集合 vs `delete-list.txt`）：**完全一致**，44 = 44，无遗漏、无多余、无 rename。
- 第 2 步（5 个副本哈希）：**完全一致**，主仓库 HEAD blob = 服务端仓库 HEAD blob = `server/relay-core.json` 记录值。
- 第 3 步（`git grep`）：命令不是"零输出"——有 **2 处非代码命中**（一条服务端仓库里的容器命令、一条注释），**零个 import**。见下文第 3 节，需要协调者确认判据。
- 第 4 步（`npm run check && npm test`）：**全绿**，`tests 168 / pass 168 / fail 0`。
- 第 5 步：本报告。

执行完毕后两个仓库都是干净的：

```
主仓库      git status --short  →  ?? .trellis/tasks/11-09-repo-split/
主仓库      git remote -v       →  （空）
服务端仓库  git status --short  →  （空）
服务端仓库  git remote -v       →  （空）
```

## 环境说明

本机是 PowerShell，没有 bash（第 1 阶段已确认 `C:\Program Files\Git\bin\bash.exe` 不存在、WSL 不可用），所以 implement.md 里的 `grep` / `$(...)` 都用等价写法执行：`git grep -nE` 原生支持；集合比对用 PowerShell 的 `Compare-Object`；哈希用 `node -e`（与 design §3 的参考命令同一套换行归一逻辑，额外把 `process.argv` 改成脚本内常量）。

## 第 1 步：删除路径 vs `delete-list.txt`

`git show --stat` 摘要：

```
b1d30e1 test(agent): skip recorded herdr probes when the fixtures are absent
        1 file changed, 11 insertions(+), 1 deletion(-)          ← 只有 server/test/herdr.test.ts

2cd0ec5 refactor(server)!: move the public relay to cloudterminal-relay-server
        54 files changed（含 44 个 D）
beed231 docs: point relay deployment at the server repo
        7 files changed, 26 insertions(+), 35 deletions(-)       ← README.md、server/TUNNEL.md、5 个 spec
```

三个提交合计改动 62 个路径（含删除）。删除按提交分布：

| 提交 | 删除数 |
|---|---|
| `b1d30e1` | 0 |
| `2cd0ec5` | **44** |
| `beed231` | 0 |

比对方法：从 `D:\MyNewProjects\_scratch\repo-split-pi3\delete-list.txt` 读出去重后的期望集合——跳过注释行（`#`）和 7 条"不要删除"兜底行；`server/deploy/` 这行按 `927fc25` 时该目录下的实际跟踪文件展开为 `server/deploy/Caddyfile`、`server/deploy/relay/package.json`、`server/deploy/relay/package-lock.json`。实际集合同样展开后取 `git diff --name-status 927fc25..HEAD --diff-filter=D`。

```
expected=44 actual=44
--- 清单里但没删 ---        （无）
--- 删了但不在清单 ---      （无）
```

补充：

- `git diff --name-status 927fc25..HEAD --diff-filter=R` 无输出（没有 rename 冒充删除）。
- 7 条"不要删除"兜底行在 HEAD 里全部仍存在（`server/src/shared/protocol.ts`、`protocol-account.ts`、`server/src/relay/relay.ts`、`server/test/helpers.ts`、`server/test/relay.test.ts`、`server/TUNNEL.md`、`server/scripts/tunnel-relay.ps1` 一律 `Test-Path = True`）。
- 44 条实际删除明细（`2cd0ec5`）：`.cnb.yml`、`.github/workflows/image.yml`、`server/{.dockerignore,.env.example,Dockerfile,README.md,compose.yml,compose.tls.yml,compose.build.yml}`、`server/deploy/{Caddyfile,relay/package.json,relay/package-lock.json}`、`server/src/relay/{api,tenancy,key,show-key,main}.ts`、`server/src/db/*`（8 个）、`server/src/oauth/*`（6 个）、`server/test/{db-bindings,db-config,db-migrate,db-tokens,db-helpers,fake-db,oauth-config,oauth-discovery,oauth-flows,oauth-verify,relay-api,relay-tenancy,deployment-image}`。

**结论：与 `delete-list.txt` 完全一致。**

## 第 2 步：5 个副本文件哈希

同时查了三个来源：两边的 **HEAD blob**（不是工作区文件，避免 CRLF/编辑器干扰）、`server/relay-core.json` 的记录。

| 文件 | 主仓库 HEAD blob（`server/…`） | 服务端仓库 HEAD blob（`src/…`） |
|---|---|---|
| `src/relay/relay.ts` | `c204a785e7f9dbbb…a8125ae6` | `c204a785e7f9dbbb…a8125ae6` |
| `src/shared/relay-protocol.ts` | `7ed809a73b8b933f…9eba881` | `7ed809a73b8b933f…9eba881` |
| `src/shared/protocol-account.ts` | `6c93328d72e5c7de…6a67aad5` | `6c93328d72e5c7de…6a67aad5` |
| `src/shared/crypto.ts` | `92228b0c03df673e…1c6656700` | `92228b0c03df673e…1c6656700` |
| `src/shared/log.ts` | `43b235df066dc07c…96af0952` | `43b235df066dc07c…96af0952` |

完整值（两边逐行相同）：

```
c204a785e7f9dbbbed6d3046fb8d52d966bbb9d46fd47ec20cc0491ca8125ae6  relay.ts
7ed809a73b8b933f7aac49bd3de139838de110a7ad095d218ebcafa629eba881  relay-protocol.ts
6c93328d72e5c7deba01a04f52523fcad664baed5d58f2e29465f3ff6a67aad5  protocol-account.ts
92228b0c03df673ef972591fb3fe99aaad93a468e09a3a7966fdacf1c6656700  crypto.ts
43b235df066dc07cb27e734f1085a7f766ff09020eaaa7ee5982252496af0952  log.ts
```

`server/relay-core.json`：

```json
{ "source": "https://github.com/azurekiln2333/cloudterminal-relay-server",
  "commit": "fcd073d04e183c24ac7236d388099ff0cf27d714",
  "files": { …同上 5 个哈希… } }
```

服务端仓库当前 HEAD 是 `fcd073d feat: initial relay server (split from cloudterminal@927fc25)`，与 `relay-core.json` 里记录的 commit 一致（pi-2 的 2a amend 已完成，提交说明里的来源号是 `927fc25`，正确）。工作区文件哈希（CRLF→LF 后）也与上表相同。

**结论：5 个副本一致，校验文件可信，`sync-relay --check` 的数据基础成立。**

## 第 3 步：遗留引用检查

implement.md 的原命令：

```
$ git grep -nE "from '\.\./(db|oauth)/|relay/(api|tenancy|key|show-key|main)\.ts" -- server
server/TUNNEL.md:57:   docker compose -f compose.tls.yml exec relay node src/relay/show-key.ts
server/test/setup.test.ts:10:// `relay-key.test.ts` together with `src/relay/key.ts`.
```

**命中 2 处，"应该没有输出"没有满足。** 但两处都不是代码引用：

1. `server/TUNNEL.md:57` —— 一条在**服务端仓库的容器里**执行的运维命令（`docker compose … exec relay node src/relay/show-key.ts`），`src/relay/show-key.ts` 现在确实只存在于服务端仓库，命令行本身正确。
2. `server/test/setup.test.ts:10` —— 注释，说明 key 用例已随 `src/relay/key.ts` 搬到 `relay-key.test.ts`。

为确认"检查的真实意图（没有残留 import）"，另跑了几条更精确的：

| 检查 | 命令 | 结果 |
|---|---|---|
| A：`src`/`test` 里所有 import/require 中出现 `db/`、`oauth/`、`relay/` | `git grep -nE "(from\|require\(\|import\().*(db/\|oauth/\|relay/)" -- server/src server/test` | 6 处，**全部是 `../relay/relay.ts`**（`agent/main.ts:13`、`agent/sidecar.ts:18`、`test/helpers.ts:4`、`link.test.ts:10`、`relay-sidecar.test.ts:11`、`relay.test.ts:5`）——即保留下来的中继核心副本，符合 design §1 |
| B：任何 `../db/` 或 `../oauth/` 引用 | `git grep -nE '\.\./(db\|oauth)/' -- server` | **0** |
| C：对已移走模块的相对导入 | `git grep -nE "['\"]\./(api\|tenancy\|key\|show-key\|main)(\.ts)?['\"]" -- server/src server/test` | **0** |
| D：`tenancy`/`show-key`/`AccountAuthorizer` 任何出现 | `git grep -nE 'tenancy\|show-key\|AccountAuthorizer' -- server/src server/test` | 6 处，全是 `relay.ts` 里的接口定义与注释、`deployment.test.ts:13` 的注释；无 import |

顺带核对 design §2：`server/src/relay/relay.ts` 头部只 import `../shared/{crypto,log,relay-protocol,protocol-account}.ts`，**没有** `tenancy` / `db`；`AccountAuthorizer` / `AccountClientResult` 定义在文件内，`unavailableAccounts` 兜底实现存在。解耦落实了。

**结论：无残留代码引用；2 处文本命中是否算"通过"，请看"需要协调者决定"第 1 条。**

## 第 4 步：主仓库 `server` 检查

```
$ cd server && npm run check
> cloudterminal-server@0.1.0 check
> tsc --noEmit
（无输出）                                exit=0

$ cd server && npm test
ℹ tests 168
ℹ suites 29
ℹ pass 168
ℹ fail 0
ℹ cancelled 0
ℹ skipped 0
ℹ todo 0
ℹ duration_ms 75593.4686
                                          exit=0
```

与 pi-3 报告里的数字完全一致（`tests 168 / suites 29 / pass 168 / fail 0`）。`skipped 0` 是因为本机 `.build/pi-herdr/herdr-probe` 存在，`herdr.test.ts` 那条 fixture 用例照常执行——fresh clone 才会跳过，这与 pi-3 的说明一致，不算问题。

跑完后 `git status --short` 仍是 `?? .trellis/tasks/11-09-repo-split/`，测试没有留下任何被跟踪的改动。

## 和 implement.md / design.md 不一致的地方

1. **第 3 步的判据没满足（2 处命中）**，但都不是 import。pi-3 已在 `reports/pi-3-phase2.md` 的"需要协调者决定"第 4 条预告过这件事，本次复核确认了它的判断：`TUNNEL.md:57` 指向服务端仓库，`setup.test.ts:10` 是说明性注释。我没有改文件（本阶段只读）。
2. **执行方式**：没有 bash，`grep`/进程替换用 `git grep` 与 PowerShell 等价物，语义相同（已在上文列出每条命令）。
3. 第 2 步我除了比工作区文件，还比了**提交里的 blob**，比 implement.md 要求更严格；结论相同。

## 需要协调者决定的事

1. **第 3 步判据要不要放宽为"零 import"**。按字面（零输出）→ 不通过；按意图（没有残留代码引用）→ 通过（`../db`、`../oauth`、已移走模块的相对导入都是 0）。要真正零输出，需要改 `server/TUNNEL.md:57` 的措辞和 `server/test/setup.test.ts:10` 的注释，这两处都没必要改，建议放宽。
2. **全仓范围（不加 `-- server`）还有 11 处命中**，其中 `.trellis/` 里的都是历史任务文档，不属于本阶段清理对象，但值得知道：
   - `.trellis/spec/backend/deployment.md:7`、`:18` —— pi-3 报告里说的"正文 4 处例外"中的两处（第 7 行同时写着 `server/src/relay/key.ts` 与 `server/Dockerfile`，都是已删或已搬走的东西）。
   - `.trellis/spec/backend/logging-guidelines.md:18` —— 已改成指向服务端仓库的写法，正则仍会命中字符串 `src/relay/main.ts`，属正常。
   - `.trellis/tasks/10-13-relay-multitenant/{design,implement}.md` 共 5 处（`relay/api.ts`、`relay/tenancy.ts`、`relay/main.ts`）——该任务把实现写在了主仓库，现在代码搬走了，任务文档里的路径已失效。要不要在 `10-13-relay-multitenant` 里补一句"代码已随拆仓移到服务端仓库"，请决定（我按规则没改）。
   - `server/TUNNEL.md:57`、`server/test/setup.test.ts:10` —— 见上。
3. **`deployment.md` 正文**（第 7 行同时引用 `server/src/relay/key.ts`、`server/Dockerfile`）与 pi-3 在开头加的段落有点自相矛盾：开头说这些已移到服务端仓库，正文仍按主仓库路径描述。这与 pi-3 报告"需要协调者决定"第 1 条是同一件事，仍未解决。
4. **`server/` 下的本机垃圾文件**（`server.zip`、`ansi.cjs`、`check-herdr.cjs`、`hold.cjs`）仍在磁盘上，被 `.git/info/exclude` 与 `.gitignore` 挡住，没有进任何提交。第 3 阶段推之前要不要清掉，请决定。
5. **主仓库仍无 remote**（`git remote -v` 为空），第 3 阶段推送前需要补。这和我在第 1 阶段报告里的提醒相同，目前没变。

## 附：本阶段产生的副作用

- 没有改任何文件、没有改 git 状态、没有新建临时文件（哈希用的临时脚本写在 `%TEMP%` 并已删除）。
- 跑了 `npm test`，会在 `server/` 下产生/复用 `.build/` 之类的测试临时目录（已被忽略，`git status` 未受影响）。
- 未运行 flutter、未运行 pi-4 的扫描脚本、未动服务端仓库。
