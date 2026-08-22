# AI_HardSI v5.27.1 Smoker/Spitter 站桩与口径修复

**日期**：2026-08-22
**状态**：已部署 + 热加载验证 + git推送 (a1b1215, 9 commits ahead -> pushed)
**触发**：用户报告“大量特感呆傻，远程控制类 Smoker/Spitter 技能打空、放完技能站桩、原地反复跳”，要求以 Jockey 为参考审计全树可达性/死分支/苛刻条件

## 审计摘要（Jockey对照）

- **Jockey 优**：`bt_jockey.inc:544` root `ride->harass(5s硬超时/520u放行)->mode1锁链->地形(ledge/narrow/open均Acquire+LOS+Range分离)->hopSeq(6s closeStrafe超时)->strafeApproach->Wander`，`AlternatingHop` `bt_jockey.inc:302` 补 `IN_FORWARD+瞄黑板` 解原地跳，`HarasserRide` `bt_jockey.inc:29` 3-5s主动跳下，`StuckDetour` 全 движения 分支接入。
- **Smoker/Spitter 差**：Backoff期内有LOS+在射程内但 `approachAct(!InRange)`/`closeRangeStrafe(!LOS)` 均FAIL -> 零移动一帧；`m_hasVisibleThreats` 失真；`Stuck 0.4/20/3` 对横移守位过敏感。

## 修复清单

### 1. Smoker Backoff站桩 P0 `bt_smoker.inc:417/582/649`

- 新增 `SmokerCond_BackoffActive` `bt_smoker.inc:417` 读 `SI_AbilityBackoffActive(_smoker)`。
- 新增 `backoffStrafe` `bt_smoker.inc:582` `Sequence(5, IsInRange850, HasTargetLOS, BackoffActive, AcquirePinnable, StrafeApproach)` 堵 `850内+有LOS+Backoff0.5s` 空档，插 `root` `bt_smoker.inc:649` `closeRangeStrafe`后。
- 原空档：`cooldownPull(1.8)` FAIL (Backoff) -> `routeAmbush(!LOS+!InRange)` FAIL -> `closeRangeStrafe(!LOS)` FAIL -> `approachAct(!InRange)` FAIL -> `retarget` 零移动。

### 2. Smoker pin后傻站 P0 `bt_smoker.inc:224`

- `SmokerAct_SteerPinToAcid` `>=850` 原 `SUCCESS` 静止 -> 改 `RUNNING` 横移微抖 `bt_smoker.inc:224` (`_smoker_pin_strafe_*` 0.4-0.9s切换 `MOVELEFT/RIGHT` + 瞄受害者)，舌头仍引擎托管不后退防断。
- `<850` 仍背对目标 `IN_FORWARD` 后退 `bt_smoker.inc:213`。

### 3. Spitter 口径+守位 P0 `bt_spitter.inc:403/410/438`

- `openS0_Approach 800->900` `bt_spitter.inc:403`、`openS0_Spit 800->900` `bt_spitter.inc:410` 对齐 `z_spit_range 900` `ENGINE_CVARS.md:29`，消 800-900 假Approach。
- `postSpitHold 300-600u` `bt_spitter.inc:438` `StrafeRandom->StrafeApproach` 止纯横移贴墙 `StuckDetour` 反复跳。

### 4. Charger StepBack LOS P0 `bt_charger.inc:594`

- `m_hasVisibleThreats` -> `CND_HasTargetLOS` `bt_common.inc:310` 解 BT接管视角后引擎标志失真；`ChargerAct_StepBackCharge` `bt_charger.inc:593` 后退0.4s后 trace 复核。

### 5. Stuck去抖 P1 `bt_common.inc:24`

- `STUCK_CHECK_INTERVAL 0.4->0.6`、`THRESHOLD 20->15`、`JUMP_ROUNDS 3->4`，降 `300-600u` 横移守位每0.4s贴墙即跳频；`postSpitHold` 已改前进，`15u` 微抖动不误判卡死。

### 6. 杂项

- `bt_charger.inc:287` 删未用 `blockedPath` 影子变量，warnings 29->27。
- `AI_HardSI.sp:191` `5.27.0->5.27.1`。

## 编译与部署

- `spcomp 1.12.0.7220` `AI_HardSI.sp -i include` 0 error / 27 warnings (21既有+6未用符号)。
- `cp /tmp/AI_HardSI_bt.smx -> scripting/compiled/AI_HardSI_bt.smx + left4dead2/addons/sourcemod/plugins/AI_HardSI_bt.smx` (86K)。
- `rcon sm plugins info AI_HardSI_bt` `5.27.1 running 08/22 10:58:29 Hash 5e1772...`；`sm plugins reload` 成功；`errors_*.log` 零新增。
- `git commit a1b1215` `fix(hardsi): v5.27.1 ...` + 前8 commits 共9 -> `git push` 成功 `origin/master a1b1215`。

## 验证建议

- `sm_cvar ai_debug 1` 2分钟：`Smoker 500u墙后 HasLOS+Backoff` 时 `rootBranch` 稳定 `6b backoffStrafe` 位移>50u/s；`Spitter 300-600u postSpitHold` 不再每0.4s跳。
- 实机：24人图 `c2m1_highway` 压测 `Smoker 10次拉` 打空率、拉中后横移活性；`Spitter 800-900u` 开阔地 `openS0_Spit` 是否正常吐。

## 关联

- `l4d2-ai-hardsi-v525-livefix.md` / `l4d2-ai-hardsi-v5.23-bt-review-fix.md`（前置审查背景）
- `ENGINE_CVARS.md:29` 引擎射程实测基准
