---
name: l4d2-cfg-mount-pitfall
description: Docker volume 挂载 cfg 目录覆盖了镜像默认的 valve.rc 等引擎必需文件导致服务器卡死
metadata: 
  node_type: memory
  type: feedback
  tags: 
    - l4d2
    - docker
    - cfg
    - valve.rc
    - pitfall
  originSessionId: 4b3417fe-a874-420c-b976-80f0ddfa0c75
---

# L4D2 Docker：挂载 cfg 目录覆盖引擎必需文件

## 现象
- 服务器启动后卡在 "Server is hibernating"，永不唤醒
- `docker logs` 显示 `Game_srv.so loaded` 后无任何进展
- **RCON 认证失败**（`rcon_password` 在 `server.cfg` 中但 `valve.rc` 未执行它）
- 不挂载 cfg 目录时服务器正常启动
- 挂载空 cfg 目录也会卡死（表现相同）

## 根因
`jackzmc/srcds-l4d2:master` 镜像的 `/server/left4dead2/cfg/` 目录包含 **46 个引擎必需文件**

> **2026-07-25 已迁移到 `left4devops/l4d2`（内部路径 `/home/louis/l4d2/left4dead2/`，cfg 为 `/cfg` symlink），详见 [[l4d2-docker-migration]]。**：
- `valve.rc` — Source 引擎初始化脚本，启动时自动执行
- `config_default.cfg` — 默认配置
- `moddefaults.txt` — 模组默认值（391KB）
- 各种硬件配置 `.ekv` 文件、`settings_default.scr` 等

用 Docker volume 挂载我们的 `cfg/` 目录时，**整个镜像内 cfg 目录被替换**，`valve.rc` 等文件丢失。Source 引擎启动时找不到 `valve.rc`，初始化流程中断，游戏 DLL 加载后无法继续，永远卡在休眠状态。

**Why:** 之前在其他服务器上没踩这个坑，可能是因为用了 SteamCMD 手动下载服务端（cfg 文件在宿主机上生成），而非这种游戏文件内置在镜像里的方案。

**How to apply:**
1. 部署前先从镜像提取默认 cfg 文件：
   ```bash
   docker run --rm --entrypoint "" jackzmc/srcds-l4d2:master \
     tar czf - -C /server/left4dead2 cfg > default-cfg.tar.gz
   ```
2. 合并到我们的 cfg 目录（不覆盖已有文件）：
   ```bash
   tar xzf default-cfg.tar.gz -C /opt/gameservers/l4d2/data/ --keep-old-files
   ```
3. 确认 `valve.rc` 存在后再启动服务器

## 关联
- [[l4d2-permissions-pitfall]] — 文件权限 700
- [[l4d2-32bit-architecture-pitfall]] — 32 位架构
- [[l4d2-mysql-blocking]] — MySQL 驱动卡死
- [[l4d2-deployment-rules]] — 综合踩坑清单
