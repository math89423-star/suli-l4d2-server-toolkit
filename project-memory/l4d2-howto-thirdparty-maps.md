---
name: l4d2-howto-thirdparty-maps
description: L4D2 服务器安装和切换三方图的操作步骤（VPK 直接放 addons，不做提取）
metadata: 
  node_type: memory
  type: reference
  tags: 
    - l4d2
    - maps
    - thirdparty
    - howto
  originSessionId: b9b6dac1-f58d-4856-8419-3bbadd708f38
---

# L4D2 三方地图操作指南（直装模式）

> **⚠️ 当前服务器是直装 `srcds_linux`**，不走 Docker。
> 旧 Docker 路径 `/opt/gameservers/l4d2/data/` 已废弃。

## 核心原则

**VPK 直接放 addons，引擎自己加载一切。不提取、不拆分、不搞 BSP。**

和本地开服一样：VPK 丢进 `addons/`，`sm_map` 切图，完事。

| 地图类型 | 服务端 VPK | 说明 |
|---------|-----------|------|
| 非工坊地图 | **放 addons** | 源 ZIP 在 admin-panel，nginx 暴露供玩家下载 |
| 工坊地图 | **不放** | 客户端 Steam 工坊订阅，服务端放 VPK 会版本冲突 |

为什么要服务端放 VPK：vscripts 的 `PrecacheModel("models/xxx.mdl")` 需要服务端能找到文件。没有 VPK → PrecacheModel 静默失败 → 客户端不加载模型 → 贴图/碰撞全没。

## 目录结构

```
/home/administrator/l4d2-server/
├── left4dead2/
│   └── addons/                    ← 非工坊 VPK 放这里（引擎启动时自动加载）
│       ├── *.vpk                  ← 三方地图 VPK
│       └── sourcemod/
├── admin-panel/
│   ├── maps/
│   │   ├── zip/                   ← 原始 ZIP 压缩包（nginx 下载站）
│   │   └── vpk/                   ← VPK 备份
│   └── app.py                     ← Flask 后端
└── cfg/
    └── sourcemod/                  ← 插件 cfg
```

## 安装新三方图

### 方式 1：Admin Panel 网页上传（推荐）

访问 http://127.0.0.1/ → 地图管理 tab：
- **ZIP 上传**：拖拽/选择 .zip → 自动 unzip → VPK 复制到 addons + vpk 备份 → maps.json 更新

### 方式 2：手动命令行

```bash
# 从 ZIP 提取 VPK
unzip -o <zip文件> "*.vpk" -d /tmp/

# 放到 addons（引擎加载目录）
cp /tmp/*.vpk /home/administrator/l4d2-server/left4dead2/addons/

# 备份 VPK
cp /tmp/*.vpk /home/administrator/l4d2-server/admin-panel/maps/vpk/
```

## ⚠️ 换图规则（关键！）

### 已加载的 VPK 之间切换：`sm_map` 即可

```bash
python3 /tmp/rcon.py 'sm_map c2m1_highway'
```

### 新增 VPK 后：必须重启 srcds！

引擎**只在启动时**扫描 addons 目录下的 VPK。运行中新加的 VPK 不会被识别。
`sm_map` 会报 "Changing map to..." 但实际不换——因为引擎根本没加载那个 VPK。

```bash
# 找到 srcds 进程
ps aux | grep srcds_linux

# 杀掉并重启（用你原来的方式）
kill <pid>
cd /home/administrator/l4d2-server && ./srcds_linux -game left4dead2 ... &
```

### 总结

| 场景 | 操作 |
|------|------|
| 已加载 VPK 之间切图 | `sm_map` 直接切，不需要重启 |
| 新增 VPK 后切图 | **先重启 srcds**，再 `sm_map` |
| 换插件 cfg | `sm_cvar` 临时生效，或 `sm plugins reload` |

## 地图名规则

VPK 内 BSP 文件名 ≠ 引擎实际地图名。引擎地图名由 `missions.cache/*.txt` 定义。

```
VPK 内部文件:  maps/cheyenne.bsp        ← 无前缀
mission 定义:  "Map" "1-cheyenne"        ← 有数字前缀
sm_map 需要:   sm_map 1-cheyenne         ← 用 mission 定义的名称
```

**换图时用 mission 文件里的 Map 字段**，不要用 VPK 内部文件名。

## 当前地图池（2026-08-18）

### 非工坊（VPK 在 addons）

| 地图 | 首关 | VPK |
|------|------|-----|
| Left4SGC BETA 2.2 | `1-cheyenne` | left4sgc_v2_2-1of2.vpk + 2of2.vpk |
| 恶灵附身2 | `tew2_1stem` | tew2_campaign.vpk + tew2_resources.vpk |
| Tank God Domain | `hehe211` | cc_tankgod.vpk |
| Mapaliminal | `anemoia_arcade` | mapaliminal.vpk |
| TUMTaRA (工坊) | `tumtara` | 469986973.vpk |

### 工坊（客户端订阅，服务端不放 VPK）

| 地图 | 首关 | Workshop ID |
|------|------|-------------|
| 天梯 | `hls_05` | 3703865650 |
| 天梯2 | `hls_10` | 3731244861 |

## 关联

- [[l4d2-deployment-rules]] — 铁律清单
- [[l4d2-map-switch-pitfalls]] — 提取方案的七个坑
- [[l4d2-admin-map-management]] — 前端面板管理
- [[l4d2-howto-plugins]] — 插件管理指南
