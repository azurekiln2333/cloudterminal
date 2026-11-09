# 实施计划：双入口并存

## 前置

- 任务：`.trellis/tasks/10-13-dual-ingress`
- 用户已定：局域网**默认开启**；填了中继地址就自动同时支持外网；没有二选一提问。
- 范围：`server/src/agent/` 内，加 `server/test/`。relay.ts 与协议不动。

## 有序检查清单

- [ ] 1. `core.ts`：`emit` 单槽位 → `emitters: Set<Emit>`；
      新增 `addEmitter(emit): () => void`（返回注销函数）；
      `setEmitter` 保留为"清空后添加"的兼容语义；
      新增 `fanout(msg, to)`；构造函数改用 `fanout`。
- [ ] 2. `link.ts`：新增 `private detachEmitter?: () => void`；
      `start()` 注册 emitter（幂等）；`stop()` 注销。确认 `emit` 里
      `online`/`readyState` 守卫仍能防止向关闭的 socket 写。
- [ ] 3. `config.ts`：`connectionMode` 保留（读取兼容），但增加
      `localRelayEnabled?: boolean`（默认 true）与
      `remoteRelayEnabled` 的推导，或在 main.ts 内推导，避免模型膨胀。
      原则：旧文件不改也能跑。
- [ ] 4. `setup.ts`：去掉"连接方式 1/2"提问；改为
      `本机端口 [当前]` → `中继地址（留空只用局域网）` → `注册密钥`；
      保留工作目录与共享终端提问。
- [ ] 5. `main.ts`：装配双入口
      - `useLocalRelay = true`（除非 `--no-local-relay`）
      - `useRemoteRelay = relayUrl !== undefined`
      - 端口冲突 → 明确报错退出，不静默换端口
      - 创建 `links: RelayLink[]`，局域网 link + 可选公网 link
      - `printPairing` 逐 link 打印地址；配对码优先走局域网 link
      - 关闭时 `Promise.all(links.map(stop))`
- [ ] 6. `main.ts`：`--no-local-relay` 新参数（逃生阀）+ HELP 文本更新。
- [ ] 7. 新增测试：
      - `core` emitter 扇出与注销；
      - `link` start/stop 的 emitter 生命周期；
      - 旧配置（`connectionMode: 'local'` / `'remote'`）加载后的入口判定；
      - 双 relay 实例集成：agent 同时连接，两边 hello_ok，无 replaced。
- [ ] 8. `server/npm run check`（tsc）。
- [ ] 9. `server/npm test`。
- [ ] 10. `README.md`：把"方式一 / 方式二"改为"局域网默认开启，填中继地址即可同时外网"，
      并说明配对横幅会列出两个地址。
- [ ] 11. 手工验证：启动后确认局域网地址可用；配好中继后确认两个地址都在线。

## 验证命令

```powershell
cd D:\MyNewProjects\cloudterminal\server
npm run check
npm test
```

## 审阅闸口

- 闸口 A（步骤 1-2 后）：emitter 扇出正确且**无泄漏**。确认 `setEmitter` 的
  既有调用点（`core.ts:70` 的 codex，以及所有测试）仍工作。
- 闸口 B（步骤 3-6 后）：旧配置文件无需修改即可启动；单入口行为无回归。
- 闸口 C（步骤 7-9 后）：check + test 全绿。

## 回滚点

任一闸口失败 → `git checkout -- server/src/agent/ server/test/`。

## 明确不做

- 不改 `relay.ts` 的 `entry.socket` 单值语义（跨进程无冲突）。
- 不改协议帧（不新增入口类型上报）。
- 不改手机端与 Windows 客户端。
- 不做多个公网中继。
