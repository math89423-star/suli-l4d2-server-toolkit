---
name: l4d2-hunter-sprint-pounce-fix
description: Hunter v3.3 行为树修复 — 远距离冲刺而非缓慢爬行，进入扑击范围立即下蹲扑击
metadata: 
  node_type: memory
  type: project
  tags: 
    - l4d2
    - hunter
    - ai
    - bt
    - behavior-tree
    - fix
  modified: 2026-07-28T01:56:32.312Z
  originSessionId: 0c8e8543-5be1-47a8-afc7-05c525d94a92
---

# L4D2 Hunter AI 远距离爬行修复 (v3.3)

## 问题

Hunter 在距离生还者较远时（>1000 单位），缓慢爬行过来而不是快速冲向目标扑击。

## 根因（两个 Bug）

### Bug 1: approachFull 强制蹲伏

`approachFull`（v3.2 selector 第 7 分支）把 `ACT_Crouch` 放在 `ACT_ErraticApproach` 之前：

```
approachFull = sequence(crouchSeq, approachSeq)
  crouchSeq = ACT_Crouch       → 按 IN_DUCK，返回 SUCCESS
  approachSeq = acquireTarget  → RUNNING
                + ErraticApproach
```

Hunter **先蹲下再前进**。蹲伏状态下移速约 50%，表现为"缓慢爬行"。

### Bug 2: crouchApproachSeq 无前进移动

`crouchApproachSeq`（第 8 分支）使用 `ACT_StrafeRandom`，该 action 只按 IN_MOVELEFT/IN_MOVERIGHT 横移，**没有 IN_FORWARD**。Hunter 在原地左右横移而不靠近目标。

## 修复：v3.3 sprint→crouch→pounce 流程

### 1. 新增 HunterAct_SprintApproach

远距离（> pounce range）时**站立冲刺**（不蹲伏），全速跑向目标 + 随机 ±30° zigzag：

```sourcepawn
BT_Status HunterAct_SprintApproach(int client) {
    // zigzag 横移 + 朝目标方向前进
    BT_AddButton(client, IN_FORWARD);
    BT_RemoveButton(client, IN_DUCK);  // 关键：确保不蹲伏
    return BT_RUNNING;
}
```

### 2. 新增 crouchPrepSeq（过渡下蹲）

进入扑击范围（≤ pounce range）+ 有 LOS + 未下蹲 → 立刻按 IN_DUCK：

```
crouchPrepSeq = sequence(OnGround, NOT IsDucking, isInRange, HasLOS)
  → ACT_Crouch
```

### 3. 新增 closePounceSeq（近距离直接扑）

距离 ≤ straight_pounce_proximity（200）+ 有 LOS → 直接瞄准扑击（无 Gauss 偏移角，更快反应）。

### 4. 修复 crouchApproachSeq

替换 `ACT_StrafeRandom`（只横移）为 `HunterAct_CrouchApproach`：
- 面向目标前进 (IN_FORWARD)
- 随机左右横移换方向
- 保持下蹲状态 (IN_DUCK)

### 5. Selector 优先级重新编排

```
 1. missEscSeq       — 扑空后逃跳
 2. highPounceSeq    — 抢占高台
 3. narrowPounceSeq  — 窄巷直扑
 4. openApproachSeq  — 开阔地侧翼
 5. semiApproachSeq  — 半开阔贴墙
 6. closePounceSeq   — [v3.3] 近距离直扑 (≤200)
 7. fastPounceSeq    — 标准扑击 (蹲伏+有LOS+范围内)
 8. crouchPrepSeq    — [v3.3] 进入范围→立刻下蹲
 9. sprintApproachSeq — [v3.3] 远距离→全速冲刺
10. crouchApproachSeq — [v3.3] 无LOS→蹲伏前进+横移
11. wander           — 漫游
```

## sprint→crouch→pounce 完整流程

```
Tick N:   Hunter 1500u 远 → branch 9 (sprint) 激活，全速跑向目标
Tick N+1: 进入 1000u 范围 → branch 8 (crouchPrep) 激活，按 DUCK
Tick N+2: FL_DUCKING 已设 → branch 7 (fastPounce) 激活，POUNCE!
```

## 配置

| cvar | 值 | 说明 |
|------|-----|------|
| `ai_fast_pounce_proximity` | 1000 | 扑击范围阈值（BT 用此值判断） |
| `ai_straight_pounce_proximity` | 200 | 近距离直扑阈值 |

## 编译部署

```bash
cd /opt/gameservers/l4d2/data/addons/sourcemod/scripting/AI_HardSI_optimized
../spcomp AI_HardSI.sp -o../compiled/AI_HardSI_bt.smx -i../include
cp ../compiled/AI_HardSI_bt.smx ../plugins/AI_HardSI_bt.smx
# RCON: sm plugins reload AI_HardSI_bt
```

## 备份

- `plugins/AI_HardSI_bt.smx.bak.v33_hunter_fix` — v3.2 原版（41668 bytes）
- `scripting/AI_HardSI_optimized/bt_hunter.inc.bak.v32` — v3.2 源码

## 回滚

```bash
cp plugins/AI_HardSI_bt.smx.bak.v33_hunter_fix plugins/AI_HardSI_bt.smx
# RCON: sm plugins reload AI_HardSI_bt
```

## 相关记忆

- [[l4d2-tank-ai-fix]] — Tank AI bhop 修复（同插件）
- [[l4d2-specialspawner-config]] — specialspawner cvars
- [[l4d2-si-composition-manager]] — SI 组合管理器
- [[l4d2-weapon-attributes]] — 武器属性架构
