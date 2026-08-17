---
name: l4d2-32bit-architecture-pitfall
description: L4D2 Docker 镜像 srcds_linux 是 32 位二进制，所有插件必须用 32 位，metamod_x64.vdf 必须删除
metadata: 
  node_type: memory
  type: feedback
  tags: 
    - l4d2
    - docker
    - 32bit
    - architecture
    - pitfall
  originSessionId: 4b3417fe-a874-420c-b976-80f0ddfa0c75
---

# L4D2 32位架构兼容性坑

## 现象
- MetaMod 日志中出现: `wrong ELF class: ELFCLASS64`
- `Unable to load plugin "addons/metamod/bin/linux64/server"`
- 服务器可能仍然启动（MetaMod 失败非致命），但 L4DToolZ/多人生效不了

## 根因
`jackzmc/srcds-l4d2:master` 镜像中的 `srcds_linux` 是 **32 位 ELF**（`ELF 32-bit LSB executable, Intel 80386`），不是 64 位。

> **2026-07-25 已迁移到 `left4devops/l4d2`，详见 [[l4d2-docker-migration]]。32 位问题视新镜像而定。**

但插件包里同时包含了：
- `addons/metamod/bin/server.so` — 32 位 ✅ 
- `addons/metamod/bin/linux64/server.so` — 64 位 ❌
- `addons/metamod.vdf` — 指向 32 位 `addons/metamod/bin/server`
- `addons/metamod_x64.vdf` — 指向 64 位 `addons/metamod/bin/linux64/server`

Source 引擎会尝试加载所有 `.vdf` 文件，`metamod_x64.vdf` 加载 64 位 .so 时失败。

**Why:** L4D2 官方服务端一直是 32 位编译的，Valve 从未发布 64 位版本。Docker 镜像保留了这个架构。插件包从社区下载时通常同时包含 32/64 位版本以兼容不同游戏。

**How to apply:**
1. 部署后删除所有 x64 VDF: `rm -f /opt/gameservers/l4d2/data/addons/metamod_x64.vdf`
2. 验证 srcds_linux 架构: `file /server/srcds_linux`（容器内）
3. 验证插件架构: `file addons/metamod/bin/server.so` — 必须是 32-bit
4. 如果要安装新插件，永远下载 32 位 (.i486 / _i486) 版本

## 关联
- [[l4d2-permissions-pitfall]] — 另一个同时踩的坑（文件权限 700）
- [[game-server-deployment-plan]] — 整体部署
