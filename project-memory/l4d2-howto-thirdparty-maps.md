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

# L4D2 三方地图操作指南

## 核心原则

**VPK 直接放 addons，引擎自己加载一切。不提取、不拆分、不搞 BSP。**

和本地开服一样：VPK 丢进 `addons/`，`sm_map` 切图，完事。

| 地图类型 | 服务端 VPK | 说明 |
|---------|-----------|------|
| 非工坊地图 | **放 addons** | 源 ZIP 在 `admin-panel/maps/zip/`，nginx 暴露供玩家下载 |
| 工坊地图 | **不放** | 客户端 Steam 工坊订阅，服务端放 VPK 会版本冲突 |

为什么要服务端放 VPK：vscripts 的 `PrecacheModel("models/xxx.mdl")` 需要服务端能找到文件。没有 VPK → PrecacheModel 静默失败 → 客户端不加载模型 → 贴图/碰撞全没。

## 目录结构

```
/opt/gameservers/l4d2/admin-panel/maps/
├── zip/                                    ← 原始 ZIP 压缩包（权威源 + nginx 下载站）
└── vpk/                                    ← VPK 备份
/opt/gameservers/l4d2/data/addons/          ← 非工坊 VPK 放这里（引擎自动加载）
/opt/gameservers/l4d2/data/maps/maps/       ← 仅保留官图 BSP（c1m1_hotel 等）
/opt/gameservers/l4d2/data/maps/missions/   ← 清空（VPK 提供 missions）
/opt/gameservers/l4d2/data/maps/scripts/    ← 清空（VPK 提供 scripts）
```

## 安装新三方图

### 方式 1：Admin Panel 网页上传（推荐）

访问 http://81.71.101.135/admin/ → 「地图管理」tab：
- **ZIP 上传**：拖拽/选择 .zip → 自动 unzip → VPK 复制到 addons + vpk 备份 → scan_maps.py 更新
- **Steam 工坊**：输入工坊 URL 或 ID → steamcmd 下载 → 自动解析地图名 → 添加到轮换

### 方式 2：手动命令行

```bash
# 从 ZIP 提取 VPK
unzip -o /opt/gameservers/l4d2/admin-panel/maps/zip/地图.zip "*.vpk" -d /tmp/

# 放到 addons
cp /tmp/*.vpk /opt/gameservers/l4d2/data/addons/

# 备份 VPK
cp /tmp/*.vpk /opt/gameservers/l4d2/admin-panel/maps/vpk/

# 重新扫描
python3 /opt/gameservers/l4d2/admin-panel/scan_maps.py
```

## 换图

```bash
# 查看可用地图及当前状态
/home/ubuntu/l4d2-switch-map.sh --list

# 切换（就是 sm_map，VPK 已在 addons 不需要任何文件操作）
/home/ubuntu/l4d2-switch-map.sh re3m1        # 首关名
/home/ubuntu/l4d2-switch-map.sh re3           # 别名
```

**⚠️ 新增 VPK 到 addons 后必须 `docker restart`**，引擎只在启动时扫描 addons。已加载的 VPK 之间切换只需 `sm_map`，无需重启。

## 轮询

- **官图**：`Campaign Finale Auto Transition` 自动按 c1→c2→...→c14→c1 循环
- **三方图**：终章胜利后从 `mapcycle.txt` 找下一个三方图
- **投票**：玩家可通过 `!nominate` 提名地图，`!rtv` 发起投票
- 两套系统互不跳转（官图打完不会跳到三方图，反之亦然）

## 当前地图池

### 非工坊（VPK 在 addons）

| 地图 | 首关 | VPK | 文件名 |
|------|------|-----|--------|
| Dark Wood (Extended) | `dw_woods` | 940MB | darkwood_extended_19.vpk |
| 增城 (广州增城) | `zc1_m1` | 834MB | gzzc7.9.vpk |
| Amid the Ruins | `atr01_trailer_park` | 537MB | amidtheruins.vpk |
| 生化危机3 | `re3m1` | 463MB | resident_evil3_10sep2025.vpk |
| Dear Esther | `de_donnelley_m1` | 432MB | dearesther.vpk |
| 生化危机1 | `re1m1` | 350MB | resident_evil1_19junio2024.vpk |
| Drop Dead Gorges | `ddg1_tower_v2_1` | 282MB | ddg_v2_1.vpk |
| Dead City 2 | `dc2m1_riverside` | 190MB | deadcity2.vpk |
| Tanks Playground | `l4d2_tanksplayground` | 108MB | l4d2_tanksplayground.vpk |
| Lab 024 | `l4d2_lab024_01` | 97MB | lab024_l4d2.vpk |

### 工坊（客户端订阅，服务端不放 VPK）

| 地图 | 首关 | Workshop ID |
|------|------|-------------|
| 天梯 | `hls_05` | 3703865650 |
| 天梯2 | `hls_10` | 3731244861 |
| TUMTaRA | `tumtara` | 469986973 |

### 未安装

无。所有 ZIP 已提取 VPK 放入 addons。

## 玩家侧

- **非工坊地图**：玩家需要手动下载 VPK 放到自己 `left4dead2/addons/`
- **工坊地图**：玩家 Steam 工坊订阅即可

## 为什么放弃提取方案

三个月来维护的"提取 BSP + scripts + missions"方案是错的：
- 99% 的时间 VPK 直接放 addons 就能用，和本地开服一样
- "服务端不放 VPK"规则只适用于工坊地图的版本冲突场景
- 提取方案引入了 7 个坑：残留 .nuc、vscripts 漏拷、melee 漏拷、mission VDF 格式、String Table 损坏、PrecacheModel 静默失败、验证缺失
- 详见 [[l4d2-map-switch-pitfalls]]

## 关联

- [[l4d2-deployment-rules]] — 铁律清单
- [[l4d2-map-switch-pitfalls]] — 提取方案的七个坑
- [[game-server-deployment-plan]] — 整体架构
