---
name: l4d2-pressure-system-removed
description: 压力系统（pressure_tracker + AI 攻击性调制 + tier 战术过滤）全套废弃与清理记录（2026-08-16）—— 替代机制 = tank_wave_mutator 波次突变
metadata:
  node_type: memory
  type: project
  originSessionId: pressure-cleanup-20260816
  modified: 2026-08-16T02:30:00.000Z
---

# L4D2 压力系统整体废弃与清理（2026-08-16）

**背景**：用户拍板"旧版压力值已废弃"。原 SI 压力体系（2026-08-13 批准的
pressure_tracker 计划）被更优设计替代：**特感波次有条件突变为 Tank 波次**
（tank_wave_mutator，详见 [[l4d2-tank-wave-mutator]]）。
云端 agent 方案中凡涉及压力值的内容均以本地废弃为准。

## 旧压力体系组成（已全部清除）

| 组件 | 作用 | 拆除方式 |
|---|---|---|
| pressure_tracker.smx | 全局压力追踪（aggression/tier cvar 生产者） | 已 disabled（8/13），本次删除文件 |
| AI_HardSI v5.8 压力集成 | `_pressure_aggr` 黑板 + Scaled 攻击距离节点 | v5.20.0 移除全部 |
| specialspawner v2.1.0 tier 表 | 冷静期/自杀/补偿/分批按段位 | v2.4.4 移除全部 |
| si_comp v2.5.0 tier 过滤 | 战术模式按段位加权 | v2.7.0 移除，等权随机 |
| 文档/配置 | SI_PRESSURE_PLAN.md / PRESSURE_SYSTEM*.md / pressure_tracker.cfg / reload_pressure.cfg | 删除（备份 /tmp/pressure-cleanup-20260816/） |

## 清理中修复的遗留 bug

**specialspawner 冷静期 12-15s 覆盖 cfg 25-35s**（记忆 [[l4d2-rest-tier-override-bug]] 的
根本问题）：`g_iCurrentPressureTier` 全局默认 = 2 → 即使 pressure_tracker 未加载，
`EnterRest` 也走 `GetRestRangeByTier(2)` 的 12-15s，cfg 设计值从未生效。
v2.4.4 删除 tier 表后 `EnterRest` 直接用 `ss_rest_min/max`（25-35s）→ **设计值回归**。

## 部署状态（2026-08-16 10:20 空服 reload 验证通过）

- specialspawner **v2.4.4** running（hash df804048...）
- si_composition_manager **v2.7.0** running（hash a80a1632...）
- AI_HardSI_bt **v5.20.0** running（hash 746b2941...）
- tank_wave_mutator **v2.4.0** running 联动正常（SS_HoldClearing native 仍在）
- errors 日志 0 新增；`ss_rest_min/max` = 25.0/35.0 ✅

## 行为等价性

- AI_HardSI：Scaled 节点在 cvar 缺失时恒等普通节点（dist ÷ 1.0 = dist），
  Smoker 850 / Spitter 900 / Boomer 300 距离门控值不变 → 零行为变化
- si_comp：tier 过滤删除 → 6 模式等权随机（原 T2 默认下 SIMPLE×3/MODERATE×2/COMPLEX×0，
  有行为变化：COMPLEX 模式现在会出现——用户可接受，tank 突变接管难度调节）
- specialspawner：冷静期/自杀/补偿/分批全部回归 cfg 静态值

## 新压力调节机制（本地现状，勿再引入压力值）

**tank_wave_mutator v2.4.0**（plugins/tank_wave_mutator.smx，源码
scripting/tank_wave_mutator.sp）：
- 10% 随机突变 + 连续 5 波无倒地强制双 Tank + 连续 11 波无 Tank 保底单 Tank
- Tank 波后 3 波冷静期（计数冻结）
- 与 specialspawner 联动：SS_OnWaveRest/SS_OnWaveStart forward + SS_HoldClearing
  挂起清缴（Tank 波清缴条件 = Tank 死亡）
- 就近生成（12 采样 ≥450u 最近点，防待命站桩）

## 相关

- [[l4d2-si-pressure-plan]] — 旧计划（已废弃，仅存档）
- [[l4d2-rest-tier-override-bug]] — 冷静期 bug 记忆（已根除）
- [[l4d2-tank-wave-mutator]] — 新机制
- [[l4d2-ai-identity-system]] — "行为树承担压力调节"拍板（v5.0，压力值被 tank 突变取代）