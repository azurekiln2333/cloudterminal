# 三端接入账号登录与绑定
前置:无。后续 pairing-simplify、ux-unify 依赖本任务。

## Requirements
### 服务端(relay)
- 新增 relay 托管的 OAuth 回调页:`OAUTH_REDIRECT_URI` 指向 relay 自己(如 `https://<relay>/api/v1/auth/oauth/callback`),relay 在服务端完成换码
- 新增按 `state` 轮询结果的接口,客户端发起登录后轮询拿 relay 凭据;复用 `ct_oauth_states` 一次性、带过期
- 客户端无需自定义 URL scheme(兼容鸿蒙、Windows、浏览器)
- OAuth 客户端信息只来自 `.env`,不写死、不由本任务注册

### 电脑端(agent 本机 Web 绑定页)
- agent 启动时在 `127.0.0.1` 起本机 Web 页并自动打开浏览器
- 页面:当前账号/绑定状态、“登录并绑定本机”、已绑定账号列表(可解绑)、手机备用二维码 + 短码
- 绑定由本机 agent 用设备凭据向 relay 证明同意(等价 pair_code 同意),用户无需输码
- 只监听回环地址;Windows Flutter 助手可直接嵌入/打开该页,不重复实现

### 手机端
- “登录”按钮 → 系统浏览器打开 `authorize_url` → 轮询 → 拿到凭据
- 登录后拉 `/api/v1/devices` 显示“我的电脑”(在线状态),点击连接
- 凭据安全存储,支持刷新、退出登录
- 保留旧设备密钥配对

## Acceptance Criteria
- [ ] 电脑启动服务 → 浏览器出现绑定页 → 登录一次即绑定成功
- [ ] 手机登录同一账号 → 列表出现该电脑 → 进入会话;全程不输地址/密钥/码
- [ ] 登录超时、取消、令牌过期、relay 未配置 OAuth 均有明确提示
- [ ] Node 与 Dart 测试通过
