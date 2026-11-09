# 执行计划：拆分仓库（4 个 pi 分工）

## 分工

| 角色 | 位置 |
|---|---|
| 协调者：Claude | Herdr 面板 `w45:p1` |
| pi-1 | `w45:p2` |
| pi-2 | `w45:p3` |
| pi-3 | `w45:p4` |
| pi-4 | `w45:p5` |

- 需求见同目录的 `prd.md`，设计见 `design.md`。只有协调者能改这三个文件（prd / design / implement）。
- 主仓库：`D:\MyNewProjects\cloudterminal`。

## 0. 规则（每个 pi 都要遵守；违反任何一条，立刻停下写报告）

1. **不推送，不碰远端。** 不 push，不执行 `git remote add`，不访问 GitHub / CNB 的网页或 API。
2. **不执行会丢东西的 git 命令。** 包括：
   - `reset --hard`、`checkout -- <文件>`、`restore`、`clean`
   - `stash`、`rebase`、`commit --amend`、`push --force`、`branch -D`

   也不删除任何不是你本次新建的文件。
3. **提交时只写明确路径。** 只用 `git add -- <明确路径>`，禁止 `git add -A`、`git add .`、`git commit -a`。
4. **以下内容永远不能进任何提交：**
   - `.signing/` 下的任何文件，以及 `*.p12 *.p7b *.cer *.csr *.pfx *.jks`
   - `ohos/build-profile.json5`
   - `server/ansi.cjs`、`server/check-herdr.cjs`、`server/hold.cjs`
   - `.env`（`.env.example` 可以提交）和 `*.pid`
   - 任何 `storePassword` / `keyPassword` 的值
5. **第 1 阶段只有 pi-1 能改主仓库**，包括主仓库的文件和 git 状态。其他 pi 对主仓库只读，唯一例外是把自己的报告写进本任务的 `reports/`。
6. **依赖安装限制。** 不在主仓库的 `server/` 里运行 `npm install` 或 `npm ci`，不建指向主仓库 `node_modules` 的链接（junction / symlink）。
7. **`flutter` 命令同一时间只能有一个 pi 在跑**，并行跑会让鸿蒙工具链崩溃。第 1 阶段只有 pi-1 跑 flutter。
8. **不碰 Trellis 流程命令。** 不运行 `task.py`，不用 `/trellis-*` 命令，不新建 Trellis 任务。当前任务是 `.trellis/tasks/11-09-repo-split`，不要改它的 `task.json`。
9. **只做本文件分给你的那一节。** 做完写报告就停，不接着做下一阶段，也不做别人的部分。
10. **拿不准就写进报告。** 拿不准的事、和设计不符的事、需要用户拍板的事，都不要猜，写进报告的「需要协调者决定」。
11. **长命令别中途打断。** `npm test` 大约要跑 80 秒，属于正常。

**报告**写到 `.trellis/tasks/11-09-repo-split/reports/<编号>-phase<阶段>.md`，用中文，包含：
- 结论：完成 / 部分完成 / 受阻
- 做了什么
- 关键命令和结果（测试数字照抄输出）
- 和 design.md 不一致的地方
- 需要协调者决定的事

## 1. 第 1 阶段（4 个 pi 同时开始）

### pi-1：先备份，再把现有工作提交到本地（唯一能改主仓库的人）

1. **先备份**，做完这一步再动其他东西：
   `mkdir -p /d/MyNewProjects/_backups && tar -czf /d/MyNewProjects/_backups/cloudterminal-$(date +%Y%m%d-%H%M%S).tar.gz --exclude=node_modules --exclude=oh_modules --exclude=.dart_tool --exclude=.hvigor --exclude=cloudterminal/build --exclude=cloudterminal/apps/cloudterminal_windows/build --exclude=cloudterminal/ohos/entry/build --exclude=cloudterminal/android/app/build -C /d/MyNewProjects cloudterminal`

   然后用 `ls -la <备份文件>` 和 `tar -tzf <备份文件> | grep -cE '^cloudterminal/(\.git|lib|server/src|\.signing)/'` 确认备份里有 `.git`、`lib`、`server/src`、`.signing`。

2. **本地忽略设置：**
   - 在 `.gitignore` 末尾追加两行：`.signing/` 和 `*.pid`。
   - `printf 'server/ansi.cjs\nserver/check-herdr.cjs\nserver/hold.cjs\n' >> .git/info/exclude`
   - `git update-index --skip-worktree ohos/build-profile.json5`。确认两点：
     - `git status --short ohos/build-profile.json5` 没有输出；
     - `git show HEAD:ohos/build-profile.json5 | grep -c storePassword` 的结果是 0。

3. **按组依次提交。** 提交信息用英文 conventional commit 风格，参考 `git log --oneline`。

   每次 `git commit` 前，下面两条命令都必须没有输出：
   - `git diff --cached --name-only | grep -nE '(^|/)\.signing/|\.(p12|p7b|cer|csr|pfx|jks)$|build-profile\.json5|\.cjs$|(^|/)\.env$|\.pid$'`
   - `git diff --cached | grep -niE 'storePassword|keyPassword'`

   分组如下：
   - C1 `chore`：`git add -- .gitignore`
   - C2 `feat(agent)`：`git add -- server/src/agent server/src/shared server/scripts server/test server/package.json server/package-lock.json server/tsconfig.json server/.gitignore`
   - C3 `feat(relay)`：`git add -- server/src/relay server/src/db server/src/oauth server/Dockerfile server/.dockerignore server/.env.example server/compose.yml server/compose.tls.yml server/compose.build.yml server/deploy server/README.md server/TUNNEL.md .github .cnb.yml`
   - C4 `feat(app)`：`git add -- lib test pubspec.yaml pubspec.lock third_party`
   - C5 `feat(windows)`：提交前先确认 `git status --short -uall apps | grep -E '\.iml$|/\.idea/|/build/|/\.dart_tool/'` 没有输出，然后 `git add -- apps`
   - C6 `chore(ohos)`：`git add -- ohos/AppScope/app.json5 ohos/entry/src/main/resources/base/profile/buildinfo.json5 ohos/entry/src/main/resources/rawfile/buildinfo.json5`
   - C7 `docs`：`git add -- README.md start.cmd start.sh start-windows.cmd scripts`
   - C8 `docs(trellis)`：`git add -- .trellis ':(exclude).trellis/tasks/11-09-repo-split'`

   全部提交后，`git status --short` 应该只剩 `?? .trellis/tasks/11-09-repo-split/`。如果还有别的文件，写进报告，不要硬塞进某个组。

4. **扫描全部历史**，两条命令都必须没有输出：
   - `git grep -InE -e '-----BEGIN [A-Z ]*PRIVATE KEY-----' -e 'gh[pousr]_[A-Za-z0-9]{30,}' -e 'sk-ant-[A-Za-z0-9_-]{20,}' -e 'AKIA[0-9A-Z]{16}' -e '(store|key)Password"?[[:space:]]*:[[:space:]]*"[^"]+' $(git rev-list --all)`
   - `git log --all --name-only --format= | sort -u | grep -E '(^|/)\.signing/|\.(p12|p7b|cer|csr|pfx|jks)$|\.cjs$'`

5. **跑检查**，按顺序跑，flutter 不要并行：
   1. `cd server && npm run check && npm test`
   2. 在仓库根目录跑 `flutter analyze`，再跑 `flutter test`
   3. `cd apps/cloudterminal_windows && flutter analyze && flutter test`

6. **写报告** `reports/pi-1-phase1.md`，附上 `git log --oneline -12` 的输出。

### pi-2：在新目录搭服务端仓库，并完成解耦

工作目录：`D:\MyNewProjects\cloudterminal-relay-server`。先确认这个目录不存在；如果已经存在，停下写报告。对主仓库只读。

1. **复制文件。** 从主仓库的 `server/` 复制过来，保持相对路径（`server/` 对应新仓库的根目录）：
   - `src/relay/{relay,api,tenancy,key,show-key,main}.ts`
   - `src/db/*`、`src/oauth/*`
   - `src/shared/{protocol-account,crypto,log}.ts`
   - `test/` 下：`relay` `relay-api` `relay-tenancy` `db-bindings` `db-config` `db-migrate` `db-tokens` `oauth-config` `oauth-discovery` `oauth-flows` `oauth-verify` `deployment-image` 这些 `.test.ts`，以及 `helpers.ts` `fake-db.ts` `db-helpers.ts`
   - `Dockerfile` `.dockerignore` `.env.example` `compose.yml` `compose.tls.yml` `compose.build.yml` `deploy/` `README.md` `tsconfig.json`

   再从主仓库根目录复制 `.github/workflows/image.yml` 和 `.cnb.yml`。

   不要复制：`node_modules`、`server.zip`、`*.cjs`、agent 代码和 agent 测试。

2. **新建 `package.json`：**
   - `name` 为 `cloudterminal-relay-server`，`"type": "module"`，`engines.node` 为 `">=23.6"`
   - `dependencies` 只留 `ws` 和 `mysql2`，版本照抄主仓库 `server/package.json`；`devDependencies` 也照抄
   - `scripts` 只要三个：`relay`、`check`（即 `tsc --noEmit`）、`test`（即 `node --test "test/**/*.test.ts"`）

   另外新建 `.gitignore`，至少包含 `node_modules/`、`.env`、`.env.*`、`!.env.example`。

3. **拆协议文件。** 按 design.md §4 新建 `src/shared/relay-protocol.ts`，然后把 `relay.ts` 和各测试里对 `protocol.ts` 的 import 都改成从它导入。

4. **解耦。** 按 design.md §2 修改 `relay.ts`、`tenancy.ts`、`main.ts`、`test/helpers.ts`、`test/relay-api.test.ts`。再按 §6 新建两个测试，用例从主仓库对应位置移植，用到的辅助函数一起带上：
   - `test/relay-startup.test.ts`：来自 `deployment.test.ts:109`
   - `test/relay-key.test.ts`：来自 `setup.test.ts:74`

5. **改 CI 和镜像地址。** 按 design.md §5：
   - 用 `grep -n "server/" .github/workflows/image.yml .cnb.yml` 找出路径，全部改掉
   - 改 `deployment-image.test.ts` 里的目录推算
   - 改默认镜像地址：两个 compose 文件、`.env.example`、`README.md`
   - README 开头加一句：电脑端 agent 与 App 在 https://github.com/azurekiln2333/cloudterminal

6. **装依赖并测试。** 只在这个新目录里运行 `npm install`。然后：
   - `npm run check` 和 `npm test` 全部通过。MySQL 套件被跳过是正常的。
   - `grep -rn "src/agent" src test` 没有输出。

7. **本地提交，不加 remote：**
   1. `git init -b main`
   2. 用 `git add -- <明确路径>` 暂存，再用 `git diff --cached --name-only | grep node_modules` 确认没有输出
   3. 提交，提交信息为 `feat: initial relay server (split from cloudterminal@<主仓库 HEAD 短号>)`

8. **写报告** `reports/pi-2-phase1.md`，包含：
   - 5 个副本文件的 sha256（先把换行统一成 LF 再算，命令见 design.md §3）
   - 测试数字
   - `git log --oneline` 的输出

### pi-3：准备主仓库清理（只准备，不改主仓库）

工作目录：`D:\MyNewProjects\_scratch\repo-split-pi3`，新建一个。

1. **查引用。** 在主仓库 `server/` 里，找出所有会留下的文件（agent、scripts、留下的测试），看它们是否 import 了要移走的文件。要移走的是：
   - `src/relay/{api,tenancy,key,show-key,main}.ts`
   - `src/db/**`、`src/oauth/**`

   报告里写出每处引用，以及打算怎么处理。

2. **写草稿文件。** 在工作目录里按主仓库的相对路径写：
   - `server/scripts/sync-relay.ts` 和 `server/test/relay-core-sync.test.ts`，按 design.md §3
   - 改好的 `server/test/deployment.test.ts`：只留第 49 行和第 92 行两个用例
   - 改好的 `server/test/setup.test.ts`：去掉第 74 行的用例和第 8 行 key.ts 的 import
   - 改好的 `server/test/herdr.test.ts`：第 970 行用到的 fixture 目录不存在时跳过，并写明原因
   - `server/test/helpers.ts`：如果有 db 相关代码，就去掉
   - 改好的 `server/package.json`：去掉 `mysql2` 依赖和 `relay` 脚本，加上 `sync-relay` 脚本
   - 改好的 `README.md`："公网中继服务器"一节改成简短说明，再链接到服务端仓库。README 里所有指向 `.github/`、`.cnb.yml`、`server/README.md`、`server/compose*` 的链接，都改到服务端仓库
   - 改好的 `server/TUNNEL.md`：把链接改到服务端仓库

3. **写删除清单** `delete-list.txt`：列出第 2 阶段要从主仓库删除的每个路径，一行一个，每行写明理由。

4. **写报告** `reports/pi-3-phase1.md`，包含：
   - 引用检查的结果
   - 草稿文件清单
   - 删除清单
   - 第 2 阶段的应用步骤

### pi-4：写验证脚本，核对设计（不改主仓库）

工作目录：`D:\MyNewProjects\_scratch\repo-split-pi4`，新建一个。

1. **写 `scan-history.sh <仓库目录>`。** 对该仓库的全部提交，做 pi-1 第 4 步的两项扫描。另外列出所有提交里出现 `lichengyu`、`C:\Users`、`D:\` 的文件，这一项只是隐私提示，不算失败。

2. **写 `fresh-clone-test.sh <仓库目录> <main|server>`。** 脚本先 `git clone` 到 `D:\MyNewProjects\_scratch\fresh-<时间>`，然后：
   - `server` 模式：`npm ci && npm run check && npm test`
   - `main` 模式：先在 `server/` 里跑 `npm ci && npm run check && npm test`；再在仓库根目录和 `apps/cloudterminal_windows` 里各跑一遍 `flutter pub get && flutter analyze && flutter test`

   第 1 阶段两个模式都不要运行，因为两个仓库都还没准备好。只用 `bash -n` 检查语法。

3. **查 node-pty。** 看主仓库 `server/node_modules/node-pty/` 下有没有 `prebuilds/win32-x64`，据此判断：新 clone 之后，不装 Visual Studio 能不能 `npm ci` 成功。

4. **核对设计（只读）。** 把 design.md 逐条和真实代码对照，找出写错或漏掉的地方。至少查这几项：
   - §4 要移走的区段，是否引用了区段外的符号
   - §6 的测试归属，有没有漏掉的文件
   - 有没有 agent 文件 import 了 `db/`、`oauth/` 或 `relay/key.ts`
   - CI 里还有没有别的 `server/` 路径

5. **写报告** `reports/pi-4-phase1.md`。

## 2. 第 2 阶段（用户同意后，由协调者按 2a → 2b → 2c 的顺序派发）

本阶段对第 0 节规则的调整（其余规则照旧）：
- **规则 5**：只有 pi-3 能改主仓库，只有 pi-2 能改服务端仓库。
- **规则 6**：pi-3 可以在主仓库的 `server/` 里运行 `npm install`，但只能用来更新 `package-lock.json`。
- **规则 7**：只有 pi-4 跑 flutter，而且只在它自己新克隆的目录里跑。

design.md §10 列出的决定已经定了，不要再改。

### 2a. pi-2：改服务端仓库首个提交的说明

1. 这是规则 2 唯一的例外。先确认 `git status --short` 没有输出，然后在 `D:\MyNewProjects\cloudterminal-relay-server` 执行：
   `git commit --amend -m "feat: initial relay server (split from cloudterminal@927fc25)"`
   只改提交说明，不改任何文件。
2. 确认三件事：
   - `git log --oneline` 只有 1 个提交，说明已经是新的；
   - `git status --short` 没有输出；
   - `git remote -v` 没有输出。
3. 写报告 `reports/pi-2-phase2a.md`，写上新的提交号，然后停下。

### 2b. pi-3：清理主仓库（主仓库只有你能改）

按 `reports/pi-3-phase1.md` 第五节的步骤做，草稿在 `D:\MyNewProjects\_scratch\repo-split-pi3`。具体如下：

1. **复制中继核心。** 从服务端仓库原样复制 5 个副本文件。
2. **改 `server/src/shared/protocol.ts`。** 删掉第 7 行和整个 Relay envelope 区段（包括 `RelayFrame`），在原位置写一行 `export * from './relay-protocol.ts';`。`PROTOCOL_VERSION` 不动。
3. **应用草稿。** 草稿文件全部照搬。
4. **删除文件。** 按 `delete-list.txt`，用 `git rm -- <明确路径>` 删除；`deploy` 目录用 `git rm -r -- server/deploy`。这些路径不受规则 2"不删文件"的限制，因为删掉的内容都能从历史里找回。
5. **生成校验文件。** 运行 `cd server && node scripts/sync-relay.ts D:/MyNewProjects/cloudterminal-relay-server`，然后加 `--check` 再跑一次，必须退出 0。
6. **更新依赖锁文件。** 运行 `cd server && npm install`，然后看 `git diff --stat -- server/package-lock.json`。锁文件里只允许少掉 `mysql2` 和只被 `mysql2` 用到的包；如果其他包的版本也变了，停下写报告。
7. **跑检查。** `npm run check && npm test` 必须全部通过。
8. **查遗留引用。** 运行：
   `git grep -nE "server/README\.md|server/compose|server/Dockerfile|server/deploy|workflows/image\.yml|\.cnb\.yml|src/relay/(api|tenancy|key|show-key|main)\.ts|src/(db|oauth)/" -- ':!.trellis/tasks' ':!.trellis/workspace'`
   把每一处命中都写进报告，并标明是"指向服务端仓库，可以留"还是"需要处理"。需要处理的就改掉，第 9 步提到的规范文件例外。
9. **改规范。** 在 `.trellis/spec/backend/` 下的 `index.md`、`directory-structure.md`、`deployment.md`、`database-guidelines.md` 开头各加一段，写明以下三点，文件其余内容不动：
   - 中继服务器、账号、数据库、OAuth、部署和 CI 已经移到 `cloudterminal-relay-server`；
   - 本仓库只保留 5 个中继核心副本；
   - 要改这几个副本，先改服务端仓库，再运行 `npm run sync-relay -- <服务端仓库目录>`。
10. **分三次提交。** 每次提交前照旧跑第 1 阶段 pi-1 的两条安全检查。
    - `test(agent): skip recorded herdr probes when the fixtures are absent`：只放 `server/test/herdr.test.ts`
    - `refactor(server)!: move the public relay to cloudterminal-relay-server`：其余所有代码改动和删除，包括 `relay-core.json`、`package.json`、`package-lock.json`
    - `docs: point relay deployment at the server repo`：`README.md`、`server/TUNNEL.md`、`.trellis/spec`

    提交完后，`git status --short` 应该只剩 `?? .trellis/tasks/11-09-repo-split/`。
11. **写报告** `reports/pi-3-phase2.md`，附上 `git log --oneline -4` 的输出和测试数字。

### 2c. 验证（pi-3 提交后同时派发；不要改两个仓库）

**pi-4**
1. 两个仓库各跑一次 `bash scan-history.sh`，A 和 B 两项都要 PASS。
2. 跑 `KEEP=1 bash fresh-clone-test.sh /d/MyNewProjects/cloudterminal-relay-server server`。
3. 跑 `KEEP=1 bash fresh-clone-test.sh /d/MyNewProjects/cloudterminal main`。如果 flutter 失败的原因是本机环境（例如鸿蒙工具链），照实写进报告，不要去改代码。
4. 在第 3 步新克隆的主仓库的 `server/` 目录里，按顺序做：
   1. `node scripts/sync-relay.ts /d/MyNewProjects/cloudterminal-relay-server --check`，应该退出 0。
   2. 在 `src/shared/crypto.ts` 末尾加一行 `// tamper`。这时 `node --test test/relay-core-sync.test.ts` 应该失败，`--check` 也应该返回非 0。
   3. 用 `git -C <克隆目录> show HEAD:server/src/shared/crypto.ts > <克隆目录>/server/src/shared/crypto.ts` 还原，再跑一遍，两项都应该恢复通过。
5. 写报告 `reports/pi-4-phase2.md`。

**pi-1**（只读审查，不跑 flutter）
1. 用 `git show --stat` 看 pi-3 的 3 个提交，删掉的路径必须和 `delete-list.txt` 完全一致。如果有出入，逐条列出来。
2. 主仓库 5 个副本文件的哈希（先统一成 LF 再算）必须和服务端仓库的 HEAD 一致。
3. `git grep -nE "from '\.\./(db|oauth)/|relay/(api|tenancy|key|show-key|main)\.ts" -- server` 应该没有输出。
4. 在主仓库跑 `cd server && npm run check && npm test`。
5. 写报告 `reports/pi-1-phase2.md`。

**pi-2**（只读审查文档）
1. 主仓库 `README.md` 和 `server/TUNNEL.md` 里，所有指向 `github.com/azurekiln2333/cloudterminal-relay-server/...` 的链接，逐条核对服务端仓库里是否真有这个文件。
2. 服务端仓库文档里，所有提到主仓库的链接和路径（例如 `server/scripts/tunnel-relay.ps1`），逐条核对是否正确。
3. 写报告 `reports/pi-2-phase2.md`。

## 3. 第 3 阶段（用户确认后，由协调者执行）

1. 两个仓库都推送到 `main`。
2. 服务端仓库打 `v0.1.0` 标签，触发镜像发布。
3. 用户在 GitHub 上把镜像包设为公开。
4. 验证不登录就能拉取镜像。

### 2d. 小修（2c 验证发现的问题；按 pi-2 → pi-3 → pi-4 的顺序做，第 0 节和第 2 节的规则照旧）

**pi-2（只改服务端仓库）**
1. 新建 `.gitattributes`，只写一行：`* text=auto eol=lf`。然后运行 `git add --renormalize .`，再运行 `git diff --cached --name-only`，结果必须只有 `.gitattributes`。如果多出别的文件，停下写报告。
2. `test/deployment-image.test.ts` 第 111 行的 `\n` 改成 `\r?\n`。同一个文件里，其他对文件内容做匹配、却只认 `\n` 的正则，也照样改。
3. `README.md` 中，"仓库根目录的 `start.cmd`"和"根目录的 `sh start.sh`"两处，改成"主仓库根目录"。原来的"未发布"等文案不要动，部署测试要用到。
4. 运行 `npm run check && npm test`，结果必须是 119/119。
5. 先跑两条安全检查，然后只做一次提交。
6. 写报告 `reports/pi-2-phase2d.md`，写上新的提交号。

**pi-3（只改主仓库，要等 pi-2 做完）**
1. 根目录 `analysis_options.yaml` 加上 `analyzer: exclude: [apps/**]`，并写一行注释：Windows 助手是独立的包，在它自己的目录里分析。
2. `server/TUNNEL.md` 第 3 行，写明 `Caddyfile` 在 `deploy/` 目录下。
3. 运行 `cd server && node scripts/sync-relay.ts D:/MyNewProjects/cloudterminal-relay-server`，让 `relay-core.json` 记录服务端仓库的新提交号；5 个文件的哈希应该不变。再加 `--check` 跑一次，必须退出码为 0。
4. 运行 `npm run check && npm test`，必须全部通过。这一步不跑 flutter。
5. 先跑两条安全检查，然后只做一次提交。
6. 写报告 `reports/pi-3-phase2d.md`。

**pi-4（要等 pi-3 做完）**：对两个仓库重新做 2c 里 pi-4 的第 1 到 3 步（历史扫描，以及 server 和 main 两种模式的 fresh-clone 测试），然后写报告 `reports/pi-4-phase2d.md`。
