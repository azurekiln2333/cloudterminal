# 设计：双入口并存（局域网 + 可选公网中继）

## 目标语义

```
config.connectionMode 从 'local' | 'remote'  →  隐式双入口
   局域网中继：总是开启（默认）
   公网中继：  relayUrl 存在就连
```

用户视角：**默认就能用局域网；填了服务器地址就自动多一个外网入口。** 没有模式切换。

## 变更边界

只改 `server/`，**不改协议帧、不改手机端、不改 relay 路由语义**。

| 文件 | 改动 |
| --- | --- |
| `server/src/agent/core.ts` | emitter 单槽位 → 多槽位扇出 |
| `server/src/agent/link.ts` | 增加 link 身份/移除支持；`CLOSE_REPLACED` 处理调整 |
| `server/src/agent/config.ts` | 配置模型：`connectionMode` 保留兼容，新增隐式双入口判定 |
| `server/src/agent/setup.ts` | 向导：去掉二选一，改为"端口 + 可选中继" |
| `server/src/agent/main.ts` | 同时构建 localRelay + 可选 remote link；配对横幅打印两个地址 |
| `server/src/relay/relay.ts` | **不改**（已核实：两个独立 relay 进程间无 agentId 冲突） |
| `server/test/` | 新增多 link 扇出、配置兼容、双入口测试 |

## 关键设计决策

### 1. relay 侧为什么不改

用户场景里两个入口是**两个独立的 relay 实例**：

- 局域网中继 = agent 进程内 `createRelay()`（`main.ts:148`）
- 公网中继 = 服务器上的 Docker 进程

`relay.ts:152` 的 `entry.socket` 单值替换只在**同一个 relay 进程上**同一 agentId
注册两次时触发。跨进程不共享 `agents` Map，所以不会互相踢。
**结论：relay.ts 不动。**

> 例外（记录在案）：若将来有人把公网 relay 和本机 relay 指向同一地址，就会触发
> `CLOSE_REPLACED`。这是既有行为，本任务不引入也不修复。

### 2. AgentCore emitter 扇出

**现状**（`core.ts:64,73`）：

```ts
private emit: Emit = () => {};
setEmitter(emit: Emit): void { this.emit = emit; }   // ← 单槽位，后写覆盖
```

**改为多槽位**：

```ts
private readonly emitters = new Set<Emit>();

addEmitter(emit: Emit): () => void {
  this.emitters.add(emit);
  return () => this.emitters.delete(emit);   // 返回注销函数
}

// 兼容保留：旧的单值语义映射为"替换全部"
setEmitter(emit: Emit): void {
  this.emitters.clear();
  this.emitters.add(emit);
}

private fanout(msg: AgentMessage, to?: string): void {
  for (const emit of this.emitters) emit(msg, to);
}
```

构造函数里 `opts.codex?.setEmitter((m) => this.fanout(m))`。

**为什么用 Set + 返回注销函数**：link 断线/stop 时必须能摘掉自己的 emitter，
否则会向已关闭的 socket 投递。

### 3. RelayLink 生命周期

每个 link 在 `start()` 时注册 emitter，`stop()` 时注销：

```ts
start(): void {
  this.stopped = false;
  this.detachEmitter ??= this.opts.core.addEmitter((msg, to) => this.emit(msg, to));
  this.connect();
}

stop(): void {
  this.stopped = true;
  this.detachEmitter?.();
  this.detachEmitter = undefined;
  ...
}
```

**注意**：`CLOSE_REPLACED`（`link.ts`）当前会让 link 永久停止重连。双入口下
每台 relay 独立，这个分支不会误触发；保留现状即可。

### 4. 配置模型（向后兼容）

保留 `connectionMode` 字段用于读取旧文件，但**运行时不再依赖它做二选一**：

```ts
// 运行时判定
const relayUrl = values.relay ?? process.env.CLOUDTERMINAL_RELAY ?? config.relayUrl;
const useLocalRelay = true;                       // 局域网总是开
const useRemoteRelay = relayUrl !== undefined;    // 有地址就连
```

旧文件迁移：

| 旧配置 | 新行为 |
| --- | --- |
| `connectionMode: 'local'` | 局域网开；`relayUrl` 为空 → 无公网入口（等价旧行为） |
| `connectionMode: 'remote'` + `relayUrl` | 局域网开 + 公网连（**升级**：旧行为是只有公网） |
| 只有 `relayUrl`（更旧） | 同上 |

> `connectionMode: 'remote'` 的旧用户会**多出**一个局域网入口。这是本任务的目的，
> 需要在 README 里说明。

### 5. main.ts 装配

```ts
// 局域网：总是启动
const localRelay = createRelay({ logger: log, relayKey: localRelayKey });
await localRelay.listen(port, '0.0.0.0');          // 端口冲突 → 明确报错退出
const localUrl = `ws://127.0.0.1:${port}/ws`;
const lanUrl = `ws://${lanAddress() ?? 'localhost'}:${port}/ws`;

// 公网：有地址才连
const links: RelayLink[] = [];
links.push(new RelayLink({ url: localUrl, ..., relayKey: localRelayKey }));
if (remoteRelayUrl) {
  links.push(new RelayLink({ url: remoteRelayUrl, ..., relayKey: relayRegistrationKey }));
}
```

**端口冲突**（决策）：`listen` 失败 → 打印明确错误并退出，**不静默换端口**
（静默换端口会让手机里已保存的地址失效）。

### 6. 配对横幅

两个入口都要打印：

```
┌──────────────────── 手机配对 ────────────────────
│ 局域网（同一 Wi-Fi）：ws://192.168.68.78:3731/ws
│ 外网（出门用）：      wss://your.domain/ws
│ 配对码：    YB7E-PNA7   （10 分钟内有效，仅可使用一次）
│
│ 也可手动填写：设备 ID a_xxx
│              密钥见 ~/.cloudterminal/agent.json
└──────────────────────────────────────────────────
```

配对码需要在**每个** link 上分别注册（每个 relay 有自己的 `pairCodes` Map）。
`requestPairCode()` 对每个 online 的 link 各调一次，横幅共用同一个显示码不现实
（两个 relay 的码是不同的），因此：**逐 link 打印各自的码**，或者只对当前
"主" link（优先局域网）请求配对码。

**决策**：优先展示局域网入口的配对码（同 Wi-Fi 场景最常见，且局域网 relay 在
本进程内，必定可用）；公网入口的配对码在其 link online 时单独提示一行。

### 7. 向导

```
本机端口（局域网始终开启）[3731]：
中继地址（留空只用局域网）[]：
注册密钥（回车保留）：
工作目录 [...]：
```

去掉了 `连接方式：1 中继服务器，2 本机局域网` 这一问。

## 兼容性与风险

| 风险 | 处理 |
| --- | --- |
| 旧配置的 remote 用户多出局域网监听 | 符合预期；README 说明；可用 `--no-local-relay` 关掉（新增逃生阀） |
| 端口被占导致启动失败 | 明确报错 + 提示改 `--port`；不静默换 |
| 多 link 重复投递同一 clientId | 每台 relay 的 clientId 空间独立，`to` 路由只在各自 relay 内解析 |
| emitter 泄漏 | `stop()` 注销；测试断言 |
| 重复的 `onOnline` 触发 `printPairing` | `firstOnline` 标志保持"只打一次"，改为对每个 link 独立处理 |

## 验证策略

单测：

1. `core.ts`：`addEmitter` 两个 → 一次 fanout 两个都收到；注销一个 → 只剩一个。
2. `link.ts`：`start()` 注册 / `stop()` 注销 emitter（无泄漏）。
3. `config.ts`：旧 `connectionMode: 'local'/'remote'` 文件加载后，双入口判定正确。
4. 集成：两个 relay 实例（不同端口），agent 同时连 → 两边都收到 `hello_ok`，
   都不产生 `replaced`；客户端各自能收发。

手工：启动后确认两个地址都能配对（局域网 + 公网）。

## 回滚

改动集中在 `server/src/agent/`，无协议与持久化破坏性变更。`git revert` 即回滚。
