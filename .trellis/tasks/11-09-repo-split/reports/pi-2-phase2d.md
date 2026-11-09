# pi-2 第 2 阶段（2d）报告：服务端仓库小修（CRLF + 文案）

## 结论

**完成。** 服务端仓库新提交 **`841cc86`**（`fix: keep LF checkouts and CRLF-tolerant deployment checks`）。只改了服务端仓库，主仓库没碰（仍 `beed231`，`git status --short` 只有 `?? .trellis/tasks/11-09-repo-split/`）。没有 push，没有加 remote，没有运行 `task.py`。

`npm run check` 干净，`npm test` **119/119 通过**。

## 做了什么

对应 implement.md「2d · pi-2」第 1–6 步。

### 1. `.gitattributes`（第 1 步）

新建，内容只有一行：
```
* text=auto eol=lf
```

然后按要求跑 `git add --renormalize .`。

**一个执行细节需要说明**：`git add --renormalize .` **只对已跟踪文件生效**，不会暂存新建的 `.gitattributes`，所以第一次跑完 `git diff --cached --name-only` 是**空的**（`.gitattributes` 还是 `??`）。我只显式执行了 `git add -- .gitattributes`，再跑一次 `git add --renormalize .` 确认没有别的文件被重写。最终 `git diff --cached --name-only` = **只有 `.gitattributes`**，符合第 1 步的验收条件，没有多出别的文件。

原因也确认了：原目录的文件本来就是 `i/lf w/lf`（不是 CRLF），所以 renormalize 除了新文件之外没有任何要改写的。pi-4 的失败来自**克隆时的检出转换**（Git for Windows 的 `core.autocrlf=true`），`.gitattributes` 正好治这个。

### 2. CRLF 宽容（第 2 步）

改了 `test/deployment-image.test.ts` 两处**依赖字面 `\n` 的内容正则**：

| 行 | 改前 | 改后 |
| --- | --- | --- |
| 113（原 111） | `/^volumes:\n {2}relay-data:$/m` | `/^volumes:\r?\n {2}relay-data:$/m` |
| 346（原 344） | `/^ {4}environment:\n(?: {6}#.*\n)* {6}RELAY_TRUST_PROXY: "1"$/m` | `/^ {4}environment:\r?\n(?: {6}#.*\r?\n)* {6}RELAY_TRUST_PROXY: "1"$/m` |

第 113 行同时加了两行注释说明为什么用 `\r?\n`（`compose` 是原始文件文本，Windows 检出可能是 CRLF）。

**为什么只改这两处**（第 2 步说"其他对文件内容做匹配、却只认 `\n` 的正则也照样改"，我逐条核过同一文件里所有 `\n` 和 `$/m`）：

| 位置 | 形式 | 是否 CRLF 敏感 | 处理 |
| --- | --- | --- | --- |
| 35/48/63/135/141/384 | `split(/\r?\n/)` | 否（已经宽容） | 不动 |
| 43/65 | `join('\n')` | 否（入参已按 `\r?\n` 切过，输出统一 LF） | 不动 |
| 71/75/225 | `` `\n  ${event}:` ``、`/\n {2}[a-z_]+:/`、`indexOf('\n      - name:')` | 否 | 不动 |
| 113（原 111） | 正则里字面 `\n`，输入是**原始文件文本** | **是 —— 实测唯一失败点** | 已改 |
| 205 | `/HEALTHCHECK[^\n]*\n?[^\n]*\/healthz/` | 否（`[^\n]` 能吃 `\r`） | 不动 |
| 346（原 344） | 正则里字面 `\n` | 原则上敏感（输入经 `serviceBlock` 归一化，实际不会触发） | 已改（防御性） |
| 90/99/109/110/129/130/131/201/212/213/335/336/337/395 | `^…$/m` | **否** | 不动 |

关键知识点：JS 里 `$`（multiline）在 `\r` **之前**也能匹配，因为 `\r` 本身就是 LineTerminator；所以 `^  {4}build:$/m` 这类锚点在 CRLF 下照样成立。真正会挂的只有**模式中间写死 `\n`** 的那种。这也解释了为什么 pi-4 只看到 1 个失败，而不是十几个。

### 3. README 文案（第 3 步）

只改这两处（"未发布"等部署测试依赖的文案一个字没动）：

```
- 1. 安装 Node.js 24 LTS，双击仓库根目录的 `start.cmd`。
+ 1. 安装 Node.js 24 LTS，双击主仓库根目录的 `start.cmd`。

- …macOS / Linux 使用根目录的 `sh start.sh`。
+ …macOS / Linux 使用主仓库根目录的 `sh start.sh`。
```

### 4–5. 检查 + 一次提交

`npm run check && npm test` 通过后，先跑第 1 阶段 pi-1 的两条安全检查（都无输出），再做**一次**提交：

```
fix: keep LF checkouts and CRLF-tolerant deployment checks
```
提交内容只有 3 个文件：`.gitattributes`（新增）、`README.md`、`test/deployment-image.test.ts`（`3 files changed, 7 insertions(+), 4 deletions(-)`）。

## 关键命令和结果

```
$ git add --renormalize . && git diff --cached --name-only
（空 —— 详见上面第 1 点说明）

$ git add -- .gitattributes && git add --renormalize . && git diff --cached --name-only
.gitattributes                      ← 只有这一个，符合要求

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
ℹ duration_ms 1505.8321

# MySQL 套件按预期跳过：
﹣ bindings / ﹣ migrations / ﹣ tokens / ﹣ api over MySQL (AC1/AC4)
  # no MySQL configured: set CT_TEST_MYSQL_URL (or DB_HOST/DB_USER/DB_NAME) to run this suite

# 两条安全检查（提交前，均无输出）
$ git diff --cached --name-only | grep -E '(^|/)\.signing/|\.(p12|p7b|cer|csr|pfx|jks)$|build-profile\.json5|\.cjs$|(^|/)\.env$|\.pid$'
$ git diff --cached | grep -iE 'storePassword|keyPassword'
$ git diff --cached --name-only | grep node_modules        ← 也无输出

$ git log --oneline
841cc86 fix: keep LF checkouts and CRLF-tolerant deployment checks
fcd073d feat: initial relay server (split from cloudterminal@927fc25)

$ git status --short      # 无输出
$ git remote -v           # 无输出

$ git ls-files --eol | grep README.md
i/lf  w/lf  attr/text=auto eol=lf   README.md       ← 属性已生效
```

### 额外做的验证（在仓库外的一次性副本里，做完已删除）

为了不只满足于"报的那一条用例过了"，我把整个仓库复制到 `D:\MyNewProjects\_scratch\crlf-probe-pi2`，把所有文本文件**强制转成 CRLF**（模拟最坏情况的 Windows 克隆），在副本里跑：

```
修复前：ℹ tests 10 / pass 9 / fail 1
        ✖ default compose entries pull an image and never build on the server
          AssertionError: compose.yml must keep the persistent key volume
        （与 pi-4 报的现象完全一致）

修复后（全量 119 个用例，全部文件 CRLF）：
        ℹ tests 119 / pass 119 / fail 0
```

这也证明了 pi-4 的判断：只有第 111 行那条会因为 CRLF 失败。

验证完已 `Remove-Item -Recurse` 删掉该临时目录（`Test-Path` → `False`），服务端仓库工作区仍然干净。

### 5 个副本文件哈希：仍然不变（pi-3 第 3 步可以直接用）

```
c204a785e7f9dbbbed6d3046fb8d52d966bbb9d46fd47ec20cc0491ca8125ae6 src/relay/relay.ts
7ed809a73b8b933f7aac49bd3de139838de110a7ad095d218ebcafa629eba881 src/shared/relay-protocol.ts
6c93328d72e5c7deba01a04f52523fcad664baed5d58f2e29465f3ff6a67aad5 src/shared/protocol-account.ts
92228b0c03df673ef972591fb3fe99aaad93a468e09a3a7966fdacf1c6656700 src/shared/crypto.ts
43b235df066dc07cb27e734f1085a7f766ff09020eaaa7ee5982252496af0952 src/shared/log.ts
```
与 `reports/pi-2-phase1.md` 里记录的**完全相同** —— 本次没有碰这 5 个文件。pi-3 重跑 `sync-relay.ts` 时 `relay-core.json` 里只有 `commit` 会从 `fcd073d` 变成 `841cc86`。

## 和 design.md 不一致的地方

无。`design.md` §10 第 9 条原本写"暂不处理：不加 `.gitattributes`"，但那一条的前提是"一致性检查本来就会先统一换行"；2c 的实测发现它还影响 `deployment-image.test.ts` 的全新克隆（不只是哈希比对），所以 2d 决定加上。这属于 2d 对 §10 第 9 条的**有意推翻**，我照 2d 执行。§10 其他条目未受影响。

## 需要协调者决定的事

1. **提交信息是我拟的**，2d 只要求"只做一次提交"，没给文案。我用的是 `fix: keep LF checkouts and CRLF-tolerant deployment checks`（正文说明了 CRLF 根因 + README 文案）。如果要求 `chore:` 或别的措辞，需要 amend（我这次不自行改）。
2. **`.gitattributes` 的取舍**：`* text=auto eol=lf` 会让 Windows 开发者的检出也变 LF（这是本意，测试和 CI 行为一致）。如果团队里有人习惯在 Windows 上编辑出 CRLF，这不会妨碍他提交（git 会归一化），但编辑器里看到的可能和磁盘上不一致。当前无远程、无人协作，暂无影响。
3. 顺带提醒（不是本次范围）：2d 的 pi-3 第 3 步要重跑 `sync-relay.ts`，所以主仓库 `relay-core.json` 里的 `commit` 会变成 `841cc86`——**不是** `fcd073d`。如果 pi-1 的审查脚本里写死了 `fcd073d`，需要相应调整。
