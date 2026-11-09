# pi-2 第 2 阶段（2c）报告：只读核对文档链接

## 结论

**完成（纯只读）。** 核对结果：**没有断链，没有指向不存在文件的引用**。发现 2 处措辞/可验证性问题（都不算错误、无需改文件），见「发现的问题」。

两个仓库都没有修改：主仓库 `beed231`（`git status --short` 仍只有 `?? .trellis/tasks/11-09-repo-split/`），服务端仓库 `fcd073d`（`git status --short` 无输出）。没有 push，没有运行 `task.py`，没有跑 flutter。

## 做了什么

### 第 1 步：主仓库 `README.md` + `server/TUNNEL.md` 里指向服务端仓库的链接

用正则枚举 `https?://github.com/azurekiln2333/cloudterminal-relay-server[^\s)"'\]>]*`，全部命中如下（共 5 处）：

| 文件:行 | URL | 指向 | 服务端仓库里是否存在 |
| --- | --- | --- | --- |
| `README.md:14` | `…/cloudterminal-relay-server` | 仓库主页 | ✅ 是本地同名仓库（`fcd073d`） |
| `README.md:77` | `…/cloudterminal-relay-server` | 仓库主页 | ✅ 同上 |
| `README.md:77` | `…/cloudterminal-relay-server#readme` | 仓库主页 README 锚点 | ✅ 根目录有 `README.md` |
| `server/TUNNEL.md:3` | `…/cloudterminal-relay-server` | 仓库主页 | ✅ 同上 |
| `server/TUNNEL.md:31` | `…/cloudterminal-relay-server` | `git clone` 用 | ✅ 同上 |

**没有任何带文件路径的链接**（不存在 `…/blob/main/…` 或 `…/tree/main/…` 形态），所以不存在「链接指向的目录/文件在服务端仓库里不存在」这一类断链。`#readme` 是 GitHub 对根 `README.md` 的默认锚点，服务端仓库根目录确实有 `README.md`。

同时核对了这些链接所在段落的**实质内容**（链接文字背后的文件清单），逐条对照服务端仓库根目录：

| 文档里的说法 | 实际 | 结论 |
| --- | --- | --- |
| 镜像与 GitHub Actions 发布在服务端仓库 | `.github/workflows/image.yml`、`.cnb.yml` 均存在 | ✅ |
| `compose.yml` / `compose.tls.yml` 在服务端仓库 | 两个文件都在根目录 | ✅ |
| `.env.example` | 在根目录 | ✅ |
| Caddy 配置 | `deploy/Caddyfile` 存在 | ✅ |
| 账号与数据库说明 | 服务端 `README.md` §7「可选账号层（OAuth2 + MySQL）」存在；`src/db/migrate.ts` 存在 | ✅ |
| 升级和排障说明 | 服务端 `README.md` §8「查看状态、升级和切换入口」、§9「数据和排障」存在 | ✅ |
| 主仓库只保留中继核心副本 `server/src/relay/relay.ts` + `server/src/shared/{relay-protocol,protocol-account,crypto,log}.ts` | 主仓库 `server/src/relay/` 只有 `relay.ts`；`server/src/shared/` 有这 4 个文件（另有 `protocol.ts`、`pairing.ts`，属 Agent 侧，说法里没排除它们，不算错） | ✅ |
| `npm run sync-relay -- <服务端仓库目录>` | 主仓库 `server/package.json` 有 `"sync-relay": "node scripts/sync-relay.ts"` | ✅ |
| `server` 的 `npm test` 会校验副本一致性 | `server/test/relay-core-sync.test.ts` 与 `server/relay-core.json` 都在 | ✅ |
| `server/TUNNEL.md` 相对链接 | 主仓库该文件存在 | ✅ |

TUNNEL.md 里对服务端仓库文件的引用也都对得上：`compose.tls.yml`、`compose.build.yml`、`.env.example`、`deploy/Caddyfile`、`docker compose … exec relay node src/relay/show-key.ts`（`src/relay/show-key.ts` 存在）、`RELAY_TRUST_PROXY=1`（`compose.tls.yml:23` 确有）、`RELAY_IMAGE`（`.env.example:21`）、`RELAY_PORT`（`.env.example:24`、`compose.yml`）、`.env` 里的 `RELAY_DOMAIN`（`.env.example:10`），以及「服务端仓库 README 的『局域网 / VPN 部署』」→ 服务端 `README.md` §4「局域网 / VPN 部署：不需要域名」。全部 ✅。

另外确认这两个文件里**已经没有**指向已删除文件的链接（`server/README.md`、`server/compose*`、`server/Dockerfile`、`server/deploy`、`.github/`、`.cnb.yml`）：`Select-String` 无命中。✅

### 第 2 步（对应 implement.md 的 pi-2 第 2 步）：服务端仓库文档里提到主仓库的链接和路径

| 文件:行 | 提到的主仓库对象 | 核对结果 |
| --- | --- | --- |
| `README.md:3` | `https://github.com/azurekiln2333/cloudterminal`（主仓库） | ✅ 无路径后缀，写法与 design.md 一致 |
| `README.md:103`、`107` | 「双击**仓库根目录**的 `start.cmd`」「`start.cmd --setup`」 | ⚠️ 文件存在、参数可用（见下），但「仓库根目录」在服务端仓库语境下有歧义 — 见「发现的问题 1」 |
| `README.md:109` | 「根目录的 `sh start.sh`」 | ✅ 主仓库根目录有 `start.sh` |
| `README.md:109` | `%USERPROFILE%\.cloudterminal\agent.json`（或 `CLOUDTERMINAL_HOME`） | ✅ 与主仓库 `server/src/agent/config.ts:24,28` 一致（`CLOUDTERMINAL_HOME` 或 `homedir()/.cloudterminal`，文件名 `agent.json`） |
| `README.md:125` | 「也就是原来的 `server/` 目录」 | ✅ 历史说明，正确 |
| `TUNNEL.md:3` | 服务端仓库 README + 「`compose*.yml`、`.env.example`、`deploy/Caddyfile` 都在那个仓库的根目录」 | ✅ 文件都在；措辞上 `deploy/Caddyfile` 严格说在 `deploy/` 子目录，但句子给了完整相对路径 — 见「发现的问题 2」 |
| `TUNNEL.md:86`、`89` | 主仓库 + `pwsh -File server/scripts/tunnel-relay.ps1` | ✅ 主仓库有 `server/scripts/tunnel-relay.ps1`，位于 `server/` 下，路径正确 |
| `TUNNEL.md:7` | 「`server/scripts/tunnel-relay.ps1` 会以 `--local-relay` 模式启动 Agent」 | ✅ 脚本第 129 行 `node src/agent/main.ts --local-relay`；主仓库 `server/src/agent/main.ts` 确实支持 `--local-relay` |

顺带确认：服务端文档里**没有**残留 `../` 形式的跨仓库相对引用（第 1 阶段我改过的 `.env.example` / `compose.yml` 现在是 `.cnb.yml`、`.github/workflows/image.yml`），`README.md`/`TUNNEL.md`/`.env.example`/`compose*.yml` 里 `../` 命中数为 0。✅

## 关键命令和结果

```
# 枚举指向服务端仓库的 URL
README.md       -> https://github.com/azurekiln2333/cloudterminal-relay-server   (×2)
README.md       -> https://github.com/azurekiln2333/cloudterminal-relay-server#readme
server\TUNNEL.md -> https://github.com/azurekiln2333/cloudterminal-relay-server  (×2)

# 主仓库里是否还有指向已删文件的链接（应为空）
Select-String README.md, server\TUNNEL.md -Pattern "server/README\.md|server/compose|server/Dockerfile|server/deploy|\.github/|\.cnb\.yml"
（无输出）

# 服务端仓库根目录
.cnb.yml .dockerignore .env.example .github .gitignore compose.build.yml compose.tls.yml
compose.yml deploy Dockerfile node_modules package-lock.json package.json README.md src test
tsconfig.json TUNNEL.md
deploy/ -> Caddyfile, relay/{package.json,package-lock.json}
src/relay/ -> api.ts key.ts main.ts relay.ts show-key.ts tenancy.ts

# 主仓库 side
server/src/relay/ -> relay.ts（只剩这一个）
server/src/shared/ -> crypto.ts log.ts pairing.ts protocol-account.ts protocol.ts relay-protocol.ts
server/scripts/ -> demo-agent.ts e2e.ts herdr-smoke.ts sync-relay.ts tunnel-relay.ps1
server/package.json scripts -> agent, check, test, e2e, demo, sync-relay（无 relay 脚本）
server/package.json deps -> @anthropic-ai/claude-agent-sdk, node-pty, ws（无 mysql2）
start*.cmd/sh -> start-windows.cmd, start.cmd, start.sh

# 服务端 README 章节
1 先把镜像准备好 / 2 服务器上需要哪些文件 / 3 公网部署 / 4 局域网 / VPN 部署 / 5 Windows 和手机连接
6 本地构建 / 7 可选账号层 / 8 查看状态、升级和切换入口 / 9 数据和排障 / 10 验证状态

# .env.example 关键变量
RELAY_DOMAIN=relay.example.com
RELAY_IMAGE=ghcr.io/azurekiln2333/cloudterminal-relay-server:latest
RELAY_PORT=8787
RELAY_LOCAL_IMAGE=cloudterminal-relay:local

# compose.tls.yml:23  RELAY_TRUST_PROXY: "1"
# compose.build.yml   context: . / dockerfile: Dockerfile

# 跨仓库相对引用残留（应为空）
Select-String README.md,TUNNEL.md,.env.example,compose*.yml -Pattern '\.\./'
（无输出）

# start.cmd 透传参数（支持 --setup）
node src/agent/main.ts %*
```

## 发现的问题

两处都**不是断链**，属于文案可读性/可验证性问题，本次只读不动手。

1. **服务端 `README.md:103`「双击仓库根目录的 `start.cmd`」有歧义。**
   在服务端仓库里读这句话，「仓库根目录」会被理解成**本仓库**根目录，但本仓库没有 `start.cmd`（`start.cmd` 在主仓库根目录）。上一句「Windows 电脑仍使用完整项目中的根目录启动器」勉强能消歧，但第 1 步单独看会误导。建议改成「双击**主仓库**根目录的 `start.cmd`」，同段 `sh start.sh` 也一样。这是第 1 阶段我从主仓库整体复制过来的原有措辞，不是新引入的错误。

2. **主仓库 `server/TUNNEL.md:3`「`compose*.yml`、`.env.example`、`deploy/Caddyfile` 也都在那个仓库的根目录」。**
   `compose*.yml` 和 `.env.example` 确实在根目录，`deploy/Caddyfile` 在 `deploy/` 子目录。句子给了完整相对路径，读者不会走错，只是「都在根目录」这个说法不够准确。可改成「都在那个仓库里（`deploy/Caddyfile` 在 `deploy/` 下）」。

3. **链接的存在性只能离线核到「本地有同名仓库」。**
   两个仓库都**没有配置 remote**（主仓库 `git remote -v` 空，服务端仓库也空），所以 5 个 `github.com/azurekiln2333/…` URL 是否真的可达、仓库是否已建、是否公开，**离线无法验证**。我能确认的是：URL 里的 owner/repo 与 design.md 一致、URL 形态是仓库主页、`#readme` 锚点对应的文件在服务端仓库根目录存在。按第 2 阶段的规则我没有访问 GitHub。等第 3 阶段推送后，这几条链接才会真正生效。

## 需要协调者决定的事

1. 上面「发现的问题 1、2」要不要修。如果修，需要派活（本次是只读任务，我没动文件）；两处都只改 1 行文案。
2. 第 3 阶段推送后，如果需要「链接确实可达」的验证，得有人联网点一遍（我按规则没有访问 GitHub / CNB）。
