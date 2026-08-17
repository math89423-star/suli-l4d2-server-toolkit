---
name: l4d2-docker-migration
description: 2026-07-25 从 jackzmc 迁移到 left4devops Docker 镜像，解决 Steam 认证问题
metadata: 
  node_type: memory
  type: project
  originSessionId: 76ffb1c9-b2a3-41ee-930c-fd0eb40908ba
---

# L4D2 Docker 镜像迁移

**迁移日期**: 2026-07-25
**原因**: `jackzmc/srcds-l4d2:master` 镜像不支持 `sv_setsteamaccount`，导致 "No Steam logon" 玩家被踢。

## 新旧对照

| 项目 | 旧 (jackzmc) | 新 (left4devops) |
|------|-------------|-------------------|
| 镜像 | `jackzmc/srcds-l4d2:master` | `left4devops/l4d2:latest` |
| 用户 | steam | louis (uid=1000) |
| 服务器根目录 | `/server/left4dead2/` | `/home/louis/l4d2/left4dead2/` |
| addons 挂载 | `/server/left4dead2/addons` | `/addons`（内部 symlink → `left4dead2/addons`） |
| cfg 挂载 | `/server/left4dead2/cfg` | `/cfg`（内部 symlink → `left4dead2/cfg`） |
| 其他挂载 | `/server/left4dead2/maps` 等 | `/home/louis/l4d2/left4dead2/maps` 等 |
| Steam 更新 | 无 | ✅ 每次启动 steamcmd 自动更新 |
| GSLT | ❌ Unknown command | ✅ `sv_setsteamaccount` 在 server.cfg 正常执行 |
| 启动方式 | `./srcds_linux` | `./entrypoint.sh` → `steamcmd` 更新 → `./srcds_run` |

## 配置文件

`/opt/gameservers/l4d2/docker-compose.yml`

## GSLT Token

位于 `data/cfg/server.cfg`：
```
sv_setsteamaccount C68C39492F159F9DB6B536BA121E04CC
```

## 注意事项

- 首次启动 steamcmd 下载约 40MB，需要 5-10 分钟
- 后续启动只需增量更新，秒级完成
- 所有 `data/` 下文件权限 644/755，uid=1000 可读

## GSLT 重要结论

**L4D2 引擎不支持 `sv_setsteamaccount`** — 这是 CS:GO/TF2 时代的 GSLT 机制，从未移植回 L4D2。
- 旧 jackzmc 的 "No Steam logon" 是其内嵌 Steam 客户端认证失败，与 GSLT 无关
- left4devops 镜像的 Steam 客户端正常工作，玩家可直接通过 Steam 浏览器或 `connect` 加入
- `server.cfg` 中已删除无效的 `sv_setsteamaccount` 行

## 关联记忆

- [[l4d2-deployment-guide]] — 完整部署指南
- [[l4d2-server-quick-reference]] — 日常管理
