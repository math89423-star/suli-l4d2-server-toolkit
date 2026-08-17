---
name: l4d2-ai-hardsi-v510-hunter-stall-fix
description: AI_HardSI_bt v5.10（2026-08-14）— Hunter fastPounceSeq 站桩修复，v5.9 遗漏的最后一个 Cooldown 站桩 bug
metadata: 
  node_type: memory
  type: project
  originSessionId: 992ff90c-bbfe-4f42-b640-c839e90d7506
  modified: 2026-08-14T08:42:37.946Z
---

# AI_HardSI_bt v5.10（2026-08-14，已部署待 reload）

用户报告"Hunter 依然会远距离站桩"→ 审计发现 **`fastPounceSeq` 是 v5.9 遗漏的最后一个 Cooldown 站桩 bug**。

## 根因

**bt_hunter.inc:504** `int cooldownAttack = BT_CreateCooldown(1.0, attackActionSeq);` 制造站桩：

1. Hunter ≤500u + 蹲姿 + LOS → `fastPounceSeq`（分支7）条件满足
2. `Cooldown(1.0)` 冷却期返回 `FAILURE` → 整个 Sequence FAIL
3. Selector 反复选中分支7又反复 FAIL（条件仍满足）→ **冷却期内站着不动，每1秒扑一下**

这和 v5.7 `crouchPrepSeq` 站桩、v5.9 其他 6 个扑击分支站桩是**完全相同的模式**。

## 为什么 v5.9 遗漏

v5.9 已经修复了 6 个扑击分支（narrowPounce / openStrat0/1 / closePounce / coordPounce / disruptionSeq），注释明确写了原理（line 409-414），但 **`fastPounceSeq` 的 Cooldown 包裹被遗漏**。

## 修复（v5.10）

**移除 Cooldown 包裹，直接合并攻击序列**：

```sourcepawn
// v5.10 FIX: 移除 Cooldown 包裹 — fastPounceSeq 是 v5.9 遗漏的最后一个
// 站桩 bug。引擎自带扑击冷却（z_lunge_interval 默认 0.5s），插件侧不需要再锁。
int attackActionSeq = BT_CreateSequence(5,
    BT_CreateAction(ACT_SnapAimToBlackboardTarget),
    BT_CreateAction(HunterAct_OverheadOffset),
    BT_CreateAction(ACT_GaussianAimOffset),
    BT_CreateAction(ACT_QueueLunge),
    BT_CreateAction(ACT_SignalAttack)    // 原 signalCoord 合并
);

// 树构建
BT_AddChild(fastPounceSeq, pounceInnerSeq);
BT_AddChild(fastPounceSeq, attackActionSeq);  // 直接添加，无 Cooldown 包裹
```

原代码：
- `cooldownAttack = Cooldown(1.0, attackActionSeq)`
- `signalCoord = ACT_SignalAttack`
- 分别添加到 fastPounceSeq

新代码：
- `attackActionSeq` 直接包含 5 个 Action（含 SignalAttack）
- 直接添加到 fastPounceSeq，无 Cooldown 包裹

## 编译部署

```bash
cd /opt/gameservers/l4d2/data/addons/sourcemod/scripting/AI_HardSI_optimized
../spcomp AI_HardSI.sp -o../compiled/AI_HardSI_bt.smx -i../include
cp ../compiled/AI_HardSI_bt.smx ../plugins/AI_HardSI_bt.smx
# RCON: sm plugins reload AI_HardSI_bt
```

- 编译: 13 warnings（存量未使用符号），66K
- 部署: 2026-08-14 16:41，已装盘
- **待 reload**（服务器当前空闲，但遵守静默规则等用户指示）

⚠️ **reload 副作用**：在场 bot BT 绑定重置 → 原版 AI 接管直到重生。

## 验证方法

`ai_debug 1` 观察 Hunter 分支分布：
- **修复前**: 分支 7 占比高但站着不扑
- **修复后**: 分支 7 触发后立即扑击，无 1 秒站桩

实战：进入扑击范围后应连续扑击（引擎冷却 0.5s），不再有站桩间隔。

## 相关修复历史

- v5.7: `crouchPrepSeq` 站桩修复（Cooldown 包裹 ACT_Crouch）
- v5.8: 回滚 v5.7 冷却机制（导致新站桩），改持续按 DUCK
- v5.9: 修复 6 个扑击分支 Cooldown 站桩
- **v5.10: 修复最后遗漏的 `fastPounceSeq` Cooldown 站桩**

相关：[[l4d2-ai-hardsi-v57-audit-fix]] [[l4d2-hunter-sprint-pounce-fix]] [[l4d2-si-ai-audit-v56]] [[l4d2-ai-hardsi-engine-tuning]]
