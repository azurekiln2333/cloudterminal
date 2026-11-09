# 服务端 compose 自动更新
## Requirements
- `server/compose.yml`、`compose.tls.yml` 加 watchtower 服务(镜像版本固定,不用 latest),relay 加 `com.centurylinklabs.watchtower.enable/scope` 标签
- 轮询间隔、scope 可通过 `.env` 配置(默认 600s),开启 cleanup
- `compose.build.yml` 本地构建场景给 relay 打 `watchtower.enable=false`,避免被覆盖
- `relay-data` 卷在更新中保持
- 更新 `server/README.md`:启用/关闭自动更新的说明
## Acceptance Criteria
- [ ] `docker compose config` 通过(三种组合)
- [ ] 推新镜像后 relay 自动重建,key 与账号数据保留
- [ ] 文档说明 docker.sock 挂载的权限风险
