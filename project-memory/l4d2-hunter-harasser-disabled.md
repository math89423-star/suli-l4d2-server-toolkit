---
name: l4d2-hunter-harasser-disabled
description: Hunter 骚扰者模式已禁用，改为纯攻击性 AI（v5.21）
metadata: 
  node_type: memory
  type: project
  originSessionId: 2fcd2e47-a027-4c00-9a32-16e0e6209504
  modified: 2026-08-14T17:28:32.457Z
---

# Hunter 骚扰者模式禁用（v5.21）

**问题根因**：用户反馈 Hunter 体感与原版无差异，经排查发现骚扰者机制过度限制了 Hunter 的攻击性。

## 原机制问题

1. **角色分配机制**：
   - 只有 Boomer/Smoker 能成为发起者（INITIATOR）
   - Hunter **100% 被分配为骚扰者（HARASSER）**
   - 日志验证：`grep "assigned.*INITIATOR" L20260815.log` 只看到 Boomer/Smoker

2. **骚扰者行为过于保守**：
   - 保持 600-1000u 距离游走
   - 600u 内：原地蹲守（v5.19 刚改的）
   - 1000u 外：接近到 800u
   - 600-1000u：横移骚扰
   - **只有发起者得手或齐射令下达后才解除限制**

3. **行为树优先级问题**：
   - 骚扰模式是分支4，排在几乎所有扑击分支之前
   - Hunter 大部分时间都在"等待发起者"，而不是主动扑击

## 解决方案：完全禁用骚扰模式 + 增加扑击距离 + 修复角度偏移 bug（方案 C）

**文件**：`bt_hunter.inc`, `bt_common.inc`

**修改 1：禁用骚扰模式**
1. 注释掉 `harassSeq` 的创建（730-737 行）
2. 注释掉根节点对 `harassSeq` 的引用（1067 行）

**修改 2：增加扑击距离 1000u → 1500u**
1. 树构建器 fallback：`fPounceRange = 1500.0`（701 行）
2. cvar 创建：`ai_fast_pounce_proximity = 1500`（1097 行）
3. cvar 强制值：`hCvar.SetFloat(1500.0)`（1102 行）
4. 引擎准备距离：`hunter_pounce_ready_range = 1500`（1113 行）

**修改 3：修复高斯角度偏移 bug（根本原因）**
- **问题**：`ACT_GaussianAimOffset` 和 `HunterAct_WideGaussOffset` 从 `GetClientEyeAngles()` 读取角度，但前一个节点 `ACT_SnapAimToBlackboardTarget` 写的是 BT 累加器 `g_fBT_Angles[]`，同一 tick 内引擎 EyeAngles 还是旧值
- **结果**：偏移加到"上一 tick 的陈旧视角"上，覆盖掉前面节点刚算好的精确瞄准 → **观感直线扑击，随机偏移完全失效**
- **修复**：改为从累加器读取（如果已设置）→ 加偏移 → 写回累加器
- **影响范围**：
  - `bt_common.inc`: `ACT_GaussianAimOffset`（所有特感的标准高斯偏移）
  - `bt_hunter.inc`: `HunterAct_WideGaussOffset`（开阔地形 ±35° 大偏移）

**效果**：
- Hunter 不再保持距离等待发起者
- 从 1500u 距离就开始扑击（原 1000u）
- **扑击角度真正随机偏移 ±15°（标准）或 ±35°（开阔地形），不再直线扑击**
- 更激进的攻击频率，类似别的服务器的表现
- 保留所有其他增强功能（墙面二段跳、欺骗性跳跃、高位扑、地形适应等）

## 部署状态

- **编译时间**：2026-08-15 01:27（修复角度偏移 bug 后最终版本）
- **部署路径**：`/opt/gameservers/l4d2/data/addons/sourcemod/plugins/AI_HardSI_bt.smx`
- **重载方式**：touch 插件文件，SourceMod 自动检测重载
- **待验证**：
  1. Hunter 是否持续扑击（频率提升）
  2. 扑击角度是否有明显随机偏移（不再直线）
  3. 1500u 扑击距离是否会导致"按了但没扑出去"（如果引擎硬限制小于 1500u）

## 后续监控

如果效果仍不理想，可能还需要调整：
1. 扑击距离门控（当前 1000u）
2. Sprint 接近的触发条件
3. 行为树其他分支的优先级

**Why**：骚扰者机制设计初衷是"战术配合"，但实际效果让 Hunter 变得过于被动。

**How to apply**：Hunter 相关修改优先考虑攻击性，避免过度防御或等待机制。
