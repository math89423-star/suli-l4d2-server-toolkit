---
name: l4d2-killfeed-mapend-reward
description: "si_hud v1.9.3（2026-08-03 用户拍板）：击杀聊天播报改 KILL/HEADSHOT 词 + 去特感中文昵称；过关奖励每人 2000 积分（替代 survivor_transition 回满血,该插件已禁用）"
metadata: 
  node_type: memory
  type: project
  originSessionId: f3dda53e-a801-4112-9add-65c88345feb2
  modified: 2026-08-03T08:16:25.820Z
---

# 击杀播报改版 + 过关奖励（si_hud v1.9.3,2026-08-03）

## ① 击杀聊天播报(Y 键可见,PrintToChatAll)

**用户定稿格式**：`Rochelle  [M16] HEADSHOT BOOMER`

- 动作词：爆头 = `HEADSHOT`、普通 = `KILL`（例: `Rochelle  [M16] KILL BOOMER`）
- 特感只显示英文名（BOOMER/HUNTER/…），**去掉中文昵称**（烟鬼/胖子/猎人/口水/猴子/牛/女巫/坦克）— `GetSIName` 统一改（聊天/击杀卡/横幅/HP 条全部生效）
- Witch 聊天播报同改（`WITCH` 不再带"女巫"，suffix 的"爆头"后缀删除）
- 保留后缀：近战" 近战"、Tank" ★"/" 近战 ★"（爆头不再有中文"爆头"后缀，由 HEADSHOT 词体现）
- 击杀卡/横幅中文标题（"爆头击杀"等）保留不变

## ② 过关奖励（替代过关回满血）

- **l4d2_survivor_transition（豆瓣酱）已禁用**（2026-08-03）：它 hook `map_transition`（进安全门）把站立玩家拉到 100 血（`IsStand 100`）= 用户说的"过关回满血"。已改名 `.disabled` + RCON unload（连带死亡/倒地玩家过关血量设置也由引擎自管）
- si_hud `Event_MapTransition` 新增：每人 `g_iWallet += si_hud_mapend_reward`（默认 **2000**，0=关闭），`PrintToChatAll` 播报 `[过关] 每人获得 2000 积分奖励！`（用户要求 Y 键聊天框可见）
- 奖励逻辑独立于 scoreboard 开关（不依赖 g_cvScoreboardEnable）
- ✅ 血量跨图保留 = **L4D2 原版行为**（用户纠正：原版就是带状态进下一关，回满血才是 survivor_transition 插件加的）。禁用插件后无需任何快照恢复，残血/倒地次数自然跨图保留

## 状态

- ✅ 2026-08-03 16:15 热重载生效（unload survivor_transition + reload si_hud）；版本号已校正 1.9.3
- 待玩家实测：击杀爆头聊天格式、过关奖励入账+播报
- 未 commit git

相关：[[l4d2-si-hud-scoring]]（计分体系）[[l4d2-ptg-disabled]]（同类禁用模式）[[l4d2-respawn-gear]]（复活套装）
