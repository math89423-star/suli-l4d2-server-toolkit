# AI_HardSI_bt v5.10 — Hunter 站桩修复（2026-08-14）

## 问题

用户报告："Hunter 依然会远距离站桩"

## 根因

**`fastPounceSeq`（分支7）遗漏 v5.9 的 Cooldown 移除修复** — 这是 v5.9 修复其他 6 个扑击分支后唯一残留的站桩 bug。

### 站桩机制

1. Hunter 进入扑击范围（≤500u）+ 蹲姿 + 有 LOS
2. `fastPounceSeq` 前置条件满足，selector 选中分支 7
3. `Cooldown(1.0)` 在冷却期返回 `FAILURE`
4. 整个 `fastPounceSeq` 失败，但 selector **停留在分支 7**（条件仍满足）
5. 下一 tick 重复 → **冷却期内站着不动，每 1 秒扑一下**

这和 v5.7 修复的 `crouchPrepSeq` 站桩、v5.9 修复的其他扑击分支站桩是**完全相同的模式**。

### 为什么 v5.9 遗漏了这个

v5.9 已经修复了 6 个扑击分支：
- ✅ `narrowPounceSeq`
- ✅ `openStrat0_WidePounce`
- ✅ `openStrat1_ErraticPounce`
- ✅ `closePounceSeq`
- ✅ `coordPounceSeq`
- ✅ `disruptionSeq`

但 **`fastPounceSeq` 的 Cooldown 包裹被遗漏了**。

## 修复（v5.10）

**bt_hunter.inc:497-511**

```sourcepawn
// v5.10 FIX: 移除 Cooldown 包裹 — fastPounceSeq 是 v5.9 遗漏的最后一个
// 站桩 bug：冷却期内前置条件满足但 Cooldown FAIL → 整支 FAIL → selector
// 反复选中分支7又反复 FAIL = 站着不动。引擎自带扑击冷却（z_lunge_interval
// 默认 0.5s），插件侧不需要再锁。直接合并攻击序列到 fastPounceSeq。
int attackActionSeq = BT_CreateSequence(5,
    BT_CreateAction(ACT_SnapAimToBlackboardTarget),
    BT_CreateAction(HunterAct_OverheadOffset),
    BT_CreateAction(ACT_GaussianAimOffset),
    BT_CreateAction(ACT_QueueLunge),
    BT_CreateAction(ACT_SignalAttack)    // 原 signalCoord 合并
);
```

**bt_hunter.inc:631-633** — 树构建简化

```sourcepawn
BT_AddChild(fastPounceSeq, pounceInnerSeq);
BT_AddChild(fastPounceSeq, attackActionSeq);  // 直接添加，无 Cooldown 包裹
```

## 编译

```bash
cd /opt/gameservers/l4d2/data/addons/sourcemod/scripting/AI_HardSI_optimized
../spcomp AI_HardSI.sp -o../compiled/AI_HardSI_bt.smx -i../include
```

- **编译输出**: 13 warnings（存量未使用符号，无影响）
- **文件大小**: 66K（与 v5.9 相同）
- **部署时间**: 2026-08-14 16:41

## 部署

```bash
cp scripting/compiled/AI_HardSI_bt.smx plugins/AI_HardSI_bt.smx
# RCON: sm plugins reload AI_HardSI_bt
```

⚠️ **reload 副作用**：在场 bot 的 BT 绑定重置 → 原版 AI 接管直到重生。

## 验证方法

开启 `ai_debug 1`，观察 Hunter 的 `g_iBTLastWinningChild` 分布：

- **修复前**: 分支 7（fastPounceSeq）占比异常高，但 Hunter 站着不扑
- **修复后**: 分支 7 触发后应立即扑击，无站桩停顿

实战观察：
- Hunter 进入扑击范围后应**连续扑击**（引擎冷却 0.5s），不再有 1 秒站桩间隔
- 远距离应保持 sprint（分支 9）或 crouchApproach（分支 10），不在扑击范围内站立

## 相关修复历史

- **v5.7**: 修复 `crouchPrepSeq` 站桩（Cooldown 包裹 ACT_Crouch）
- **v5.8**: 回滚 v5.7 的冷却机制（导致新站桩），改为持续按 DUCK
- **v5.9**: 修复 6 个扑击分支的 Cooldown 站桩 bug
- **v5.10**: 修复最后一个遗漏的 `fastPounceSeq` Cooldown 站桩 bug

## 相关记忆

- [[l4d2-ai-hardsi-v57-audit-fix]] — v5.7 LOS 迁移 + crouchPrep 站桩修复
- [[l4d2-hunter-sprint-pounce-fix]] — v3.3 sprint→crouch→pounce 流程
- [[l4d2-si-ai-audit-v56]] — v5.6 全特感呆傻审计
- [[l4d2-ai-hardsi-engine-tuning]] — Tank/Charger/Spitter 站桩修复历史
