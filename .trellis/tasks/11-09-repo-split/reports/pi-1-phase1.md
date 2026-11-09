# pi-1 第 1 阶段报告

## 结论

**完成。** 备份已做并验证，主仓库的 9 个本地提交已全部落地，工作区只剩 `?? .trellis/tasks/11-09-repo-split/`，两项历史扫描 0 命中，三套检查全绿。未推送、未加 remote、未使用任何会丢东西的 git 命令。

## 做了什么

### 1. 备份（先做，再动其他东西）

环境里没有 git bash（`C:\Program Files\Git\bin\bash.exe` 不存在），WSL 也不可用（`Wsl/Service/CreateInstance/CreateVm/HCS/HCS_E_HYPERVISOR_NOT_INSTALLED`），所以用 Windows 自带的 `tar.exe`（bsdtar）执行同样的命令，路径改成 Windows 形式；exclude 语义先在一个临时小目录里验证过（`--exclude=node_modules` 和 `--exclude=proj/build` 都能命中嵌套路径）。

```powershell
tar -czf D:\MyNewProjects\_backups\cloudterminal-20261109-215253.tar.gz `
  --exclude=node_modules --exclude=oh_modules --exclude=.dart_tool --exclude=.hvigor `
  --exclude=cloudterminal/build --exclude=cloudterminal/apps/cloudterminal_windows/build `
  --exclude=cloudterminal/ohos/entry/build --exclude=cloudterminal/android/app/build `
  -C D:/MyNewProjects cloudterminal
```

结果：

- 文件：`D:\MyNewProjects\_backups\cloudterminal-20261109-215253.tar.gz`，`15,196,689` 字节，耗时 1.7s，退出码 0。
- `tar -tzf` 条目总数 3315，其中 `cloudterminal/.git/` 1034 条（`.git/objects/` 992 条）、`cloudterminal/lib/` 43 条、`cloudterminal/server/src/` 53 条、`cloudterminal/.signing/` 51 条 —— `.git`、`lib`、`server/src`、`.signing` 四项都在。
- **额外验证（implement.md 没要求）**：把备份解包到 `_backups\_verify`，确认 `git log --oneline -1` = `43cc663 feat(app): add herdr workspace control with reflowing pane viewport`、`git status --short` 同样是 162 行、`git fsck` 只有正常的历史遗留 dangling blob/commit 提示。验证完删掉了 `_backups\_verify`（这个目录是我本次新建的，未动其他任何文件）。

### 2. 本地忽略设置

| 动作 | 验证 |
|---|---|
| `.gitignore` 末尾追加 `.signing/`、`*.pid` | `git check-ignore -v` 命中 `.gitignore:51:.signing/` 和 `.gitignore:52:*.pid` |
| `.git/info/exclude` 追加 `server/ansi.cjs`、`server/check-herdr.cjs`、`server/hold.cjs` | 三个文件都命中 `.git/info/exclude` 第 7/8/9 行，文件本身没动 |
| `git update-index --skip-worktree ohos/build-profile.json5` | `git ls-files -v` 显示 `S ohos/build-profile.json5`；`git status --short ohos/build-profile.json5` 空；`git show HEAD:ohos/build-profile.json5 \| grep -c storePassword` = **0** |

补充事实：`.signing/` 从来没有被跟踪过（`git ls-files .signing` 0 条，`git log --all --name-only` 里也没有 `.signing/` 前缀），所以只是"以后也不会进去"。

### 3. 按组提交

每次 `git commit` 前都跑了两条守卫命令（用 PowerShell 复刻同样的正则，放在 `%TEMP%\pi1-guard.ps1`，不在仓库里）：

- 暂存文件名匹配 `(^|/)\.signing/|\.(p12|p7b|cer|csr|pfx|jks)$|build-profile\.json5|\.cjs$|(^|/)\.env$|\.pid$`
- 暂存 diff 匹配 `storePassword|keyPassword`

9 次提交每次都是 `GUARD OK`。

| 组 | 提交 | 内容 |
|---|---|---|
| C1 | `1717090 chore: ignore signing material and pid files` | 1 文件 / +7 |
| C1b | `aaaa7e1 chore: add trailing newline to .gitignore` | 1 文件 / +1 −1 |
| C2 | `4b82ab4 feat(agent): add sidecar, herdr bridge, pty and setup commands` | 41 文件 / +7948 −100 |
| C3 | `792ff8e feat(relay): add tenancy keys, container deploy and image CI` | 13 文件 / +1024 |
| C4 | `7197ffe feat(app): add herdr terminal, codex screens and vendored xterm` | 124 文件 / +27384 −2122 |
| C5 | `4a2f443 feat(windows): add the Windows assistant app` | 41 文件 / +4372 |
| C6 | `a36111a chore(ohos): use the release bundle name and ship build info` | 2 文件 / +1 −1（rename 100%） |
| C7 | `611284a docs: document the general terminal, herdr and Windows assistant` | 5 文件 / +784 −36 |
| C8 | `927fc25 docs(trellis): record the current specs, tasks and workspace journals` | 134 文件 / +9096 −689（已核对 `11-09-repo-split` 一条都没进去） |

C5 的事前检查 `git status --short -uall apps | grep -E '\.iml$|/\.idea/|/build/|/\.dart_tool/'` 没有输出。

提交后的工作区：

```
$ git status --short
?? .trellis/tasks/11-09-repo-split/
```

只有任务目录，没有别的残留文件。

### 4. 历史扫描

- 密钥/令牌扫描（`git rev-list --all` 共 **21** 个提交）→ **0 行输出**。
- 敏感路径扫描（`git log --all --name-only` 去重后匹配 `.signing/`、`*.p12/p7b/cer/csr/pfx/jks`、`*.cjs`）→ **0 命中**。

### 5. 检查

1. `cd server && npm run check` → `tsc --noEmit` 无输出（干净）。`npm test`：

```
ℹ tests 273
ℹ suites 50
ℹ pass 273
ℹ fail 0
ℹ cancelled 0
ℹ skipped 0
ℹ todo 0
ℹ duration_ms 75736.4882
```

   MySQL 套件按预期被跳过，输出是：
   `﹣ api over MySQL (AC1/AC4) (0.0506ms) # no MySQL configured: set CT_TEST_MYSQL_URL (or DB_HOST/DB_USER/DB_NAME) to run this suite`
   （所以 `skipped 0` 是因为它是 suite 级跳过标记，不是 test 级 skip，属正常。）

2. 仓库根目录 `flutter analyze` → `No issues found! (ran in 3.4s)`；`flutter test` → `00:06 +267: All tests passed!`
   analyze 会跑 `Resolving dependencies... Got dependencies!`，结束后 `git status` 仍然干净，`pubspec.lock` 没被改。

3. `cd apps/cloudterminal_windows && flutter analyze` → `No issues found! (ran in 1.1s)`；`flutter test` → `00:00 +11: All tests passed!`

三个 flutter 命令是串行跑的，同一时间只有一个。

### 6. `git log --oneline -12`

```
927fc25 docs(trellis): record the current specs, tasks and workspace journals
611284a docs: document the general terminal, herdr and Windows assistant
a36111a chore(ohos): use the release bundle name and ship build info
4a2f443 feat(windows): add the Windows assistant app
7197ffe feat(app): add herdr terminal, codex screens and vendored xterm
792ff8e feat(relay): add tenancy keys, container deploy and image CI
4b82ab4 feat(agent): add sidecar, herdr bridge, pty and setup commands
aaaa7e1 chore: add trailing newline to .gitignore
1717090 chore: ignore signing material and pid files
43cc663 feat(app): add herdr workspace control with reflowing pane viewport
3df4779 feat(relay): add multi-tenant identity with OAuth2 accounts and MySQL bindings
2838644 docs(spec): document server/app layout and cross-layer protocol rules
```

## 和 implement.md / design.md 不一致的地方

1. **备份命令的执行方式**：没有 bash，用 Windows bsdtar 跑等价命令（见上）。产物的内容和 implement.md 要求的一致。
2. **多了一个 C1b 小提交**（`aaaa7e1`）：我用 `Add-Content -NoNewline` 追加 `.gitignore`，导致文件末尾没有换行，第一次提交里 Git 报 `\ No newline at end of file`。因为规则禁止 `commit --amend`，所以补了一个只加换行的小提交。不影响任何检查。
3. **C1 提交里包含了两处并非本次新增的 `.gitignore` 改动**（`/server.zip`、`/server/server.zip`）。任务开始时 `.gitignore` 本来就是 `M` 状态，而 C1 的指令是 `git add -- .gitignore`（整文件），所以这些既有改动一起进了 C1。内容不敏感。
4. **C2 顺带提交了 relay 侧的测试**：分组写的是 `server/test` 整个目录，所以 `server/test/deployment-image.test.ts`、`deployment.test.ts`、`setup.test.ts` 等也进了 C2（这些都是新文件）。不影响第 2 阶段 pi-3 再改它们。
5. **`server/src/shared/protocol.ts` 的改动落在 C2**（属于 `server/src/shared`）。design.md §4 要拆的正是这个文件的区段，第 1 阶段没动它，第 2 阶段处理。
6. **C6 在 Git 里表现为 rename**（`base/profile/buildinfo.json5` → `rawfile/buildinfo.json5`，100% 相似），不是 delete+add。符合预期。
7. **`server/test/helpers.ts` 没有出现在任何提交里** —— 它已跟踪且内容未改。pi-2 要复制的 `helpers.ts` 用的是主仓库现成版本，没有变化。
8. 提交信息里的 body 是我按各组实际内容写的（implement.md 只要求 conventional 风格），subject 的 scope 用的就是分组名（`chore` / `feat(agent)` / `feat(relay)` / …）。

## 需要协调者决定的事

1. **`git remote -v` 是空的** —— 主仓库当前没有配置任何 remote。第 3 阶段"两个仓库都推送到 main"之前，需要有人确认目标地址（`https://github.com/azurekiln2333/cloudterminal`？）并执行 `git remote add`。我按规则 1 没有碰。
2. **`.trellis/tasks/11-09-repo-split/` 现在永远进不了版本库**：C8 用了 `:(exclude).trellis/tasks/11-09-repo-split`，所以这个任务目录（含 `reports/`、`prd.md`、`design.md`、`implement.md`）是唯一的未跟踪内容。按 design.md §8 主仓库保留完整 Trellis 历史，那这个目录早晚要提交；什么时候提交、由谁提交，请决定（我按规则 9 没做）。
3. **`skip-worktree` 是本地设置，对别人的 clone 无效**，而且会掩盖 `ohos/build-profile.json5` 的真实改动。第 2 阶段 pi-3 若要动这个文件（比如批量格式化、`git checkout` 回滚），会得到"改了但 git 看不见"的结果，需要提前知道。是否要在第 3 阶段推之前手动 `--no-skip-worktree` 再检查一次，请决定。
4. **C1b 那个补换行的提交**如果协调者希望历史更干净，可以等第 3 阶段推送前统一 squash（那属于用户的决定，我没做）。
5. **`_backups` 目录**：`D:\MyNewProjects\_backups\` 里现在只有 `cloudterminal-20261109-215253.tar.gz` 一个文件。要不要在拆仓结束后删，请决定。
6. **行尾符**：提交时 Git 有若干 `warning: in the working copy of 'X', LF will be replaced by CRLF the next time Git touches it`（`core.autocrlf` 相关）。对本阶段检查没有影响，但正好说明 design.md §3 说的"先统一 LF 再算 sha256"是必须的；pi-2 算哈希时务必照做，否则主仓库里工作区文件（可能是 CRLF）会和服务端仓库（LF）对不上。

## 附：本阶段创建/删除的文件

- 新建：`D:\MyNewProjects\_backups\cloudterminal-20261109-215253.tar.gz`、`%TEMP%\pi1-guard.ps1`、本报告。
- 新建后删除：`D:\MyNewProjects\_backups\_verify`（备份验证用的解包目录）。
- 未改动任何不是本次新建的既有文件（除了 implement.md 指定的 `.gitignore`、`.git/info/exclude`，以及被一起提交的原有工作区改动）。
