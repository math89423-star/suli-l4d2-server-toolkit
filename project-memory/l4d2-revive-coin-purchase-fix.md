---
name: l4d2-revive-coin-purchase-fix
description: 躺尸玩家买复活币不复活——根因：复活判定只响应 player_death；SH_ReviveClient native 修复（si_hud v1.9.1 + shop v1.2.4）
metadata: 
  node_type: memory
  type: project
  originSessionId: a761e958-f85a-4276-900b-b271aba86677
  modified: 2026-08-04T09:01:31.842Z
---

# ⚠ 本机制已废除（2026-08-04 si_hud v1.12.0）：复活币整体移除，改为积分复活（6000 分/次，免费命耗尽后），详见 [[l4d2-revive-system-v1120]]。以下为历史记录。

复活币购买 Bug 修复（2026-08-03 部署）：复活判定只在 `player_death` 事件里执行（`l4d2_si_hud.sp` Event_PlayerDeath 分支 C）。玩家次数用完且无币 → 死亡 → 躺尸，之后在商店买复活币只会 `SH_AddReviveCoins(+1)`，**不会再有 death 事件 → 币白买**。

**修复**（双插件已部署并 reload 验证）：
- `l4d2_si_hud` **v1.9.1**：新增第 6 个 SH_ native `SH_ReviveClient(client)` —— 真死亡状态（非 alive / 非 `L4D_IsPlayerIncapacitated` 倒下 / 非 bot / team 2 / `g_hRespawnTimer==null` 无挂起复活计划 / 有币）时消耗 1 枚币 + `ScheduleRespawn(client, false)`，返回 1；否则 0 不动。
- `l4d2_shop` **v1.2.4**：购买复活币分支（classname 空）`SH_AddReviveCoins(+1)` 后调 `SH_ReviveClient`，生效时播报"复活币已生效，即将复活"；存活玩家返回 0 正常囤币。
- 契约：`include/l4d2_si_hud.inc` 追加 `SH_ReviveClient` 声明。

**Why:** 倒下（incapacitated）不算死亡——引擎自会处理，强行复活会穿模/双复活；已有挂起计时器时不能重复调度（ScheduleRespawn 会重置倒计时）。

**How to apply:** 判定"是否真死亡"用 `!IsPlayerAlive() && !L4D_IsPlayerIncapacitated()`，别只看 `IsPlayerAlive`（倒下玩家它也返回 false）。

相关：[[l4d2-shop-decoupled]]（SH_ API 5 natives 起步，现 6 个）、[[l4d2-auto-respawn-conflict]]（l4d2_auto_respawn 已禁用，复活系统并入 si_hud）。
