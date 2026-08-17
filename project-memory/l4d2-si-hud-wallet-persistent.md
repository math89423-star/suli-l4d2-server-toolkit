---
name: l4d2-si-hud-wallet-persistent
description: si_hud v1.13.0：可用积分跨图永久保留不再清零 + si_hud_wallet_max 30000 上限；排行榜历史积分不受影响
metadata: 
  node_type: memory
  type: project
  originSessionId: 3e620e99-2b88-47a4-ac85-305580c3e817
  modified: 2026-08-12T14:31:51.351Z
---

# si_hud v1.13.0 可用积分永久保留 + 上限（2026-08-12 部署）

**user 拍板**：可用积分（g_iWallet，商店钱包）**不再随换图/新战役清零**，永久保留；最高钳制到 `si_hud_wallet_max`（默认 **30000**，0=无上限）。**排行榜历史积分 g_iTotalScore 独立无限增长，不受上限影响**（user 特别叮嘱分清）。

**改动清单**（l4d2_si_hud.sp）：
1. **OnMapStart 清零整块删除**——v1.7.28 战役判定 + v1.11.0 战役键清零体系全废弃（官图/三方大图小图一律换图不清）；仅保留 `g_sPrevCampaign` 更新（存档 campaign 字段兼容旧档，已无校验意义）
2. **ScoreLoad_Player 战役校验删除**——v1.7.40/v1.11.0 存档战役校验移除，恢复一律放行（无存档/新玩家仍默认 0），加载后钳上限（旧档可能超 30000）。团灭带旧钱漏洞不受影响（由回滚当刻 ScoreSave_All 同步封堵）
3. **新增 `AddWallet(client, amount)` 统一入账口**——钳制 [0, si_hud_wallet_max]，替换全部 7 处 `g_iWallet +=`（伤害/小僵尸伤害/Witch 伤害/SI 击杀/救援/连杀结算/过关奖励）+ Native_SH_AddWallet（shop 插件外部入账同样走钳制）
4. 版本 1.13.0；新 cvar `si_hud_wallet_max` 已手动追加 cfg（AutoExecConfig 对已存在 cfg 不追加）

**部署**：热重载 `sm plugins reload`（不用重启服务器，在线不断线）。⚠ **reload 副作用：在线玩家内存余额归 0，且 60s 周期存档把 0 覆写回存档**（本次 2 人仅损失 936/844，已告知 user；存档备份 `si_hud_scores.txt.bak-v1.13.0`）。已实测 reload 后计分入账正常（60s 后存档文件见在线玩家余额增长）。

**推翻**：[[l4d2-si-hud-mapchange-wallet-clear]]（v1.8.2 前缀修复历史保留）、[[l4d2-si-hud-rejoin-restore]] v1.11.0 战役键体系。相关：[[l4d2-si-hud-scoring]]、[[l4d2-shop-decoupled]]

## v1.13.5 中途加入/断线重连团灭快照修复（2026-08-16，commit d559122）

**用户 2026-08-16 定稿确认规则**：团灭回到本图开局值 + 2000 补偿；换图/新战役
跨图永久保留不清零（实测确认：存档文件大量玩家 campaign 五花八门但钱包全在，
大为 16928/粟藜 10739/fl409510 4957 均跨图保留；上限 30000 钳制生效）。

**修复 bug**：`SaveScoreState()` 只在 OnMapStart 拍一次全服快照——中途加入/
断线重连玩家进服时快照仍是 0/旧值，团灭 `RestoreScoreState()` 把他钱包错误
清零。修复：`ScoreLoad_Player` 恢复存档钱包后同步 `g_iSaveWallet = 恢复值`
（"本图开始时的初始值"对该类玩家 = 进图时的余额）。⚠ 热加载副作用：在线
玩家钱包按存档恢复（最多丢 60s 窗口收入，已备份
`si_hud_scores.txt.bak-v1.13.5`）。
