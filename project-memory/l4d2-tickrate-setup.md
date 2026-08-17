---
name: l4d2-tickrate-setup
description: L4D2 60-tick + 30Hz 僵尸更新架构和修复记录
metadata: 
  node_type: memory
  type: reference
  tags: 
    - l4d2
    - tickrate
    - nb_update_frequency
  originSessionId: c741fbd0-e22a-427d-abab-64fbc3502cb4
---

# L4D2 60-Tick + 30Hz 僵尸更新架构

## 三个组件分工

| 组件 | 类型 | 职责 |
|------|------|------|
| `l4dtoolz` (fdxx v0.5.2) | Metamod 插件 (`addons/l4dtoolz.vdf`) | 解锁引擎 tickrate 上限 + 人数上限 |
| `l4d2_tickrate_enabler.smx` | SourceMod 插件 | 根据 tickrate 自动设置所有网络 cvar |
| `l4d2-start.sh` + `rcon-init.sh` | 启动脚本 | RCON 延迟注入 `nb_update_frequency` |

## l4dtoolz 不创建 sv_tickrate

- fdxx 的 l4dtoolz 解锁 tickrate 但**不创建 `sv_tickrate` cvar**
- `l4d2_tickrate_enabler.smx` 原代码 `SetConVarInt(FindConVar("sv_tickrate"), ...)` 在 cvar 不存在时崩溃
- **已修复**：加 null check，`sv_tickrate` 不存在时跳过

## 网络 cvar 最终值（60 tick）

| Cvar | 值 | 来源 |
|------|-----|------|
| sv_minrate | 60000 | server.cfg |
| sv_maxrate | 60000 | 插件：tick*1000 |
| sv_mincmdrate | 60 | 插件 |
| sv_maxcmdrate | 60 | 插件 |
| net_splitpacket_maxrate | 30000 | 插件：tick/2*1000 |
| net_splitrate | 2 | 插件 cfg |
| net_maxcleartime | 0.0001 | 插件 cfg |
| fps_max | 0 | 插件 cfg |
| nb_update_frequency | 0.033 (30Hz) | rcon-init.sh RCON 注入 |

## 注意：sv_minupdaterate / sv_maxupdaterate 在 L4D2 不存在

- 这两个是 CS:GO 的 cvar，L4D2 没有
- 插件尝试设置但 FindConVar 返回 null，SetConVarInt 静默跳过
- server.cfg 中不要写这两个

## nb_update_frequency 为什么需要两个注入源

1. `sourcemod.cfg` 中 `sm_cvar nb_update_frequency 0.033` **无效**（Nav 系统 cvar，执行时未注册）
2. 插件 `OnConfigsExecuted` 尝试设置，也可能太早
3. `rcon-init.sh`：容器启动 60s 后 RCON 注入（带 20 次重试）
4. `l4d2-start.sh`：手动/部署时额外的 RCON 注入

双重注入确保 30Hz 一定生效。

## 服务器差异

- **本服务器（81.71.101.135）**：使用 `l4d2_tickrate_enabler.smx` 插件管理 60-tick 网络 cvar
- **参考服务器**：使用不同方式开启 60-tick，**没有** `l4d2_tickrate_enabler.smx`
- 两边插件列表对比时，`l4d2_tickrate_enabler.smx` 是本服务器独有，不应删除

## 关联

- [[l4d2-deployment-rules]] — 踩坑清单
- [[l4d2-server-quick-reference]] — 管理速查
- [[l4d2-howto-plugins]] — 插件管理
- [[l4d2-permissions-pitfall]] — 权限坑

## 2026-08-16 补充：docker restart 后 nb_update_frequency 复发现场

**现象**：用户进服报告"小僵尸移动卡顿"。
**检查**：`nb_update_frequency = 0.1`（应为 0.033/30Hz）——容器某次 restart 后
rcon-init.sh 未注入（该脚本只在 compose up 流程执行），Nav cvar 回引擎默认 0.1。
其余 60-tick 网络 cvar 全部正常（cmdrate 60 / minrate 60000 / splitrate 2 /
net_splitpacket_maxrate 30000=tick/2*1000），tickrate 插件("设置服务器tick参数")运行中。
**恢复**：`sm_cvar nb_update_frequency 0.033` 立刻生效（Nav cvar 运行时可设）。
**教训**：容器 restart（非 compose up）后必查 `nb_update_frequency`；
连带检查同批网络 cvar（fps_max 保持 0，本服方案，勿动）。

## 2026-08-16 二次补充：z_gun_vertical_punch 会反复被复位 → 启动常驻守护

**复发**：恢复后数分钟内又回 1（触发者非 mapchange——sourcemod.cfg 相关键只在
切图时执行，见日志 01:13/09:46 批量）；疑似 reload/波次活动/客户端复制等事件干扰
cheat-replicated cvar（与 l4d2_punch_fix.smx 时期"复制干扰"同类）。
**对策**：常驻守护脚本 `/tmp/aihardsi_guard.sh`（setsid 后台）每 45s 校验并自动恢复：
  z_gun_vertical_punch 0 / z_gun_horiz_punch 0 / nb_update_frequency 0.033
自动修正记录在 /tmp/aihardsi_monitor.md（AUTO-FIX 行，可追溯触发频率）。
**提醒**：服务器重启后需重新启动守护（或后续并入部署脚本/系统服务）。
