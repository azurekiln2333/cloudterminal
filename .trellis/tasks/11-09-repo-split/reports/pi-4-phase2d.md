# pi-4 第 2d 阶段报告（重新验证两个仓库）

## 0. 结论

**完成，全部通过。** 2c 阶段发现的两个失败都已修好，本轮重新验证没有再发现新问题。

| 步骤 | 结果 |
|---|---|
| 1. 历史扫描（两个仓库） | **都 PASS**：检查 A、B 无命中，退出码 0 |
| 2. `fresh-clone-test.sh … server` | **PASS**：`npm ci` / `tsc` / `npm test` 全过，**119 / 119**（2c 时是 118 / 119） |
| 3. `fresh-clone-test.sh … main` | **PASS**：脚本一次跑到底，中间不再需要我手动补步骤（2c 时在根 `flutter analyze` 中止） |

对照 2c：

| 检查 | 2c | 2d |
|---|---|---|
| 服务端仓库 `npm test` | 119 个用例，**1 失败**（`compose.yml` 行尾） | **119 / 119 通过** |
| 主仓库根 `flutter analyze` | **FAIL，59 个 issue** | **No issues found!** |

两个仓库的原目录没有任何改动，没有 push、没有 remote、没有运行 `task.py`。

## 1. 本轮验证的提交

| 仓库 | HEAD | 说明 |
|---|---|---|
| 服务端 `D:\MyNewProjects\cloudterminal-relay-server` | `841cc86 fix: keep LF checkouts and CRLF-tolerant deployment checks` | 2 个提交；`git status --short` 无输出；无 remote |
| 主仓库 `D:\MyNewProjects\cloudterminal` | `908f686 fix: analyze the Windows assistant in its own package` | 25 个提交；`git status --short` 只有 `?? .trellis/tasks/11-09-repo-split/`；无 remote |

我先确认了两个修复确实在提交里：

- 服务端仓库 `.gitattributes` 只有一行 `* text=auto eol=lf`，且 `git ls-files --eol compose.yml` 显示 `i/lf  w/lf  attr/text=auto eol=lf`。
- 主仓库 `analysis_options.yaml` 里有 `analyzer:\n  exclude:\n    - apps/**`，并带一行注释说明"Windows 助手是独立的包，在它自己的目录里分析"。

## 2. 步骤 1：历史扫描

```
$ bash scan-history.sh /d/MyNewProjects/cloudterminal-relay-server
== HEAD: 841cc86   提交数: 2   远端: (无)
== 检查 A: 私钥/令牌/口令明文
PASS 无命中
== 检查 B: 历史中的签名材料 / *.cjs
PASS 无命中
== 检查 C: 隐私提示（仅提示，不影响退出码）
INFO 未发现 lichengyu / C:\Users / D:\ 痕迹
== 结论: PASS          SERVER_SCAN_RC=0
```

```
$ bash scan-history.sh /d/MyNewProjects/cloudterminal
== HEAD: 908f686   提交数: 25   分支/引用: codex/general-terminal main   远端: (无)
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
== 结论: PASS          MAIN_SCAN_RC=0
```

检查 C 仍只是提示：`.trellis/` 里的用户名/路径和 4 个测试文件里的绝对路径，仓库公开时可接受。新增的 `.gitattributes` 和 `analysis_options.yaml` 改动没有引入任何历史命中（主仓库从 24 → 25 个提交，服务端从 1 → 2 个提交）。

## 3. 步骤 2：服务端仓库 fresh clone（`server` 模式，KEEP=1）

```
$ KEEP=1 bash fresh-clone-test.sh /d/MyNewProjects/cloudterminal-relay-server server
== 克隆到:  /d/MyNewProjects/_scratch/fresh-20261109-231846
== 克隆 HEAD: 841cc86 (fix: keep LF checkouts and CRLF-tolerant deployment checks)
PASS 无签名材料、调试脚本或口令字段
$ npm ci                      → 通过
$ npm run check               → 通过（tsc --noEmit 无输出）
$ npm test                    → 通过
ℹ tests 119   ℹ suites 22   ℹ pass 119   ℹ fail 0   ℹ cancelled 0   ℹ skipped 0   ℹ todo 0
ℹ duration_ms 1388.9
== 结论: PASS          SERVER_CLONE_RC=0
```

MySQL 套件仍按预期跳过（`# no MySQL configured: set CT_TEST_MYSQL_URL …`），不算失败。

### 3.1 顺手把两个修复各自单独验证了一遍

为了确认不是"碰巧 LF 检出才过"，我在这个克隆里（我自己的克隆，不是原仓库）做了三件事：

1. **确认 `.gitattributes` 生效**：克隆里的工作区现在是 LF，不再是 2c 的 CRLF。

```
$ git ls-files --eol compose.yml compose.tls.yml Dockerfile README.md test/deployment-image.test.ts
i/lf  w/lf  attr/text=auto eol=lf   Dockerfile
i/lf  w/lf  attr/text=auto eol=lf   README.md
i/lf  w/lf  attr/text=auto eol=lf   compose.tls.yml
i/lf  w/lf  attr/text=auto eol=lf   compose.yml
i/lf  w/lf  attr/text=auto eol=lf   test/deployment-image.test.ts
```

（2c 时这里是 `i/lf  w/crlf  attr/`。）

2. **单独验证 `\r?\n` 宽容写法**：把 `compose.yml` 强行改成 CRLF（`sed -i "s/$/\r/"`），此时 `git ls-files --eol` 显示 `i/lf w/-text`，模拟"没有 .gitattributes 保护"的情况：

```
$ node --test test/deployment-image.test.ts
ℹ tests 10   ℹ pass 10   ℹ fail 0
```

也就是说即使将来有人绕过 `.gitattributes` 提交 CRLF 文件，部署契约测试也不会再误报。

3. **还原**：`git show HEAD:compose.yml > compose.yml` 后 `w/lf` 恢复，测试仍 **10 / 10**。克隆工作区自己的改动不影响结论（这份克隆是 `KEEP=1` 保留下来给人查的，还原后与 HEAD 一致）。

## 4. 步骤 3：主仓库 fresh clone（`main` 模式，KEEP=1）

```
$ KEEP=1 bash fresh-clone-test.sh /d/MyNewProjects/cloudterminal main
== 克隆到:  /d/MyNewProjects/_scratch/fresh-20261109-231943
== 克隆 HEAD: 908f686 (fix: analyze the Windows assistant in its own package)
PASS 无签名材料、调试脚本或口令字段
```

阶段一：克隆里的 `server/`

```
$ cd server && npm ci         → 通过
$ npm run check               → 通过
$ npm test                    → 通过
ℹ tests 168   ℹ suites 29   ℹ pass 167   ℹ fail 0   ℹ cancelled 0   ℹ skipped 1   ℹ todo 0
ℹ duration_ms 75558.9
```

唯一跳过的仍是她预期的那一条，理由文案正确：

```
﹣ parses every recorded live probe file (0.3622ms)
  # no recorded probe fixtures under D:\MyNewProjects\_scratch\fresh-20261109-231943\.build\pi-herdr\herdr-probe (..\.build\pi-herdr\herdr-probe is not committed)
```

阶段二：仓库根目录 flutter

```
$ flutter pub get             → 通过
$ flutter analyze             → Analyzing fresh-20261109-231943...
                                No issues found! (ran in 4.9s)
$ flutter test                → 00:06 +267: All tests passed!
```

注意 analyze 的标题是 `Analyzing fresh-20261109-231943...`（根包），不再把 `apps/` 拉进来，也没有再出现 2c 的 59 个 issue。

阶段三：`apps/cloudterminal_windows` flutter

```
$ flutter pub get             → 通过
$ flutter analyze             → Analyzing cloudterminal_windows...
                                No issues found! (ran in 1.9s)
$ flutter test                → 00:00 +11: All tests passed!
```

整个脚本一次跑完，**没有中途失败、没有需要我手动补跑的步骤**（2c 时我在根 analyze 处中止，后续 4 步是手工补的）。

可见 `apps/**` 的排除没有掩盖真问题：`apps/` 在它自己的目录里仍然被完整分析，结果同样是 No issues。

## 5. 关键数字汇总（2d）

| 检查 | 2c | 2d |
|---|---|---|
| `scan-history` 服务端 | A/B PASS | A/B PASS（2 个提交） |
| `scan-history` 主仓库 | A/B PASS | A/B PASS（25 个提交） |
| 服务端克隆 `npm ci` / `check` | 通过 / 通过 | 通过 / 通过 |
| 服务端克隆 `npm test` | 119 tests，118 pass，**1 fail** | **119 tests，119 pass，0 fail** |
| 服务端克隆 `deployment-image.test.ts` 单独跑 | 10 个里 1 个失败 | 10/10（LF）；强行 CRLF 时也 10/10 |
| 主仓库克隆 `server/` `npm test` | 168 tests，167 pass，1 skip | 168 tests，167 pass，1 skip（不变） |
| 主仓库克隆 根 `flutter analyze` | **FAIL，59 issues** | **No issues found!** |
| 主仓库克隆 根 `flutter test` | 267 pass | 267 pass |
| 主仓库克隆 `apps/` `flutter analyze` | No issues | No issues |
| 主仓库克隆 `apps/` `flutter test` | 11 pass | 11 pass |

## 6. 需要协调者知道的两件事（都不阻塞）

1. **修正我 2c 报告里的一个数字错误。** 2c 报告 §4.3 我写了"`flutter pub get` 会多出 6 个 `M`"，实际是 **10 个**（`apps/.../windows/flutter` 3 个 + `linux/flutter` 3 个 + `macos/Flutter` 1 个 + `windows/flutter` 3 个）。本轮全新克隆跑完 `flutter pub get` 后 `git status --short` 正是这 10 个文件：

   ```
    M apps/cloudterminal_windows/windows/flutter/generated_plugin_registrant.cc
    M apps/cloudterminal_windows/windows/flutter/generated_plugin_registrant.h
    M apps/cloudterminal_windows/windows/flutter/generated_plugins.cmake
    M linux/flutter/generated_plugin_registrant.cc
    M linux/flutter/generated_plugin_registrant.h
    M linux/flutter/generated_plugins.cmake
    M macos/Flutter/GeneratedPluginRegistrant.swift
    M windows/flutter/generated_plugin_registrant.cc
    M windows/flutter/generated_plugin_registrant.h
    M windows/flutter/generated_plugins.cmake
   ```

   这是 `flutter pub get` 的固有行为（生成文件随本机 SDK 重写），只发生在我保留的克隆里，不影响两个仓库。是否要把这些生成文件纳入 `.gitignore` 属于主仓库策略，我没动。

2. **保留的克隆目录**（`KEEP=1`，供事后检查）：

   | 目录 | 内容 |
   |---|---|
   | `_scratch\fresh-20261109-231846` | 服务端仓库 `841cc86` 的克隆（已验证 `.gitattributes`、强行 CRLF 试验后已还原） |
   | `_scratch\fresh-20261109-231943` | 主仓库 `908f686` 的克隆（完整跑过 npm + 两次 flutter） |
   | `_scratch\repo-split-pi4\server-clone-2d.log` | 步骤 2 的完整日志 |
   | `_scratch\repo-split-pi4\main-clone-2d.log` | 步骤 3 的完整日志 |

   上一轮（2c）的 `fresh-20261109-224742`、`fresh-20261109-224900`、`presplit-927fc25` 也还在 `_scratch` 下，确认没用之后可以删（共约几百 MB，主要是 `node_modules` 和 `.dart_tool`）。

## 7. 边界自查

- 两个仓库的原目录：主仓库仍 `908f686` + 只有未跟踪的 `.trellis/tasks/11-09-repo-split/`；服务端仓库仍 `841cc86` + `git status` 干净。都没有被我写入。
- 没有 push、没有 `git remote add`、没有访问远端（两边 `git remote -v` 都为空）。
- 没有运行 `task.py`，没有用 `/trellis-*` 命令，没有新建任务。
- 没有运行 `reset --hard` / `checkout --` / `restore` / `clean` / `stash` / `rebase` / `commit --amend` / `branch -D`；没有删任何不是我新建的文件。
- 没有在两个原仓库里运行 `npm install` / `npm ci` / `flutter`。
- flutter 只在我自己新克隆的 `_scratch\fresh-20261109-231943` 里跑（根目录 + `apps/` 两处），串行执行，没有并发。
- 在服务端克隆里做的 CRLF 试验（`sed -i` 改 `compose.yml`）只用 `git show HEAD:compose.yml` 还原，没有用被禁止的 git 命令。
