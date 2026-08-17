---
name: l4d2-plugin-inventory
description: "73 active 插件分类清单（路径: addons/sourcemod/PLUGINS.md）"
metadata: 
  node_type: memory
  type: reference
  tags: 
    - l4d2
    - plugins
    - inventory
  originSessionId: b63f80da-189a-4e3b-9a14-c597905d1e77
  modified: 2026-07-29T07:02:42.877Z
---

# L4D2 插件清单

完整清单位于服务器上的 `/opt/gameservers/l4d2/data/addons/sourcemod/PLUGINS.md`，包含：

- **73 个 active 插件**，0 disabled
- 按类别分：核心依赖(2) / SM 官方(15) / 地图投票(3) / 特感生成(7) / HUD公告(9) / 武器弹药(6) / 游戏性(12) / 过渡进度(8) / BUG修复(6) / 服务器管理(5)

## 关键配置依赖

- 武器属性、弹药量、团灭换图阈值均定义在 `cfg/sourcemod/sourcemod.cfg`
- Tank HP = 存活人数（含 BOT）× 3000，最低 12,000（l4d2_tank_unified）
- 团灭 4 次自动换图（`sm_l4d_fmc_crec_coop_map 4` / `sm_l4d_fmc_crec_coop_final 4`）
- 友伤倍率 0.30，自动复活 45 秒

## 与参考服务器的差异

- `l4d2_tickrate_enabler.smx` — 本服独有（60-tick 方式不同）
- `mapchooser / nominations / rockthevote / randomcycle` — 已永久删除

## 近期变动（2026-07-29）

- 删除：`l4d2_maptankfix`、`l4d2_tank_ranking`、`l4d2_si_kill_heal`、`l4d2_bf_killfeedback`（音效归击杀 HUD 统一管）
- 重命名：`l4d2_tank_core` → `l4d2_tank_unified`，`L4D_All_Infected_HUD_HP` → `l4d2_si_hud`
- disabled 目录已清空

## 关联

- [[l4d2-howto-plugins]] — 插件管理
- [[l4d2-server-quick-reference]] — 管理速查
- [[l4d2-tickrate-setup]] — 60-tick 架构
- [[l4d2-deployment-rules]] — 部署规则
- [[l4d2-bf-killfeedback]] — 战地击杀反馈插件（已删除，后续合并到击杀 HUD）
