---
name: l4d2-si-pinnable-target-fix
description: AI_HardSI v5.19.0（2026-08-15）—— 控制型特感倒地跳跃 bug 修复，四种 pin-SI 全部优先站立目标
metadata: 
  node_type: memory
  type: project
  originSessionId: cb71801d-ad03-4acc-97ea-96be15858743
  modified: 2026-08-15T16:06:49.656Z
---

# 控制型特感倒地跳跃 bug 修复（v5.19.0，2026-08-15 已部署）

用户反馈："特感尤其是 jockey 当目标倒地后就会在他附近跳而不是去追下一个"。

## 根因

**共享根因**（Hunter/Jockey/Charger/Smoker 四种控制型特感）：
- `ACT_AcquireClosestTarget` → `GetClosestSurvivor`（hardcoop_util.sp:239）只判 `IsPlayerAlive`（引擎对倒地者返回 true），不过滤 `m_isIncapacitated`
- 控制型特感的 leap/charge/tongue 分支缺 `CND_TargetIsPinnable` 门控 → 持续锁最近倒地者，原地跳/冲/拉（无效攻击循环）

**为什么 Boomer/Spitter 不受影响**：非控制型特感，呕吐/喷酸对倒地者有效。

## 修复（v5.19.0）

### 1. 基础设施（hardcoop_util.sp + bt_common.inc）

新增 `GetClosestPinnableSurvivor()`（hardcoop_util.sp，`SI_IsPinnable` 后）：
```sourcepawn
// v5.19: 最近的【可扑/可骑】生还者（优先站立未控，兜底任意存活）
stock int GetClosestPinnableSurvivor(const float referencePos[3], int excludeSurvivor = -1) {
    float survivorPos[3];
    int closestPinnable = -1;
    int closestAny = -1;
    float distPinnable = -1.0;
    float distAny = -1.0;
    for (int client = 1; client <= MaxClients; client++) {
        if (!IsSurvivor(client) || !IsPlayerAlive(client) || client == excludeSurvivor)
            continue;
        GetClientAbsOrigin(client, survivorPos);
        float d = GetVectorDistance(referencePos, survivorPos);
        if (distAny < 0.0 || d < distAny) { distAny = d; closestAny = client; }
        if (SI_IsPinnable(client)) {
            if (distPinnable < 0.0 || d < distPinnable) { distPinnable = d; closestPinnable = client; }
        }
    }
    return (closestPinnable > 0) ? closestPinnable : closestAny;
}
```

新增 `ACT_AcquirePinnableTarget()`（bt_common.inc，`ACT_AcquireClosestTarget` 后）：
```sourcepawn
// v5.19: 优先选【可扑/可骑】的最近生还者（站立未控），全倒地时退回最近存活者。
BT_Status ACT_AcquirePinnableTarget(int client) {
    float pos[3];
    GetClientAbsOrigin(client, pos);
    int t = GetClosestPinnableSurvivor(pos);
    if (t > 0) {
        BB_SetInt(client, "target", t);
        return BT_SUCCESS;
    }
    return BT_FAILURE;
}
```

### 2. 行为树替换（四个 bt_*.inc）

全部 `ACT_AcquireClosestTarget` → `ACT_AcquirePinnableTarget`：
- **bt_jockey.inc**：11 处（全部 leap/approach 分支 + harassSeq）
- **bt_hunter.inc**：10 处（9× BT_CreateAction + 1× WallPounce 直接调用）
- **bt_charger.inc**：15 处（全部 charge 分支）
- **bt_smoker.inc**：1 处（closeRangeStrafe 分支）

替换模式（统一加注释）：
```sourcepawn
BT_CreateAction(ACT_AcquirePinnableTarget),  // v5.19: 优先站立目标(倒地不可X)
```

### 3. 版本号

`AI_HardSI.sp` myinfo: `5.8.0` → `5.19.0`

## 部署

- 编译无 error（21 warnings 全是存量）
- 已部署 `plugins/AI_HardSI_bt.smx`（2026-08-15 00:05）
- 已热重载（`sm plugins reload AI_HardSI_bt`），version 5.19.0 确认生效

## 效果

控制型特感（Hunter/Jockey/Charger/Smoker）现在优先攻击站立未控的生还者。全队倒地时才兜底选最近存活者（保持攻击性，不站桩）。

**Why**: `GetClosestPinnableSurvivor` 先扫可 pin 的（`SI_IsPinnable` = 站立 + 未控 + 未挂边），无可 pin 时才返回 `closestAny`（任意存活）。

相关：[[l4d2-ai-hardsi-v57-audit-fix]] [[l4d2-ai-identity-system]]
