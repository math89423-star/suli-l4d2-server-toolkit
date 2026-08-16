# AI_HardSI v5.20 更新日志

**发布时间**：2026-08-16
**核心变更**：🗑️ 移除压力系统集成（pressure_tracker 已废弃，用户拍板由 tank_wave_mutator 波次突变替代）

---

## 背景

旧压力体系（pressure_tracker + sm_pressure_aggression/tier）已废弃（2026-08-16 用户拍板）。
新压力调节机制 = **tank_wave_mutator 波次突变**（10% 随机突变 + 连5波无倒地强制双Tank +
连11波无Tank保底单Tank + Tank波后3波冷静期），由 specialspawner 层独立负责，AI 行为层
不再感知任何压力值。

## 移除内容

| 位置 | 移除项 |
|---|---|
| AI_HardSI.sp | `g_hCvarPressureAggression` / `g_fPressureAggression` 全局变量 |
| AI_HardSI.sp | `TryBindPressureTracker()` 懒绑定 + `OnAllPluginsLoaded` + `OnPressureAggressionChanged` |
| AI_HardSI.sp | 4 个 scale helper（ScaleAttackRange/ScaleRetreatDistance/ScaleCooldown/ScaleApproachThreshold） |
| AI_HardSI.sp | Event_PlayerSpawn 黑板 `_pressure_aggr` 注入 |
| bt_common.inc | `BT_CreateIsTargetInRange_Scaled` 工厂 + `CND_IsTargetInRange_Scaled` 实现 |
| bt_smoker.inc ×6 | `BT_CreateIsTargetInRange_Scaled(850)` → `BT_CreateIsTargetInRange(850)` |
| bt_spitter.inc ×6 | `BT_CreateIsTargetInRange_Scaled(900)` → `BT_CreateIsTargetInRange(900)` |
| bt_boomer.inc ×7 | `BT_CreateIsTargetInRange_Scaled(300)` → `BT_CreateIsTargetInRange(300)` |

## 行为影响

**零行为变化**：压力 cvar 早已不存在（重启清除），`_pressure_aggr` 恒 1.0，
`scaledDist = baseDist ÷ 1.0 = baseDist` —— Scaled 节点在运行态与普通节点数学等价。
本次清理仅删除死代码，攻击距离门控值不变（Smoker 850 / Spitter 900 / Boomer 300）。

## 部署

- 编译：spcomp64 0 error
- 部署：`compiled/AI_HardSI.smx` → `plugins/AI_HardSI_bt.smx`
- reload：`sm plugins reload AI_HardSI_bt`（空服）

## 相关

- [[l4d2-pressure-system-removed]] — 全套压力系统清理记录（specialspawner/si_comp/文档/插件）
- tank_wave_mutator v2.4.0 — 新压力调节机制（波次突变 Tank）