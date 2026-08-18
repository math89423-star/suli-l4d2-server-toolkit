---
name: l4d2-si-spawn-hardgate-softscore-v6
description: specialspawner v6.0.0 — 云端调研落地（Hard Gate + Soft Score + 出生目标注入 + 行动进展看门狗），2026-08-18
metadata:
  node_type: memory
  type: project
  modified: 2026-08-18
---

# specialspawner v6.0.0：SS 刷点重构（对照云端调研报告落地）

任务书：`project-memory/l4d2-si-spawn-research-plan.md`（D1-D3 三大矛盾调研）。
云端交付结论 + 本实现改动对照，全部落在 `scripting/specialspawner.sp`（v5.33.0 → 6.0.0）。

## 核心判断（调研 §1/§4/§9/§28）

**不要用 "Nav reachable && LOS && Flow ∈ [a,b]" 三硬条件 AND**（极端图饿死 → 垃圾 fallback）。
正确分层：**Hard Gate（永不可破）+ Soft Score（取最优）**；幽灵主要靠**出生目标注入**
（`L4D2_CommandABot ATTACK → 短暂后 RESET`），**不是**靠距离/LOS 硬筛。
"出生没直接 LOS" ≠ 幽灵；"不知道打谁 + Nav 走不通"才是幽灵。

## D1-D3 落地答案（代码对应）

| 调研题 | 结论 | 实现 |
|---|---|---|
| D1 有无 Nav&&LOS&&Flow 三硬条件成熟算法 | 无；且本身不是最优架构 | `SISpawn_FindPosition`（Hard Gate + Soft Score），去掉 A/B 分档与"任意最近点"保底 |
| D2 全失败牺牲谁 | 先放宽 flow → concealment/距离 → 绝不打破 hull/nav reachable/face 250 | Hard Gate 含 euclid≥250、NavArea/OUTSIDE/FLOW_BLOCKED/NAV_BLOCKER、Hull、ground、infected NavPath；flow 与隐藏度只进 Soft Score |
| D3 失败是否扣波次预算 | 不扣；失败=欠账+重采样 | `g_iBatchDebt` + `tmrCatchup`（首发后 1s 一次性补），`SpawnReplacement` 失败不扣 reserve（沿用） |

## 一、Hard Gate（`SISpawn_ScanCandidates` 内，无任何 fallback 可突破）

候选点来自 `L4D_GetRandomPZSpawnPosition`（Director 先给合法 PZ），再逐项硬筛：

1. `Euclid ≥ ss_spawnrange_guard_min`（250，全队 3D 距离，防贴脸不变式 v1.3.8）
2. `L4D_GetNearestNavArea(p, 300, …, teamID=INFECTED)` 非 null
3. `L4D_GetNavArea_AttributeFlags` 不含 `OUTSIDE_WORLD / FLOW_BLOCKED / NAV_BLOCKER`
4. `SISpawn_HullClear`（按 class 尺寸 hull trace，Charger 更大；动态门/车/临时 prop 全挡）
5. `SISpawn_HasGroundSupport`（向下 hull trace 命中，防悬空/虚空）
6. `L4D2_NavAreaBuildPath(nav, targetNav, navPathMax, TEAM_INFECTED, false)` —— infected 路径可达 intended target

> 不用 `L4D2_IsReachable`（幸存者 bot 语义 + 传真人可 crash + 距离远即 false，调研 §B1）。
> NavPath 用 teamID=3，target 的 nav 用 `L4D_GetNearestNavArea(target,500,anyZ,…)`。

## 二、Soft Score（同候选打分取最高）

```
score = ScoreEuclid（≈|d-350| 越小越高）      // guard=350 变 preferred，非绝对门
      + ScoreNavTravel（[prefMin,prefMax] 首选带，超出惩罚）
      + ScoreFlow（|flowDelta|>ss_spawn_flow_delta_preferred 惩罚）   // info §6/§21 边界
      + ScoreConcealment（生还者可见出生 -150，隐藏加分）
      + ScoreAttackLOS（SI 出生即看到目标 +100；Smoker/Spitter +250）
      - ScoreClassGeometry（|dz|>150 跨层垂直惩罚）                   // §B4
```
分母里"失败 → 放宽 flow/concealment/attack LOS"由打分自然实现（没有好点就取最差通过硬门的点）；
再没有 → 返回 false → 欠账，`SISpawn_FindPosition` 第二遍只换"路径锚点"为最高 flow 生还者（§12，
Hard Gate 其余项不放松）。

## 三、intended target 选择（`SISpawn_PickTarget`，调研 §20）

不全打最高 flow（防前排被集火）。按 class profile 在本只 SI 的战场段（三段定向参照子集）内选人：
Smoker/Hunter/Jockey → 孤立/边缘（最少 380u 内队友）；Boomer/Spitter/Charger → 扎堆（最多队友）。
spawn validator 仍是统一一套，变的只有 target selection 与 class score profile。

## 四、出生目标注入（`SISpawn_ApplyTargetInject`/`tmrCancelBotCommand`，本轮最关键实验）

```
Spawn 成功 → L4D2_CommandABot(si, intendedTarget, BOT_CMD_ATTACK)   // 可绕过 BOT_CANT_SEE
  → ss_spawn_target_inject_time(1.5s) 后 → L4D2_CommandABot(si, 0, BOT_CMD_RESET)
  → 交还原版/AI_HardSI
```
CommandABot 是"出生引导器"不是完整 SI AI（报告 §11）。waveID 校验防 client 槽复用被旧 RESET 干扰。
⚠️ AI_HardSI v5.23 曾移除非正统 CommandABot 调用（怕接管冲突）——本实现按调研要求默认开
（`ss_spawn_target_inject 1`），若与 HardSI BT 抢控，把该 cvar 关掉即回退，这是报告建议的最小实验。

## 五、幽灵看门狗（`tmrForceSuicide` 重构，调研 §24/§25/§26）

幽灵判定从"视觉状态"改为"行动进展状态"：

- healthy = m_hasVisibleThreats | 正在控人 | NavTravelDistance 到目标明显下降(>100u/2.5s) | 被打（Event_PlayerHurt 刷 actionTime）
- idle 分阶段（无行动计时）：
  - `idle ≥ ss_spawn_recover_time(7s)` → retarget + 重新注入
  - `idle ≥ ss_spawn_relocate_time(14s)` → `L4D_WarpToValidPositionIfStuck` + 重新注入
  - `idle ≥ ss_suicide_time(25s)` → KillInactiveSI（最终垃圾回收，仅降级为收尾机制）
- 处决日志 `[SS] 处决 X 距生还者最近 N` 保留（观测指标）

## 六、失败不耗预算 + 移除无校验兜底

- **删除** v5.33 的"任意最近点"无条件兜底（`hasAnyPos`）与 v2.6.0 的 A/B 不可见分档（`invis_min/max`
  从"决定 fallback 等级"改为**仅注册**，防旧 cfg 报错，报告 §16 建议逐步废掉）。
- **移除后的失败**：`g_iBatchGuardBlocked++`（饿死率观测）+ `g_iBatchDebt++`（欠账）→ 首发后 1s
  `tmrCatchup` 重采样补上（不耗 reserve、不计入击杀阈值，每波至多一次）。

## 七、性能（24 人，调研 §19）

- 每只 SI 只选 1 个 intended target，路径硬门只验 candidate→target 一次
- 候选打分可见性只查 ≤4 个代表（最高 flow / 中位 flow / target / 最近），不查 24 人
- 看门狗 NavTravel 每 2.5s 只对"当前在看门"的 SI 算（≤场上 SI 数），量级可接受

## 八、新 cvar（cfg 已落，起测值见报告 §17）

`ss_spawn_candidate_samples 16`、`ss_spawn_nav_path_max 5000`、
`ss_spawn_nav_travel_preferred_min 0` / `_max 3000`、`ss_spawn_flow_delta_preferred 1500`、
`ss_spawn_target_inject 1`、`ss_spawn_target_inject_time 1.5`、
`ss_spawn_recover_time 7.0`、`ss_spawn_relocate_time 14.0`。
250/350 保留未动（先验证算法，再调参，报告 §15）。

## 九、验证/回滚

- 编译：服务器 spcomp 1.12.0.7220，0 error / 6 warning（4 个为既有：g_bRandomDirection
  float/bool、inflictor、dominated tag；不含新代码）
- 部署：`cp scripting/compiled/specialspawner.smx …/plugins/` + `cp server-cfg/sourcemod/specialspawner.cfg …/cfg/sourcemod/`
  → RCON `sm plugins reload specialspawner`
- 观测：`[SS] 处决 X 距生还者最近 N` 处决率（首要指标）、`[SS] spawn guard: X/Y skipped`（饿死率）、
  `[SS] Catchup: debt=… re-spawned=…`、`[SS] ghost-recover/ghost-relocate`（看门狗修理是否生效）
- 若幽灵处决率断崖下降，即证明老问题主要是"出生后没被告知目标"，而非"不可见点太多"
- 回滚：plugins/ 里旧 `specialspawner.smx`（v5.33.0 37805B bak）+ cfg + reload

相关：[[l4d2-si-spawn-research-plan]] [[l4d2-specialspawner-config]] [[l4d2-si-spawn-fixes]]
