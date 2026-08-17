---
name: l4d2-rest-tier-override-bug
description: 冷静期实测 20-25s 而非设计 25-35s 的根因：pressure_tracker 残留 cvar 误判触发 T2 段位表 12-15s
metadata: 
  node_type: memory
  type: project
  originSessionId: cb71801d-ad03-4acc-97ea-96be15858743
  modified: 2026-08-15T15:47:42.844Z
---

specialspawner 冷静期(REST)设计 `ss_rest_min/max = 25/35`，但 2026-08-15 实测只有 12.9-14.6s（日志 `CLEARING -> REST (XX.Xs, tier T2)`），玩家观感 20-25s（= REST 13-15s + 波后间隔恒 10.0s，被 GetPostRestInterval 下限钳死）。

**根因**：SM 里插件创建的 ConVar 在插件卸载/禁用后不注销，残留到服务器进程重启为止。pressure_tracker 今天早些跑过(14:59-15:09 有日志)后被禁用(`pressure_tracker.smx.disabled`)，但它建的 `sm_pressure_tier` 仍挂在引擎里。旧 `CheckPressureTracker()` 用 `FindConVar("sm_pressure_tier") != null` 判断 tracker 存在 → 恒 true → `g_bPressureTrackerExists=true` → `EnterRest()` 走 `GetRestRangeByTier(T2)` 的 12-15s，完全绕过 cfg 的 25-35（同理影响自杀时间/倒地补偿/分批数，全被 T2 段位表覆盖）。

**修复 v2.4.1**（specialspawner.sp `CheckPressureTracker`）：改用 `FindPluginByFile("pressure_tracker.smx")` + `GetPluginStatus == Plugin_Running` 判断插件是否真加载，与 NotifyPressureWaveStart/Cleared 一致；未加载时把 `g_cvPressureTier/Aggression` 置 null 兜底清残留。已编译（compiled/specialspawner.smx，hash 50f5703...，version 2.4.1），**未部署**（当时有真人在玩，遵 [[l4d2-dont-touch-server]]）。空服部署：`cp compiled/specialspawner.smx plugins/` + `sm plugins reload specialspawner`。

**遗留**：即便重启 pressure 系统，T2 段位表(specialspawner.sp:2059)本身写 12-15s，跟设计 25-35 不符；重新启用 pressure 时这张表要校准。相关 [[l4d2-specialspawner-config.md]] [[l4d2-si-composition-manager]]。
