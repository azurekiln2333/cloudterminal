# pi-4 第 2 阶段报告（2c / pi-4 第 1–5 步）

## 0. 结论

**部分完成：脚本全部按指令跑完，但发现了 1 个真实失败和 1 个既有问题。**

- 步骤 1（扫描两个仓库）：**通过**。两个仓库的检查 A、B 都 PASS。
- 步骤 2（服务端仓库全新克隆 + `npm ci` + `tsc` + 测试）：**失败**。`npm ci` 和 `npm run check` 通过，`npm test` 有 **1 个用例失败**：`deployment-image.test.ts:93` 的 `default compose entries pull an image and never build on the server`。根因是**行尾符**：服务端仓库没有 `.gitattributes`，本机 `core.autocrlf=true`，全新克隆把 `compose.yml` 检出成 CRLF，而该用例断言字面 `\n`。**CI（ubuntu）是 LF，所以 CI 不会红**，但任何 Windows 全新克隆都会失败。详见 §3。
- 步骤 3（主仓库全新克隆 + server/ npm + 两次 flutter）：**部分通过**。
  - `server/`：`npm ci`、`npm run check` 通过，`npm test` **168 个用例 / 29 个套件 / 通过 167 / 失败 0 / 跳过 1**（跳过的是 herdr 录制的 fixture，跳过理由文案正确）。
  - 仓库根 `flutter analyze`：**失败，59 个 issue**，全部在 `apps/cloudterminal_windows/**`。这是**既有问题**，不是拆分引入的：我用同一个克隆切到拆分前的提交 `927fc25` 对照，报的是**同样的 59 个 issue**。详见 §4.2。
  - 由于脚本在根 `flutter analyze` 处中止，我按任务顺序把剩下的步骤在同一个克隆里补跑完：根 `flutter test` **267 个用例全通过**；`apps/cloudterminal_windows` 的 `flutter pub get` / `flutter analyze`（**No issues found!**）/ `flutter test`（**11 个用例全通过**）。
- 步骤 4（一致性检查三步）：**全部符合预期**。`--check` 退出 0 → 篡改 `crypto.ts` 后 `--check` 退出 1 且 `relay-core-sync.test.ts` 失败 → 用 `git show HEAD:` 还原后两者都恢复通过。
- 步骤 5：本报告。

**两个仓库的原目录没有任何文件改动**：主仓库仍是 `beed231` + 只有 `?? .trellis/tasks/11-09-repo-split/`；服务端仓库仍是 `fcd073d` + `git status` 干净。没有 push，没有 remote，没有运行 `task.py`。唯一在服务端仓库原目录里执行过的动作是**只读的** `node --test test/deployment-image.test.ts`（为了确认"原目录 10/10 通过、克隆里 1 个失败"，见 §3.2），它不写任何文件；没有在原目录运行 `npm install` / `npm ci`。

## 1. 本次涉及的提交与目录

| 仓库 | HEAD | 状态 |
|---|---|---|
| 主仓库 `D:\MyNewProjects\cloudterminal` | `beed231 docs: point relay deployment at the server repo` | `git status --short` 只有 `?? .trellis/tasks/11-09-repo-split/` |
| 服务端仓库 `D:\MyNewProjects\cloudterminal-relay-server` | `fcd073d feat: initial relay server (split from cloudterminal@927fc25)` | `git status --short` 无输出 |

本次新产生（都在我的工作区，不碰两个原仓库）：

| 目录/文件 | 用途 |
|---|---|
| `_scratch\fresh-20261109-224742\` | 服务端仓库的全新克隆（`KEEP=1`，保留） |
| `_scratch\fresh-20261109-224900\` | 主仓库的全新克隆（`KEEP=1`，保留；步骤 3 的补跑和步骤 4 都在这里做的） |
| `_scratch\presplit-927fc25\` | 额外克隆，切到拆分前的 `927fc25`，用来证明 §4.2 的 analyze 失败是既有问题 |
| `.trellis\tasks\11-09-repo-split\reports\` | 本报告（`pi-4-phase2.md`） |

步骤 3 的完整日志存在 `_scratch\repo-split-pi4\main-clone.log`；步骤 2 没有单独存日志，输出见 §3.1。

脚本本身没有改动，仍是第 1 阶段写的那两个（`scan-history.sh`、`fresh-clone-test.sh`）。

## 2. 步骤 1：两个仓库各跑一次 `scan-history.sh`

```
$ bash scan-history.sh /d/MyNewProjects/cloudterminal-relay-server
== HEAD: fcd073d   提交数: 1   远端: (无)
== 检查 A: 私钥/令牌/口令明文
PASS 无命中
== 检查 B: 历史中的签名材料 / *.cjs
PASS 无命中
== 检查 C: 隐私提示（仅提示，不影响退出码）
INFO 未发现 lichengyu / C:\Users / D:\ 痕迹
== 结论: PASS          SERVER_RC=0
```

```
$ bash scan-history.sh /d/MyNewProjects/cloudterminal
== HEAD: beed231   提交数: 24   分支/引用: codex/general-terminal main   远端: (无)
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
== 结论: PASS          MAIN_RC=0
```

主仓库从 21 个提交变成 24 个（pi-3 的 3 个提交已进去），检查 A、B 仍然干净。`*.cjs` 仍然不在历史里，`.signing/` 也不在——第 1 阶段担心的东西确实没混进去。

## 3. 步骤 2：服务端仓库全新克隆（`server` 模式）—— 1 个用例失败

### 3.1 实际输出

```
$ KEEP=1 bash fresh-clone-test.sh /d/MyNewProjects/cloudterminal-relay-server server
== 克隆到:  /d/MyNewProjects/_scratch/fresh-20261109-224742
== 克隆内容检查: 不该提交的文件
PASS 无签名材料、调试脚本或口令字段
$ npm ci          → 通过
$ npm run check   → 通过（tsc --noEmit 无输出）
$ npm test        → 失败
ℹ tests 119   ℹ suites 22   ℹ pass 118   ℹ fail 1   ℹ cancelled 0   ℹ skipped 0   ℹ todo 0
（MySQL 套件按预期跳过：`# no MySQL configured: set CT_TEST_MYSQL_URL …`）

✖ failing tests:
test at test\deployment-image.test.ts:93:1
✖ default compose entries pull an image and never build on the server (5.5601ms)
  AssertionError [ERR_ASSERTION]: compose.yml must keep the persistent key volume
      at file:///D:/MyNewProjects/_scratch/fresh-20261109-224742/test/deployment-image.test.ts:111:12
```

### 3.2 根因：克隆检出成 CRLF，用例断言字面 `\n`

`test/deployment-image.test.ts:111`：

```ts
assert.match(compose, /^volumes:\n {2}relay-data:$/m, `${file} must keep the persistent key volume`);
```

JS 的 multiline `$` 只匹配 `\n` 之前，不会跨过 `\r`，所以 `relay-data:\r` 不匹配。

证据链：

| 检查 | 结果 |
|---|---|
| `git -C cloudterminal-relay-server config --show-origin core.autocrlf` | `file:D:/ProgramFiles/Git/etc/gitconfig true`（Git for Windows 系统配置，仓库没有覆盖） |
| 服务端仓库有 `.gitattributes` 吗 | 没有（`git ls-files .gitattributes` 空） |
| 原目录 `git ls-files --eol compose.yml` | `i/lf  w/lf`（工作区是 LF —— 是 pi-2 写文件时留下的状态） |
| 克隆 `git ls-files --eol compose.yml` | `i/lf  w/crlf`（索引一样，检出时被 autocrlf 转成 CRLF） |
| 原目录跑 `node --test test/deployment-image.test.ts` | **10 / 10 通过** |
| 克隆跑同一文件 | 10 个里 1 个失败（就是第 111 行那条） |
| 克隆里 `compose.yml` 的 CRLF 行数 / 原目录 | 35 / 0 |

结论：这不是拆分引入的，是**服务端仓库缺 `.gitattributes`** 导致的"只在我机器上能过"。主仓库有 `.gitattributes`（虽然只配了 journal 的 merge 策略，没有 `text=auto`），主仓库克隆里 `server/` 的 168 个测试全过，所以没有暴露同类问题。

影响面：CI 的 `deployment-files` job 跑在 `ubuntu-24.04`（checkout 是 LF），所以 **CI 不会红**；受影响的是"任何人在 Windows 上 clone 后本地跑测试"。而"别人 clone 之后能跑通"正是 fresh-clone 测试要保证的东西。

### 3.3 修复建议（服务端仓库归 pi-2，我不改）

二选一，建议两个都做：

1. 服务端仓库加 `.gitattributes`：`* text=auto eol=lf`（或最小化：`compose*.yml text eol=lf`）。这样 Windows 克隆也是 LF，测试和 CI 行为一致。
2. 让断言对 CRLF 宽容：`/^volumes:\r?\n {2}relay-data:$/m`。同一个文件里其它用 `\n` 拼正则的地方（如 `serviceBlock` 已经按 `split(/\r?\n/)` 处理）也可以顺手统一。

顺带一提：`test/deployment-image.test.ts` 之外没有别的用例对行尾敏感（整轮 119 个用例只有这 1 个失败）。

## 4. 步骤 3：主仓库全新克隆（`main` 模式）

### 4.1 克隆里的 `server/`

```
== 克隆 HEAD: beed231 (docs: point relay deployment at the server repo)
== 克隆内容检查: 不该提交的文件
PASS 无签名材料、调试脚本或口令字段
$ cd server && npm ci          → 通过
$ npm run check                → 通过
$ npm test                     → 通过
ℹ tests 168   ℹ suites 29   ℹ pass 167   ℹ fail 0   ℹ cancelled 0   ℹ skipped 1   ℹ todo 0
ℹ duration_ms 75627.2
```

跳过的 1 个用例（说明 pi-3 的跳过逻辑在全新克隆里确实生效，文案也正确）：

```
﹣ parses every recorded live probe file (0.5299ms)
  # no recorded probe fixtures under D:\MyNewProjects\_scratch\fresh-20261109-224900\.build\pi-herdr\herdr-probe (..\.build\pi-herdr\herdr-probe is not committed)
```

### 4.2 仓库根 `flutter analyze` 失败（59 个 issue，既有问题）

```
$ flutter pub get   → 通过
$ flutter analyze   → 失败
  error - Target of URI doesn't exist: 'package:qr_flutter/qr_flutter.dart' - apps\cloudterminal_windows\lib\screens\pairing_page.dart:4:8
  error - Target of URI doesn't exist: 'package:cloudterminal_windows/engine/sidecar_client.dart' - apps\cloudterminal_windows\test\sidecar_ipc_test.dart:11:8
  ... （共 59 条，全部在 apps\cloudterminal_windows\ 下）
59 issues found. (ran in 5.5s)
FAIL 命令失败: flutter analyze
```

原因：`flutter analyze` 在仓库根跑时，把 `apps/cloudterminal_windows/**` 当成**根包**的一部分来分析，而根包的 `.dart_tool/package_config.json` 里没有这个 app 自己的依赖（`qr_flutter`、`package:cloudterminal_windows/...`）。`apps/cloudterminal_windows` 是独立 package（有自己的 `pubspec.yaml` / `analysis_options.yaml`），必须在自己目录里分析。

**这不是拆分引入的**，对照实验：

```
$ git clone ... _scratch/presplit-927fc25 && git checkout 927fc25
$ flutter pub get && flutter analyze
  error - The function 'ToolProbe' isn't defined - apps\cloudterminal_windows\test\widget_test.dart:155:17
  error - Undefined name 'ToolKind' - apps\cloudterminal_windows\test\widget_test.dart:155:33
59 issues found. (ran in 3.6s)
```

拆分前的 `927fc25` 报的是**同样的 59 个 issue**。

同一批 `apps/` 代码在它自己的目录里是干净的：

```
$ cd apps/cloudterminal_windows && flutter pub get && flutter analyze
Analyzing cloudterminal_windows...
No issues found! (ran in 2.0s)
```

修复建议（不在我的改动范围内，交协调者）：在根 `analysis_options.yaml` 里加

```yaml
analyzer:
  exclude:
    - apps/**
```

或者把 fresh-clone 脚本/CI 的"根目录 flutter analyze"改成 `flutter analyze lib test`。前者更彻底（IDE 里也不会再报）。

### 4.3 脚本中止后我在同一克隆里补跑的剩余步骤

| 命令（目录） | 结果 |
|---|---|
| `flutter test`（仓库根） | `+267` **All tests passed!** |
| `flutter pub get`（`apps/cloudterminal_windows`） | `Got dependencies!` |
| `flutter analyze`（`apps/cloudterminal_windows`） | **No issues found!** (ran in 2.0s) |
| `flutter test`（`apps/cloudterminal_windows`） | `+11` **All tests passed!** |

Flutter 版本：`Flutter 3.27.5-ohos-1.0.1`（鸿蒙分支），本机只跑了 Windows/桌面端测试，没有 `flutter build`/打包，也没有跑鸿蒙工具链的构建，所以**没有出现鸿蒙工具链崩溃**。

附带观察（不是失败）：`flutter pub get` 会改写克隆里的生成文件，`git status` 因此多出 6 个 `M`：

```
 M apps/cloudterminal_windows/windows/flutter/generated_plugin_registrant.cc
 M apps/cloudterminal_windows/windows/flutter/generated_plugin_registrant.h
 M apps/cloudterminal_windows/windows/flutter/generated_plugins.cmake
 M linux/flutter/generated_plugin_registrant.{cc,h}  / linux/flutter/generated_plugins.cmake
 M macos/Flutter/GeneratedPluginRegistrant.swift
 M windows/flutter/generated_plugin_registrant.{cc,h} / windows/flutter/generated_plugins.cmake
```

也就是说"全新克隆 → pub get"本身就会弄脏工作区；这不影响检查结论，但第 3 阶段之前如果有人要在克隆里提交，需要先确认这些生成文件该不该进仓库。

## 5. 步骤 4：一致性检查三步（在 `_scratch\fresh-20261109-224900\server` 里做）

### 5.1 篡改前

```
$ cd <克隆>/server
$ node scripts/sync-relay.ts /d/MyNewProjects/cloudterminal-relay-server --check
relay core is in sync with https://github.com/azurekiln2333/cloudterminal-relay-server@fcd073d04e18
CHECK_RC=0

$ node --test test/relay-core-sync.test.ts
ℹ tests 1  ℹ pass 1  ℹ fail 0
```

### 5.2 追加 `// tamper` 之后

```
$ printf "\n// tamper\n" >> src/shared/crypto.ts
$ node scripts/sync-relay.ts /d/MyNewProjects/cloudterminal-relay-server --check
relay core is out of sync:
  src/shared/crypto.ts: acb7530214d10bee2ef3f212de21bce82ab34680e1c37e5a657eaf499e767400 != 92228b0c03df673ef972591fb3fe99aaad93a468e09a3a7966fdacf1c6656700
The relay core copy must match the relay server repo.
Fix it in the relay server repo first, then run:
  npm run sync-relay -- <path-to-cloudterminal-relay-server>
CHECK_RC=1

$ node --test test/relay-core-sync.test.ts
✖ the relay core copy matches relay-core.json (6.8406ms)
ℹ tests 1  ℹ pass 0  ℹ fail 1
```

两边都按设计失败了，而且报错文案确实指向"先改服务端仓库，再运行同步脚本"。

### 5.3 还原之后

用任务书里指定的命令还原：

```
$ git -C <克隆> show HEAD:server/src/shared/crypto.ts > <克隆>/server/src/shared/crypto.ts
$ node scripts/sync-relay.ts ... --check
relay core is in sync with https://github.com/azurekiln2333/cloudterminal-relay-server@fcd073d04e18
CHECK_RC=0
$ node --test test/relay-core-sync.test.ts
ℹ tests 1  ℹ pass 1  ℹ fail 0
```

两项都恢复通过。补充一个细节（不影响结论，但值得知道）：`git show HEAD:` 写出来的是 **LF**，而这个克隆里原文件是 **CRLF**（`core.autocrlf=true`），所以还原后 `git status` 会短暂显示 ` M server/src/shared/crypto.ts`：

```
$ git diff --ignore-cr-at-eol -- server/src/shared/crypto.ts | wc -l
0                     # 差异只有行尾符
$ git add -- server/src/shared/crypto.ts   # 模拟
（无输出 — 暂存内容与 HEAD 完全相同）
$ git reset -q -- server/src/shared/crypto.ts
$ git status --short -- server/src/shared/crypto.ts
（无输出 — 干净）
```

也就是说：文件内容的哈希一致（`sync-relay` 本来就把 CRLF 归一成 LF 再算哈希，design §3 的设计是对的），只是工作区行尾不同。如果以后有人用这条还原命令，接着要提交的话不会带进任何内容差异。

## 6. 关键数字一览

| 检查 | 结果 |
|---|---|
| `scan-history.sh` 服务端仓库 | A PASS / B PASS / 退出 0 |
| `scan-history.sh` 主仓库（24 提交） | A PASS / B PASS / 退出 0 |
| 服务端克隆：`npm ci` / `npm run check` | 通过 / 通过 |
| 服务端克隆：`npm test` | 119 tests，118 pass，**1 fail**（compose.yml 行尾） |
| 主仓库克隆：`server/ npm ci` / `check` | 通过 / 通过 |
| 主仓库克隆：`server/ npm test` | 168 tests，29 suites，167 pass，0 fail，1 skip |
| 主仓库克隆：根 `flutter analyze` | **FAIL，59 issues**（全部在 `apps/`；拆分前同样 59 条） |
| 主仓库克隆：根 `flutter test` | 267 通过 |
| 主仓库克隆：`apps/` `flutter analyze` | No issues found |
| 主仓库克隆：`apps/` `flutter test` | 11 通过 |
| `sync-relay --check` 三步 | 0 → 1 → 0 |
| `relay-core-sync.test.ts` 三步 | pass → fail → pass |

## 7. 需要协调者决定

- **Q1（§3）服务端仓库 CRLF 怎么修。** 建议 pi-2 在服务端仓库加 `.gitattributes`（`* text=auto eol=lf`）**并**把 `deployment-image.test.ts:111` 的断言改成 `\r?\n` 宽容写法。要我下一轮再验证一次的话，改完重跑 `fresh-clone-test.sh ... server` 即可（大约 1 分钟）。
- **Q2（§4.2）根 `flutter analyze` 怎么修。** 这是既有问题，不修也能发布；但"全新克隆后根目录 analyze 干净"这个门槛过不了。建议在根 `analysis_options.yaml` 加 `analyzer: exclude: [apps/**]`（由 pi-3 在主仓库改，我不能改主仓库）。如果决定不修，请在 `implement.md` 的验证门槛里注明"根 analyze 已知有 59 个 apps/ 相关 issue"。
- **Q3 我的 fresh-clone 脚本要不要跟着调整。** 目前 main 模式在根 `flutter analyze` 失败就中止，导致后面的 flutter 步骤要手动补跑。两个选项：(a) 保持现状（严格，先修 Q2）；(b) 把根目录那三条改成 `flutter analyze lib test`（只分析根包真正的代码）。我倾向于 (a) + 修 Q2，因为脚本作为"别人 clone 后能不能跑通"的守门员，宽松化会掩盖问题。
- **Q4 `flutter pub get` 会改写 `windows/linux/macos` 的 6 个生成文件。** 是否要它们进仓库（或加进 `.gitignore`），属主仓库策略问题，我没有改动。

## 8. 遵守的边界（自检）

- 没有 push、没有 `git remote add`、没有访问任何远端；两个仓库都仍无 remote。
- 没有运行 `task.py`，没有用 `/trellis-*` 命令，没有新建任务。
- 没有运行 `reset --hard` / `checkout --` / `restore` / `clean` / `stash` / `rebase` / `commit --amend` / `branch -D`；没有删除任何不是我新建的文件。
- 没有在两个原仓库里运行 `npm install` / `npm ci`；服务端原目录只跑过一次**只读**的 `node --test test/deployment-image.test.ts` 作为对照（§3.2），没有产生文件改动，`git status` 仍干净。
- flutter 只在 `_scratch\fresh-20261109-224900` 和 `_scratch\presplit-927fc25` 这两个我自己新建的克隆里跑过，没有并发跑。
