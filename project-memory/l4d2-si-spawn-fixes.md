---
name: l4d2-si-spawn-fixes
description: AI_HardSI v4.0.1 — Charger 出生对空气冲 + Hunter 出生蠕动两个回归修复（2026-08-02 部署）
metadata: 
  node_type: memory
  type: project
  originSessionId: 61f43fa0-69b1-454d-9bd3-8b40d1e789d6
  modified: 2026-08-01T16:19:30.622Z
---

# AI_HardSI v4.0.1 出生修复（2026-08-02 部署，51668 bytes）

## Bug 1: Charger 出生对空气冲一次

**根因**：`bt_charger.inc` 的 coordSeq（攻击窗口分支）**无距离/LOS 限制**——攻击窗口（5.5s）常被其他 SI 的 ability_use / pin 广播打开，Charger 出生瞬间 charge 技能即 ready（m_timestamp 是过去值），一出生就朝窗口内协同目标（可能 2000u+ 外/隔墙）释放 charge，观感 = "对空气冲一次"。

**修复**（两处）：
1. coordSeq 补 `CND_HasLOS + BT_CreateIsInRange(fChargeProx)`（与其他 charge 分支一致）。
2. 新增 `CND_ChargerSpawnProtect`：ghost→unghost 边沿检测（`L4D_IsPlayerGhost`），unghost 后 2s 内 SUCCESS → 根 selector 第 0 位停在 `ChargerAct_BlockCharge`（持续推后 m_timestamp，引擎 AI 也释放不了），2s 后 FAIL 恢复正常战术。

**坑**：ghost 查询 native 是 `L4D_IsPlayerGhost`（left4dhooks_stocks.inc 的 stock，读 m_isGhost），**没有** `L4D2_IsPlayerGhost`——直接编译报 undefined symbol。

## Bug 2: Hunter 运出复活后缓慢蠕动

**根因**（两个叠加）：
1. **v4.0 迟滞死区**：sprintApproachSeq 边界被推到 `fPounceRange+150`(1150)，但 crouchPrepSeq 仍是 `fPounceRange`(1000)。出生运出点常落在 1000–1150u → 冲刺/下蹲分支都不接管 → 落进 crouchApproachSeq。
2. **crouchApproachSeq 无条件按 IN_DUCK**：蹲伏移速 ~50%，从 800u 外蹲爬 6-8 秒才进扑击范围 = "蠕动"。

**修复**：
1. sprintApproachSeq 边界改回 `fPounceRange`（迟滞本意防 sprint↔crouch 抖动，代价已被修复 2 消除）。
2. `HunterAct_CrouchApproach` 增加全局 `g_fHunterPounceRange`（tree builder 从 ai_fast_pounce_proximity 缓存）：距离 > 扑击范围 → `BT_RemoveButton(IN_DUCK)` 站立快跑蛇形；范围内且已蹲才保持蹲（潜行接近）。

## 验证

- 编译 `../spcomp AI_HardSI.sp -o../compiled/AI_HardSI_bt.smx -i../include`，部署名必须是 AI_HardSI_bt.smx（产物名 ≠ 部署名坑，见 [[l4d2-ptg-dorstate-crash-fix]]）
- reload 后 sm plugins info 显示 Version 4.0.1，errors 日志零新增（[[l4d2-si-composition-timing-pitfall]] 同款验证法）

## 备份 / 回滚

- `scripting/AI_HardSI_optimized/bt_charger.inc.bak.20260802`、`bt_hunter.inc.bak.20260802`
- `plugins/AI_HardSI_bt.smx.bak.20260802_pre_spawnfix`
- 回滚：`cp plugins/AI_HardSI_bt.smx.bak.20260802_pre_spawnfix plugins/AI_HardSI_bt.smx` + reload

相关：[[l4d2-hunter-sprint-pounce-fix]] [[l4d2-si-tactical-v4]] [[l4d2-ptg-dorstate-crash-fix]]
