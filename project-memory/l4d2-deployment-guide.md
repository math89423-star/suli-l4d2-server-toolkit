---
name: l4d2-deployment-guide
description: L4D2 服务器在新机器上的完整部署步骤
metadata: 
  node_type: memory
  type: reference
  tags: 
    - l4d2
    - deployment
    - docker
  originSessionId: 9fe91733-b145-4a63-a08a-afa3f9c3a97d
---

# L4D2 服务器部署指南

> 在新服务器上从零部署 L4D2 的完整步骤。

## 前提

- Docker + Docker Compose
- 防火墙 UDP: `26900, 27005, 27015, 27020` + TCP: `27015` (RCON)
- 插件包 `/tmp/l4d2-plugin-pack.tar.gz`（由 `[[l4d2-plugin-pack]]` 脚本生成）

## 部署步骤

```bash
# 1. 创建目录
mkdir -p /opt/gameservers/l4d2/data/maps/{maps,missions,scripts}

# 2. 解压插件包
cd /opt/gameservers/l4d2
tar xzf /tmp/l4d2-plugin-pack.tar.gz

# 3. 修改 docker-compose.yml 里的 hostname 和 server.cfg

# 4. 构建 admin panel 镜像（含 steamcmd）
docker compose build l4d2-admin

# 5. 启动
docker compose up -d
```

## 部署参数

| 参数 | 值 |
|------|-----|
| 镜像 | `left4devops/l4d2:latest`（2026-07-25 从 `jackzmc/srcds-l4d2:master` 迁移） |
| 网络 | `host`（不可协商，Docker NAT 会导致 Steam 列表显示内网 IP） |
| Tickrate | 60 |
| 人数 | 16 |
| 难度 | Hard |
| 时区 | `Asia/Shanghai` |
| 重启策略 | `unless-stopped` |
| 默认地图 | `c1m1_hotel` |
| RCON | `27015` |

## 目录结构

```
/opt/gameservers/l4d2/
├── docker-compose.yml
├── l4d2-switch-map.sh         # 换图脚本（位于 /home/ubuntu/）
├── data/
│   ├── addons/                # metamod + sourcemod + l4dtoolz + VPK
│   │   ├── metamod.vdf
│   │   ├── l4dtoolz.vdf
│   │   ├── *.vpk              # 三方地图
│   │   └── sourcemod/
│   │       ├── plugins/       # 71 个 .smx
│   │       ├── extensions/    # 19 个 .so
│   │       ├── gamedata/
│   │       ├── configs/
│   │       ├── translations/
│   │       └── data/
│   ├── cfg/
│   │   ├── server.cfg         # 改 hostname/rcon_password/contact
│   │   └── sourcemod/         # sourcemod.cfg + 46 个插件 cfg
│   ├── maps/                  # 空目录，仅挂载
│   └── motd.txt
```

## 必须修改的文件

| 文件 | 修改内容 |
|------|---------|
| `docker-compose.yml` | `+hostname` 改服务器名 |
| `data/cfg/server.cfg` | `hostname`、`rcon_password`、`sv_contact` |

## 端口

| 端口 | 协议 | 用途 |
|------|------|------|
| 27015 | UDP | 游戏 + Steam 查询 |
| 27015 | TCP | RCON |
| 27005 | UDP | 客户端 |
| 27020 | UDP | 服务器状态 |
| 26900 | UDP | Steam Master Server |

## 关联记忆

- [[l4d2-server-quick-reference]] — 日常管理
- [[l4d2-deployment-rules]] — 踩坑清单
- [[game-server-port-allocation]] — 端口分配总表
