---
name: l4d2-si-hud-mapchange-wallet-clear
description: "si_hud 换图清可用积分根因——GetMapPrefix 把地图号算进战役前缀，每次换图都触发\"新战役清零\""
metadata: 
  node_type: memory
  type: project
  originSessionId: b01f0a3e-79b4-43b6-becb-40dab023ac75
  modified: 2026-08-12T14:31:55.675Z
---

# si_hud 换图清积分根因（2026-08-03 定位，v1.8.2 修复）

**症状**：打完 c1m1 进 c1m2，可用积分(g_iWallet)/复活币被清 0。

**根因**：`GetMapPrefix` 从第一个 `_` 截断 → "c1m1_hotel"→"c1m1"、"c1m2_streets"→"c1m2"，**地图号混进战役前缀**。于是 OnMapStart 的"新战役判定"(`!StrEqual(prefix, g_sPrevCampaign)`) 在每次换图都触发 → 清钱包+复活币 + `ScoreSave_All()` 把 0 写回存档文件；同时 ScoreLoad_Player 的战役校验（存档 "c1m1" vs 当前 "c1m2"）拒绝恢复 → v1.7.43 的 20s 重连恢复也被挡。**v1.7.28 起官图跨图保留从未真正生效**（设计注释 v1.7.41 "同前缀重开 c2m5→c2m1" 证明意图前缀 = "c2" 不含地图号）。

**修复（v1.8.2）**：
1. GetMapPrefix 重写：截掉 "m<数字>" 标记（"c1m2_streets"→"c1"、"zc1_m1"→"zc1"）或尾部 "分隔符+数字" 段（"l4d_yama_1"→"l4d_yama"）；无标记 → 整图名。缓冲 16→64。
2. 重连恢复加地图变化判定：断线记录当前地图，重连时若地图已变（changelevel 自动重连）→ 窗口放宽到 180s（大三方图加载慢，20s 必丢）；同图重连保持 20s。**⚠ 已废弃（v1.10.0，2026-08-04）：窗口把崩溃重连判成新加入丢钱，见 [[l4d2-si-hud-rejoin-restore]]**。

**注意**：~~三方图轮换每张图前缀不同 → 仍每次换图清零~~ **已废弃（v1.10.1，2026-08-04）**：三方图轮换曾豁免清零（current_mode.txt=custom）；**v1.11.0 再次推翻**（2026-08-04，user 拍板）：三方图也分大图小图——大地图（configs/si_hud_big_maps.txt 清单，默认 dc2/dw/de/hls）战役内保留、换战役清零；小图（无地图号标记）每次换图清零。统一走 GetCampaignKey 战役键，详见 [[l4d2-si-hud-rejoin-restore]] v1.11.0 章节。官图（official + cXm1 等 m1 首图）清零规则不变。

**⚠ 整体废弃（v1.13.0，2026-08-12，user 拍板）**：可用积分跨图**永久保留不再清零**，只钳上限 `si_hud_wallet_max` 30000——本记忆的"新战役清零"、v1.11.0 战役键清零体系全部作废，见 [[l4d2-si-hud-wallet-persistent]]。

相关：[[l4d2-si-hud-scoring]]、[[l4d2-source-code-location-pitfall]]
