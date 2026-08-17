---
name: l4d2-revive-system-v1120
description: si_hud v1.12.0 积分复活体系：复活币废除，免费命(1次/图)耗尽后积分>=6000 死亡30s自动复活（复活成功才扣）；shop 躺尸禁购
metadata: 
  node_type: memory
  type: project
  originSessionId: 7e8bf92f-7446-4a62-a9cc-d8054d85fe91
  modified: 2026-08-04T09:01:29.991Z
---

# si_hud v1.12.0 积分复活体系（2026-08-04 已部署，替代复活币）

**user 拍板动机**：复活币是"跨图储蓄资产"（积分买来屯着），被换图意外清空 = 积分白花。改"死亡时即用即付"：复活资产与当图积分同生命周期，屯币敞口归零。

## 新规则（部署验证通过）

- **免费命**：每图 base=1 次（=2 条命），每图/团灭重开刷新（`si_hud_respawn_base`，不变）
- **免费耗尽后**：积分 ≥ `si_hud_revive_cost`（6000）→ 死亡 `si_hud_respawn_delay`（**30s**，原 20）后自动复活，**复活成功才扣积分**（30s 内队友电击/救起 → `Timer_Respawn` 的 `IsPlayerAlive` 提前 return，不扣）
- 积分不足 → 躺尸等电击器/过关（死亡提示"积分不足 6000 无法自动复活"）
- **配套：shop 全商店倒地/死亡禁购**（v1.7.0，ShopBuy 入口统一拦截）→ 死亡→复活窗口积分只增不减 → 复活瞬间必够 6000，无透支问题
- **团灭回滚自然退款**：回滚钱包到本图开局 → 已扣 6000 退回
- 复活套装（M60+斧+药+雷+满血100）免费命与积分复活**都发**（Timer_RespawnTeleport 统一发 forward，v1.12.0 前已如此）

## 移除清单（si_hud v1.12.0 + shop v1.7.0 + include）

- `g_iReviveCoins` / `si_hud_respawn_coin_max` / `_start` cvar / 持久化 coins 字段 / 存档校验 coins 恢复
- SH_ 币 natives：`SH_GetReviveCoins`/`SH_AddReviveCoins`/`SH_GetCoinMax`/`SH_ReviveClient`（契约已从 include 删除）
- 商店"复活币 8500"商品（classname 空特殊商品）与躺尸买币立即复活（v1.2.4）
- 播报文案全部去币（进服/每图/死亡/得分榜），死亡/进服改提示 6000 机制

## 实现要点

- `g_bPaidRespawn[MAXPLAYERS+1]` 标志：`ScheduleRespawn(client, isPaid)` 设置，`Timer_Respawn` 复活生效时读+清+扣 `g_iWallet -= cost`
- 死亡分支：免费次数>0 → 次数-- + `ScheduleRespawn(client, false)`；`wallet >= cost` → `ScheduleRespawn(client, true)`；否则躺尸提示
- 新 cvar：`si_hud_revive_cost` 6000（0-100000）；`si_hud_respawn_delay` 20→30（**cvar 残留坑**：reload 后旧值 20 不更新，已 RCON 设 30 + cfg 手改 30；coin cvar 残留行已从 cfg 删除）
- cfg：`cfg/sourcemod/l4d2_si_hud.cfg` 已同步（delay 30 + revive_cost 6000 + 注释）

## 遗留

- bot 与玩家同逻辑（免费命→积分复活→躺尸；bot 无套装 v1.9.5 规则不变）
- 旧存档文件里残留 "coins" 字段无害（读时忽略）

相关：[[l4d2-revive-coin-purchase-fix]]（旧机制已废）、[[l4d2-respawn-gear]]（套装触发）、[[l4d2-shop-decoupled]]（SH_ API 契约）、[[l4d2-si-hud-rejoin-restore]]（钱包/战役键）
