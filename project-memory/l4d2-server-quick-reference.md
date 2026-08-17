---
name: l4d2-server-quick-reference
description: L4D2 服务器管理速查（启停、日志、改配置、常见问题）
metadata: 
  node_type: memory
  type: reference
  tags: 
    - l4d2
    - server
    - ops
    - quickref
  originSessionId: 4b3417fe-a874-420c-b976-80f0ddfa0c75
  modified: 2026-08-12T15:17:31.872Z
---

# L4D2 服务器管理速查

## 启停

```bash
# 启动（含延迟注入 nb_update_frequency 等）
/home/ubuntu/l4d2-start.sh

# 停止（三个服务全停：l4d2 + l4d2-init + l4d2-admin）
docker compose -f /opt/gameservers/l4d2/docker-compose.yml down

# 重启（保留容器，不更新参数）
docker compose -f /opt/gameservers/l4d2/docker-compose.yml restart

# 仅重启游戏服务器（不影响 admin panel）
docker restart l4d2-server

# 单独管理 admin panel
docker compose -f /opt/gameservers/l4d2/docker-compose.yml stop l4d2-admin
docker compose -f /opt/gameservers/l4d2/docker-compose.yml up -d l4d2-admin

# 重建重启（更新参数、镜像）— 然后用 l4d2-start.sh 注入
docker compose -f /opt/gameservers/l4d2/docker-compose.yml down
docker compose -f /opt/gameservers/l4d2/docker-compose.yml up -d
/home/ubuntu/l4d2-start.sh  # 重新注入 nb_update_frequency
```

> ⚠️ `nb_update_frequency` (僵尸流畅度) 是 Nav 系统 cvar，所有 cfg 执行后才注册。`sm_cvar` 在 sourcemod.cfg / server.cfg / plugin cfg 中均静默失败。唯一可靠方式：容器启动后延迟 RCON 注入，`l4d2-start.sh` 自动完成。

## 日志

```bash
docker logs --tail 50 l4d2-server       # 最近 50 行
docker logs -f l4d2-server              # 实时跟踪
docker logs l4d2-server 2>&1 | grep -i error  # 过滤错误
```

## 改配置需要重启的文件

| 文件 | 重启方式 |
|------|----------|
| `docker-compose.yml` **volumes 增减** | **down + up**（必须重建） |
| `docker-compose.yml` 其他项 | restart 即可 |
| 新增 .smx / .vdf / .so 插件 | restart |
| 修改 .smx / .so（替换编译） | restart |
| **新增 .vpk 地图到 addons/** | **restart**（引擎只在启动时扫描 addons） |

## 改配置无需重启

| 操作 | 方式 |
|------|------|
| **换地图** | `/home/ubuntu/l4d2-switch-map.sh <地图>` 或直接 `sm_map <map>` |
| 改 `server.cfg` / `sourcemod.cfg` | `exec server.cfg` 或下张图自动生效 |
| 改 `advertisements.txt` | 下一轮播自动生效 |
| 改 `hostname.txt` | `sm_hostname_reload` |
| 改 `motd.txt` | 玩家下次连接自动拉取 |
| 改武器数值 | `exec sourcemod/sourcemod.cfg` |
| 改霰弹枪射速/换弹 | 改 cvar → 即刻生效（WeaponHandling 读实时值） |
| 改复活时间 | `sm_cvar si_hud_respawn_delay <秒数>`（si_hud 内置，l4d2_auto_respawn 已禁用 2026-08-02） |

## 通过控制台执行命令

### 换地图（首选）

```bash
/home/ubuntu/l4d2-switch-map.sh <地图名>
# 例: /home/ubuntu/l4d2-switch-map.sh c4m1_milltown_a
```

### python3-rcon（执行任意命令）

```bash
python3 -c "
from rcon.source import Client
with Client('127.0.0.1', 27015, passwd='Nxp4HJ1xE2Jtzjng') as client:
    print(client.run('sm_map c3m1_plankcountry'))
"
```

### 插件热重载（不重启服务器）

```bash
python3 -c "
from rcon.source import Client
with Client('127.0.0.1', 27015, passwd='Nxp4HJ1xE2Jtzjng') as client:
    print(client.run('sm plugins reload <插件文件名不带.smx>'))
    print(client.run('sm plugins info <插件文件名>'))   # 验证版本/状态
"
```

> ⚠️ 命令是 `sm plugins reload`（**不是** `sm_reload_plugin`，会报 Unknown command）。
> 已验证（2026-08-12）：`sm plugins info` 的 Version 字段显示磁盘 smx 的信息，
> 不能证明运行态；**重载后用 OnPluginStart 日志行确认**（如 "[shop] loaded v1.7.5"）。
> reload 副作用：在线玩家的插件状态重置（PTG toggle、商店透视等需重新开启）。

### map-switch.sh（不推荐，不稳定）

```bash
# 换图（可能静默失败，不推荐）
/opt/gameservers/l4d2/map-switch.sh <地图名>

# 发送任意命令
/opt/gameservers/l4d2/map-switch.sh -c "<控制台命令>"
```

> **换图**：`changelevel` = Valve 原生；`sm_map` = SourceMod；**禁止用 `map`**（踢掉所有玩家）

## 实测笔记（2026-08-01，引擎 2.2.4.3 build 2026-06-30）

- **RCON 标准协议可用**（loopback 127.0.0.1 与公网 IP 均通）：auth 包 size=4+4+len+2、body 后 2 个空字节；auth 响应 type=0 空 body 属正常（命令照常执行）
- **A2S 查询对 127.0.0.1 源不响应**，必须用公网 IP（有 challenge 流程）
- `sv_setsteamaccount` 早期 exec 报 Unknown（见 [[l4d2-gslt-pitfall]]）；匿名登录 + VAC + 公网列表可见正常
- 引擎早期 exec server.cfg 时中文行/注释会被拆词（`Unknown command "24"`、`"/"` 等噪音），最终值仍正确（hostname/sv_downloadurl 实测正常）
- 启动早期有 `Server is hibernating` + `Unknown command "sv_hibernate_when_empty"` 噪音；实际由 sourcemod.cfg 的 `sm_cvar sv_hibernate_when_empty 0` 在 SM 时机补设

## 当前服务器参数

| 参数 | 值 |
|------|-----|
| 镜像 | `left4devops/l4d2:latest` |
| 网络 | host |
| Tickrate | 60 |
| 人数 | 24 |
| 默认地图 | c1m1_hotel |
| 主机名 | 粟藜24人纯净多特战役服[6特] |
| Tag | coop,hard,60tick,24slots,CN,custom,campaign,multi-si |
| 时区 | Asia/Shanghai |
| 外网 IP | 81.71.101.135 |
| 端口 | 27015 UDP/TCP |
| RCON 密码 | Nxp4HJ1xE2Jtzjng |

## 关键文件路径

```
/opt/gameservers/l4d2/
├── docker-compose.yml          ← 容器配置（volumes 增减需 down+up）
├── data/
│   ├── addons/                 ← MetaMod/SourceMod + 非工坊 VPK
│   │   ├── *.vpk               ← 三方图 VPK（引擎自动加载）
│   │   └── sourcemod/
│   │       ├── plugins/        ← .smx 插件
│   │       ├── configs/        ← mapcycle.txt, 公告, admins
│   │       ├── data/
│   │       │   └── hostname.txt  ← ★ 主机名真正来源
│   │       └── logs/           ← SM 日志
│   ├── cfg/                    ← 服务器配置
│   │   ├── server.cfg          ← 主配置
│   │   └── sourcemod/
│   │       ├── sourcemod.cfg   ← sm_cvar + sm_weapon
│   │       ├── l4d2_shotgun_speed.cfg
│   │       └── l4d2_ff_fix.cfg
│   ├── maps/                   ← 只保留官图 BSP
│   │   ├── maps/               ← c1m1_hotel 等官图
│   │   ├── missions/           ← 清空（VPK 提供）
│   │   └── scripts/            ← 清空（VPK 提供）
│   └── motd.txt
```

### 地图源文件

```
/opt/gameservers/l4d2/admin-panel/maps/
├── zip/                               ← 原始 ZIP 压缩包（权威源 + nginx 下载站）
└── vpk/                               ← VPK 备份
/home/ubuntu/l4d2-switch-map.sh        ← 切换脚本
```

## 多特感配置（Special Spawner）

### 刷新节奏

| cvar | 值 | 说明 |
|------|-----|------|
| `ss_first_time` | 20 | 离开安全屋后首波延迟(秒) |
| `ss_time_min` | 40 | 波次最小间隔(秒) |
| `ss_time_max` | 60 | 波次最大间隔(秒) |
| `ss_time_mode` | 1 | 间隔模式（1=递增模式） |
| `ss_suicide_time` | 25 | 闲置特感超时自杀(秒) |

### 数量控制

| cvar | 值 | 说明 |
|------|-----|------|
| `ss_base_limit` | 6 | 基础特感数 |
| `ss_extra_limit` | 1.25 | 每人额外特感数 |
| `ss_si_limit` | 24 | 地图上同时存活上限（配合 `spawn_infected_nolimit.smx` 解除引擎硬限制） |
| `ss_base_size` | 4 | 基础组大小 |
| `ss_extra_size` | 1 | 每人额外组大小 |
| `ss_spawn_size` | 4 | 每波一次刷出数量 |

- 特感总数 = `ss_base_limit + max(0, 幸存者 - 4) × ss_extra_limit`，硬上限 `ss_si_limit`
- 1-4 人 6 特，10 人 13.5→14 特，~18 人起封顶 24

### 每种特感单波上限 + 权重

| 特感 | `_limit` | `_weight` |
|------|----------|-----------|
| Smoker | 2 | 100 |
| Boomer | 2 | 200 |
| Hunter | 3 | 100 |
| Spitter | 2 | 200 |
| Jockey | 3 | 100 |
| Charger | 3 | 100 |

### 刷怪范围

| cvar | 值 |
|------|-----|
| `ss_spawnrange_min` | 100 |
| `ss_spawnrange_max` | 1500 |
| `ss_rush_distance` | 1500 |

### 生效方式

配置定义在 `cfg/sourcemod/specialspawner.cfg`，但 **`sourcemod.cfg` 中的 `sm_cvar ss_*` 覆盖其值**。实际生效路径：
- 部署：`/opt/gameservers/l4d2/data/cfg/sourcemod/sourcemod.cfg`（第 203-211 行）
- （旧副本 /home/ubuntu/l4d2-server-pack 已于 2026-08-02 清理删除，只有部署路径一份权威）

RCON 热更新：`sm_cvar ss_time_min <秒数>` 即刻生效无需换图。

## 复活时间

`si_hud_respawn_delay 15.0`（si_hud v1.7.28+ 内置，替代 l4d2_auto_respawn）— 配置文件 `cfg/sourcemod/l4d2_si_hud.cfg`
- 每图基础复活次数 `si_hud_respawn_base 2`（=3 条命），复活币 `si_hud_respawn_coin_start 2` 初始 / `si_hud_respawn_coin_max 5` 持有上限，总开关 `si_hud_respawn_enable 1`
- 次数用完 → 扣复活币 → 都没有 → 躺尸等电击器/过关
- ⚠️ `l4d2_auto_respawn.smx` 已于 2026-08-02 禁用（无条件复活绕过复活币限次，见 [[l4d2-auto-respawn-conflict]]）

## 友伤

`survivor_friendly_fire_factor_hard 0.08`（原 Hard 默认 0.3 的 ~27%）— 在 `/opt/gameservers/l4d2/data/cfg/sourcemod/sourcemod.cfg` 中 `sm_cvar` 设置。所有难度：`_easy 0.02 | _normal 0.04 | _hard 0.08 | _expert 0.15`

## 击杀回血

插件 `l4d2_si_kill_heal.smx` — 击杀特感/Witch/Tank 回复其最大血量 2%
- 站立时：回血，上限 100 HP
- 倒地时：加到 `m_healthBuffer` 延缓死亡（上限 300）
- 配置文件：`cfg/sourcemod/l4d2_si_kill_heal.cfg`
- `sm_si_kill_heal_percent "1"` — 回血比例
- `sm_si_kill_heal_max "100"` — 站立回血上限
- `sm_si_kill_heal_buffer "300"` — 倒地缓冲区上限

| 敌人 | 基础 HP | 回血 |
|------|--------|------|
| Boomer | 50 | 1 |
| Smoker | 250 | 5 |
| Hunter | 250 | 5 |
| Spitter | 100 | 2 |
| Jockey | 325 | 6.5 |
| Charger | 600 | 12 |
| Witch | 1000 | 20 |
| Tank | 3000/人 | 60~100 |

> Tank HP 随人数缩放（`sm_tank_hp_per_survivor 3000`），2 人以上击杀回血即封顶 100。

## 地图下载站

**http://81.71.101.135** — nginx 端口 80，目录 `admin-panel/maps/zip/`

## 关联记忆

- [[l4d2-map-download-server]] — nginx 地图下载站详情
- [[l4d2-announcements]] — 游戏公告系统（advertisements / auto_motd / motd）
- [[l4d2-deployment-rules]] — 踩坑清单
- [[l4d2-howto-plugins]] — 插件管理
- [[l4d2-howto-thirdparty-maps]] — 三方地图管理
- [[l4d2-weapon-values]] — 全武器数值对照
- [[game-server-port-allocation]] — 端口分配
- [[game-server-deployment-plan]] — 整体架构
