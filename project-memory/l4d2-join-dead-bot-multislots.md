---
name: l4d2-join-dead-bot-multislots
description: 战役中途新玩家加入显示死亡状态根因=l4dmultislots 死尸入队（alive_bot_time 30）；si_hud v1.12.1 兜底复活已部署
metadata: 
  node_type: memory
  type: project
  originSessionId: f49d0182-25f9-4c74-9fc8-847868618e15
  modified: 2026-08-04T13:50:45.595Z
---

# L4D2 中途加入死尸入队 bug（2026-08-04 已修复）

## 症状

战役中途（离开安全屋后）新玩家加入，显示死亡状态，**实测不会自动复活**，只能等队友电击器/下一局。

## 根因（已确认，不是 si_hud 复活体系的 bug）

**l4dmultislots 扩展的 cvar 配置行为**：

- `l4d_multislots_alive_bot_time "30"`（2026-08-03 从 0 改 30，当时为解"24 人满员时新人卡'无法生成生还者Bot'"）：新玩家第 5+ 位中途加入且场上**无存活 bot 可接管** + 幸存者离开起始安全屋 ≥30s → 玩家**以死亡状态入队**，提示"生还者已开始游戏一段时间,请等待救援或复活"（translations/l4dmultislots.phrases.txt）
- `l4d_multislots_dead_bot_method 1`：死尸入队 = 死亡状态（无尸体，等待救援室）
- 死尸入队**不触发 player_death 事件** → si_hud 复活体系（免费命→积分复活→躺尸）完全不知情 → 不会自动复活
- `l4d_multislots_no_second_free_spawn 0`：重连玩家不受影响（Free Spawn 总是存活 bot），只有全新玩家中招

## 修复：si_hud v1.12.1 入队即死兜底复活

- 新变量 `g_iJoinCheckLeft[MAXPLAYERS+1]` + `Timer_JoinDeadCheck`（OnClientPutInServer 启动：3s 起步，每 2s 重试，共 12 次 ≈ 27s 窗口）
- 判定：入队即死（`g_iDeaths[client]==0` 说明非正常死亡流程）且**场上还有存活队友**（团灭中不干预，round restart 会重置）→ `L4D_RespawnPlayer` + 清尸体 + 传送（复用 `Timer_RespawnTeleport` → **自动发复活套装** forward）→ 不扣免费命
- 边界：正常死亡（g_iDeaths>0）不干预；倒地 bot 接管（IsPlayerAlive=true）不触发；断开 userid 失效自停；NO_MAPCHANGE 防换图悬挂
- 已部署：`sm plugins reload l4d2_si_hud` → Version 1.12.1 ✓（2026-08-04 21:50）

## 遗留

- 待玩家实测：中途加入是否正常存活加入
- 源码已改未 git commit（/opt/gameservers/l4d2/data/addons/sourcemod/）

相关：[[l4d2-revive-system-v1120]]（复活体系）、[[l4d2-defib-fix-and-player-limit]]（alive_bot_time 由来）、[[l4d2-auto-respawn-conflict]]（复活类插件互斥）
