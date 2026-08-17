---
name: l4d2-si-tactical-v4
description: 特感 v4.0 战术配合体系 — si_comp_active_mode 模式下发 + 6 模式配合技 + 个体进攻性增强
metadata: 
  node_type: memory
  type: project
  originSessionId: 194960a6-af6b-400b-8cbd-a3c356e75d4a
  modified: 2026-07-31T11:57:51.771Z
---

# L4D2 特感战术 v4.0（2026-07-31）

**插件：** `AI_HardSI_bt.smx`（v4.0）+ `si_composition_manager.smx`（v2.4）
**Commit：** `1a0d8ff`（已推送 master）

## 核心架构：模式下发 → 行为树配合

- `si_composition_manager` 每次模式切换写入共享 cvar **`si_comp_active_mode`**（0-5 普通模式，6=Tank 巨兽协同，-1=未激活）
- `AI_HardSI` 的 `hardcoop_util.sp` 每秒读一次（`SI_UpdateCoordination` 里，含 FindConVar 重试兜底 —— A 开头比 s 开头先加载，OnPluginStart 时可能拿不到句柄）
- 行为树用 `CND_IsMode(N)` / `CND_IsModeAny(A,B)` 走配合分支；manager 未装时 cvar=-1 → 全分支 FAIL → 落回默认行为（优雅降级）

## 6 模式配合技（行为树分支）

| 模式 | 配合 |
|------|------|
| 0 钢铁洪流 | Charger 900u 直冲开路 → 撞中 pin 广播 → Hunter/Jockey 集火被撞者 |
| 1 暗影锁链 | Smoker 拉中 → Jockey 骑同一人 + Boomer 吐被拉者 + Spitter 吐脚下防救 |
| 2 地空协同 | Hunter 高位扑概率 65%（默认 35%，`HunterCond_HighPounceChance`）→ Charger 冲被扑者 |
| 3 生化危机 | Boomer 吐中 → Spitter 预判吐 + Smoker 拉被喷者（`SmokerAct_AcquireBoomedTarget`） |
| 4 猎手集群 | 多 Hunter 协同分散目标（**排除集火捷径**，防 dogpile）+ CircleFlank 绕后 |
| 5 均衡演武 | 无覆写 |
| 6 巨兽协同 | **全员分散控制不同目标**（也排除集火捷径）—— 不是集火 Tank 的目标！Tank 抗压，SI 锁人；Spitter 吐 Tank 追击路线（`SpitterAct_SpitTankCover`） |

## 协同系统关键机制（hardcoop_util.sp）

- **pin 广播**：`SI_UpdateCoordination`（1s timer）边沿检测 `g_bSIPreviouslyPinning`，某 SI 刚 pin 住人 → `g_iSIPinTarget` + 3s 有效 + 开攻击窗口。拉中/扑中/撞中/骑中都覆盖
- **集火 vs 分散**：`SI_GetCoordinatedTarget` 窗口内优先返回 pin 目标，**mode 4/6 除外**（分散分配）
- **集结进攻**：3+ SI 距离生还者 <900u 且窗口过期 → 自动开窗口
- 窗口默认 5.5s（`ai_coordination_window`）

## 个体进攻性（所有模式生效）

- **Smoker**：孤立度优先选目标（`SMOKER_ISOLATION_THRESHOLD 350`，到最近队友距离），天然命中"掉队/冲太快"的人；`SmokerAct_ApproachOutside` 站到目标远离队伍一侧，把人拉离队伍。**不是目标记忆**（用户明确否定"盯一人拉到底"）
- **Jockey**：`JockeyAct_SteerRide` 骑乘 steering，把人往远离队伍中心拖
- **Spitter**：`SpitterAct_PredictiveSpit` 预判吐（速度>50 时吐行进路线前方 0.8s），静止才吐脚下
- **Boomer**：narrow 地形 `ACT_AmbushHold` 伏击，原地等目标进 300u
- **Charger**：`ChargerAct_AcquireAcidTarget` 冲站在酸液里（`spit_acid` 实体）的人；coordSeq 前置到 root 第 4 位（原第 10 位被地形分支挡住）
- **Hunter**：sprint↔crouch +150u hysteresis（原 1000u 边界反复横跳）

## 新共享节点（bt_common.inc）

`CND_IsMode` / `CND_IsModeAny` / `ACT_AcquirePinTarget` / `ACT_AcquireCoordTarget` / `ACT_CircleFlank`（120°→30° 渐进大弧线绕后）/ `ACT_AmbushHold`

## 部署注意

- 换图生效（不重启服务器）
- 节点估算 ~550 < BT_MAX_NODES 768，换图后查日志 `exceeded BT_MAX_NODES`
- 备份：`plugins/AI_HardSI_bt.smx.bak.20260731_v4`
- 相关：[[l4d2-si-composition-manager]] [[l4d2-specialspawner-config]] [[l4d2-source-code-location-pitfall]]
