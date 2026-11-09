# 设计：拆分仓库

## 1. 仓库边界

**主仓库 `cloudterminal`（原地保留）**
- Flutter 端：`lib/` `test/` `android/` `ios/` `ohos/` `web/` `linux/` `macos/` `windows/` `third_party/`
- `apps/cloudterminal_windows/`
- `server/` 里的电脑端 agent：`src/agent/**`、`src/shared/{protocol,pairing}.ts`、`scripts/**`、agent 相关测试
- 中继核心副本（见 §3）
- `start.*`、`README.md`、`.trellis/`、各 AI 工具配置

**服务端仓库 `cloudterminal-relay-server`（本机路径 `D:\MyNewProjects\cloudterminal-relay-server`）**
- `src/relay/{relay,api,tenancy,key,show-key,main}.ts`
- `src/db/**`、`src/oauth/**`
- `src/shared/{relay-protocol,protocol-account,crypto,log}.ts`
- `Dockerfile`、`.dockerignore`、`.env.example`、`compose*.yml`、`deploy/**`
- `.github/workflows/image.yml`、`.cnb.yml`
- `README.md`（来自 `server/README.md`）
- 测试（见 §6）

**`server/` 目录不改名。** Windows 助手（`apps/cloudterminal_windows/lib/main.dart:60-75`）、Flutter 集成测试、`start.*` 都按这个路径找 agent。

## 2. 中继核心与账号层解耦

现状：`relay.ts:17-18` 引入 `tenancy.ts`，`tenancy.ts:12-13` 在运行时又引入 `db/`。

改法：
- 在 `relay.ts` 里定义 relay 自己需要的最小接口，不再 import tenancy 或 db：
  ```ts
  export type AccountClientResult =
    | { ok: true; accountId: string }
    | { ok: false; reason: 'no_database' | 'invalid_token' | 'not_bound' | 'unavailable' };
  export type AccountAuthorizer = {
    readonly available: boolean;
    authorizeClient(token: string, deviceId: string): Promise<AccountClientResult>;
    invalidate(accountId: string, deviceId: string): void;
  };
  ```
- `RelayOptions` 删掉 `db`、`bindingCacheMs`，新增 `accounts?: AccountAuthorizer`。
  不传时用内置的"未启用"实现：`available=false`，`authorizeClient` 返回 `{ok:false, reason:'no_database'}`，`invalidate` 什么都不做。
  这与现在 `db=null` 时的行为一字不差：账号客户端收到 `account_unavailable`。
- `tenancy.ts` 改为 `import type { AccountAuthorizer, AccountClientResult } from './relay.ts'`，`createTenancy` 的返回值满足 `AccountAuthorizer`；`boundAccounts`、`stats` 保留。
- `relay/main.ts` 改为 `createRelay({ relayKey, accounts: createTenancy({ pool: db, logger: log }), logger: log })`。
- 测试辅助 `startRelay`：服务端仓库的版本接受 `{ db, bindingCacheMs }`，在内部组装 tenancy；主仓库的版本去掉 db。
- 对外行为（握手、错误码、日志字段）一律不变。

## 3. 中继核心副本 + 一致性检查

**副本文件（以服务端仓库为准）**：
- `src/relay/relay.ts`
- `src/shared/relay-protocol.ts`
- `src/shared/protocol-account.ts`
- `src/shared/crypto.ts`
- `src/shared/log.ts`

在主仓库里，它们位于 `server/` 下的同名路径，agent 的 import 路径不变。

**校验文件 `server/relay-core.json`（主仓库）**：
```json
{ "source": "https://github.com/azurekiln2333/cloudterminal-relay-server",
  "commit": "<服务端仓库提交>",
  "files": { "src/relay/relay.ts": "<sha256>", "...": "..." } }
```
- sha256 先把 CRLF 换成 LF 再算，避免 Windows 和 Linux 换行不同导致误报。参考命令：
  `node -e "const fs=require('fs'),c=require('crypto');for(const f of process.argv.slice(1))console.log(c.createHash('sha256').update(fs.readFileSync(f,'utf8').replace(/\r\n/g,'\n')).digest('hex'),f)" <files>`

**检查 `server/test/relay-core-sync.test.ts`**：重算哈希并与 `relay-core.json` 比对，不一致就失败。报错信息要说明正确做法：先改服务端仓库，再运行同步脚本。

**同步脚本 `server/scripts/sync-relay.ts <服务端仓库目录>`**（主仓库）：
- 默认：复制这 5 个文件，并重写 `relay-core.json`（写入 `git -C <dir> rev-parse HEAD` 和哈希）。
- `--check`：只比对、不写入，不一致时退出码非 0。
- `server/package.json` 加 `"sync-relay"` 脚本。

## 4. 协议文件拆分

`server/src/shared/protocol.ts` 的第 7 行（`MAX_FRAME_BYTES`）和"Relay envelope"区段（约第 9–77 行），移到新文件 `shared/relay-protocol.ts`，包括：
- `AgentHello` / `ClientHello` / `PairHello` / `Hello`
- `PAIR_CODE_*`、`normalizePairCode`
- `RelayErrorCode`、`RelayFrame`

主仓库的 `protocol.ts` 删掉这些定义，改为 `export * from './relay-protocol.ts'`。其余内容不动，Dart 镜像也不动。

服务端仓库只有 `relay-protocol.ts`，没有完整的 `protocol.ts`。

动手前先确认这个区段不引用区段外的东西（例如 `PROTOCOL_VERSION`）。如果有引用，就一起移过去。

## 5. CI 与镜像

- 服务端仓库根目录就是原来的 `server/`：
  - `image.yml`、`.cnb.yml` 里的 `server/` 前缀全部去掉（构建上下文改为 `.`，静态检查改为 `node --test test/deployment-image.test.ts`）。
  - `deployment-image.test.ts:21-22` 的目录推算也跟着改。
- 镜像名：GitHub 侧默认取 `github.repository`，即 `ghcr.io/azurekiln2333/cloudterminal-relay-server`，不需要设置变量。
- `compose.yml`、`compose.tls.yml`、`.env.example`、`README.md` 里的默认 `RELAY_IMAGE`，改为 `ghcr.io/azurekiln2333/cloudterminal-relay-server:latest`。
- 文档里继续写明"首次 CI 发布之前，镜像并不存在"，要让 `docs never claim an unpublished image exists` 用例通过。
- `.cnb.yml` 只改路径，保留备用。
- `deploy/relay/package.json` 的去留不在本任务范围内，原样保留。

## 6. 测试归属

**服务端仓库**
- `relay`、`relay-api`、`relay-tenancy`、`db-*`、`oauth-*`、`deployment-image` 这几组测试
- `helpers.ts`、`fake-db.ts`、`db-helpers.ts`
- 新文件 `relay-startup.test.ts`：来自 `deployment.test.ts:109` 的用例
- 新文件 `relay-key.test.ts`：来自 `setup.test.ts:74` 的用例

**主仓库**
- 其余测试
- `relay.test.ts` 也保留一份，用来测主仓库里的中继核心副本
- `deployment.test.ts` 只留第 49、92 行两个 agent 用例
- `setup.test.ts` 去掉第 74 行的用例
- `herdr.test.ts:970`：fixture 目录不存在时跳过，并写明原因
- 新增 `relay-core-sync.test.ts`

拆完之后，服务端仓库里执行 `grep -rn "src/agent" src test` 必须没有任何结果。

## 7. 签名材料与本地文件

| 对象 | 处理方式 | 是否进提交 |
|---|---|---|
| `.signing/` | 写进 `.gitignore` | 否 |
| `*.pid` | 写进 `.gitignore` | 否 |
| `ohos/build-profile.json5` | 执行 `git update-index --skip-worktree`。本机文件保留签名配置，能照常签名打包；提交里仍是 HEAD 的 `signingConfigs: []` | 否 |
| `server/{ansi,check-herdr,hold}.cjs`（本机调试脚本） | 写进 `.git/info/exclude`，文件不动 | 否 |
| `ohos/.../rawfile/buildinfo.json5`（8 行，无敏感内容） | 跟 ohos 改动一起提交 | 是 |

## 8. 历史

- 主仓库保留完整历史。已扫描过，不含密钥。
- 服务端仓库全新开始：一个初始提交，提交信息里注明来源（主仓库的提交号）。

## 9. 兼容性与回滚

**兼容性**
- 手机协议、局域网入口、Windows 助手路径、`start.*` 的行为全部不变。

**回滚**
- 动手前先备份 `D:\MyNewProjects\_backups\cloudterminal-*.tar.gz`。
- 所有改动都是本地提交，推送前都能撤回。
- 推送需要用户确认后才做（第 3 阶段）。

## 10. 第 1 阶段核对后的决定（2026-11-09，优先于前文）

依据是 `reports/pi-*-phase1.md`。以下已经定了，第 2 阶段照做，不要再改：

1. **协议文件**
   - `relay-protocol.ts` 包含 `RelayFrame`，其中两处 `data` 用 `unknown`：中继不解析载荷，而且 `RelayFrame` 目前没有任何地方在用。
   - 主仓库的 `protocol.ts` 删掉整个区段（包括 `RelayFrame`），在原位置写 `export * from './relay-protocol.ts';`。
   - `PROTOCOL_VERSION` 留在 `protocol.ts`。
2. **`tenancy.ts`** 不再自己定义 `AccountClient*` 类型，改为从 `relay.ts` 导入。服务端仓库已经改好。
3. **`test/helpers.ts`**：主仓库的不动；服务端仓库的那份接收 `{ db, bindingCacheMs }`，在内部组装 tenancy。服务端仓库已经改好。
4. **`TUNNEL.md` 两边都留**
   - 服务端仓库保留完整版，因为它的部署测试会读这个文件。
   - 主仓库用 pi-3 的草稿：开头写明两个仓库各管什么，链接改到服务端仓库。
5. **`server/deploy/`** 从主仓库整个删除。
6. **主仓库 `server/package.json`** 删掉 `relay` 脚本和 `mysql2`。电脑上的局域网入口不受影响；公网中继改到服务端仓库启动。
7. **`herdr.test.ts:970`**：fixture 不存在时跳过，因为 `.build/` 不提交。录制的 fixture 里有本机路径，不放进仓库。
8. **服务端仓库首个提交的说明**改为 `split from cloudterminal@927fc25`，因为复制的内容来自这个提交。
9. **暂不处理**：不加 `.gitattributes`，因为一致性检查本来就会先统一换行。`deploy/relay/package.json` 与仓库根目录的 `package.json` 先并存，暂不合并。
10. **其他**：`deployment-image.test.ts` 只改第 22 行的 `repoDir`。README 里 CNB 的示例写成 `docker.cnb.cool/azurekiln/cloudterminal-relay-server:<tag>`。这两项服务端仓库都已改好。
