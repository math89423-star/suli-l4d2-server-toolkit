---
name: l4d2-permissions-pitfall
description: L4D2 Docker 部署时插件文件权限导致 MetaMod/SourceMod 无法加载的坑
metadata: 
  node_type: memory
  type: feedback
  tags: 
    - l4d2
    - docker
    - permissions
    - pitfall
  originSessionId: 4b3417fe-a874-420c-b976-80f0ddfa0c75
---

# L4D2 Docker 部署：插件文件权限坑

## 现象
- 服务器启动后卡在 "Server is hibernating"，地图不加载
- `docker logs` 看不到 MetaMod/SourceMod/L4DToolZ 的任何输出
- A2S 查询无响应
- 干净容器（不挂载 addons）能正常运行

## 根因
`jackzmc/srcds-l4d2:master` 容器以 **`steam` 用户（UID 1003）** 运行，而不是 root。

> **2026-07-25 已迁移到 `left4devops/l4d2`，用户变为 `louis`(UID 1000)。详见 [[l4d2-docker-migration]]。以下内容为旧镜像历史记录。**

从旧服务器迁移来的插件包中，所有文件权限是 `700`（`rwx------`），owner 是 `root:root`。

Docker bind mount 保留宿主机文件的 UID/GID 和权限位，所以容器内的 `steam` 用户：
- **无法读取** addons 下的 `.so` / `.vdf` / `.smx` 等文件
- MetaMod 尝试 `dlopen()` 时报 "File not found"（实际上是 Permission denied 的误导信息）

**Why:** 从别的服务器打 tar 包时保留了原始权限（可能是 root 700），解压后没有检查。

**How to apply:**
1. 部署插件后 **立即** 执行: `chmod -R 755 /opt/gameservers/l4d2/data/addons/`
2. 任何从外部迁移来的游戏服务器文件，挂载到 Docker 前都要检查容器运行用户和文件权限
3. 排查此类问题时，用 `--user <容器UID>` 运行临时容器测试文件可读性：
   ```bash
   docker run --rm -v /host/path:/data --user 1003 --entrypoint "" image sh -c "cat /data/file > /dev/null && echo OK || echo DENIED"
   ```

## 关联
- [[game-server-deployment-plan]] — 整体部署计划
- [[game-server-port-allocation]] — 端口分配
