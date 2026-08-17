# AI_HardSI v5.23 行为树审查修复（云端任务书实施）

**日期**：2026-08-16
**状态**：已完成部署验证（v5.23.0，空服 reload + 特感 bot 冒烟测试通过，0 运行时错误）

## 触发

用户把云端 agent 的《AI_HardSI_optimized 行为树审查与修复任务书》发来，要求对照实施。

## 关键决策

- **任务书 §11（Pressure System 修复）按废弃跳过**——压力值/tier 已随 tank_wave_mutator
  波次突变废弃，AI 行为层不感知压力值；bt_common.inc 无 scaledDist 残留（勘察确认）
- **并行实施**：先由主 agent 冻结基础设施 API 契约（bt_core/bt_common/AI_HardSI.sp 地基改动
  + 基线编译），再并行分发 6 个子 agent（每个只改自己文件：hunter/jockey/charger/spitter/
  smoker+boomer/hardcoop_util），最后统一编译仲裁 + 部署验证
- **Tank 本轮未改**（任务书 §18 建议最后）：近战 Cooldown(1.5)/投石 Cooldown(5.0) 已对齐引擎
  真实冷却（z_tank_attack_interval/z_tank_throw_interval），无"按=假成功"问题

## 核心变更（详见 sourcemod/scripting/AI_HardSI_optimized/CHANGELOG_v5.23.md）

### 基础设施（v5.22，bt_core.inc / bt_common.inc / AI_HardSI.sp）
1. **BT Control Mask**：BT_TakeControl/HasControl + BT_ControlFlags；AddButton/RemoveButton/
   SetAimAngles 自动声明接管；细粒度 BT_ClearMoveDirection/ClearAttack/ClearDuck
2. **Think Rate ≠ Control Rate**：决策每 2 帧，控制输出每帧应用（BT_ApplyControlFrame 非决策帧
   沿用上次累积输出）→ 消除 Valve/BT 交替接管
3. **BT_AbortNode**：Selector/Sequence 三条退出路径统一收尾旧 RUNNING 子树 + WAIT 时间戳清理
4. **统一 Target 校验**：BT_TargetSatisfies/TARGET_* flags + SI_IsValidTarget
5. **统一技能状态机**：SIAbilityState(IDLE/TRYING/CONFIRMED/RECOVERY) + SI_Ability* helpers
   （MarkTry/MarkConfirmed/StartCooldown/Backoff/IsReady）——按 IN_ATTACK ≠ 技能成功
6. **Wave Sync 就位补 LOS**：原注释承诺 LOS 实际只查距离，隔墙/楼上也计入 ready（已修）
7. **g_fChargerChargeConfirmed**：ability_charge 事件置位，声明前移至 include 之前（防 symbol 未定义）

### 特感（v5.23）
- **Hunter**：root selector 重排（sprint 移到 routeAmbush/routeFlank 之后）；WallPounce 类型错误修复
  （BT_Status 当 client index）；narrow/coord/disruption 统一补 CND_TargetIsPinnable
- **Jockey**：hopSeq 重建（Pinnable 守卫前移到攻击前）；8 个地形分支 Acquire 前置；
  HarasserRide 补 pinnable；mode1 锁链已符合顺序零改动
- **Charger**：ChargerAct_TryCharge 状态机（确认才 arm 12s；1.1s 超时退避 0.5-1.0s 不锁冷却）
- **Spitter**：超时不再假成功锁 8s（退避 0.3-0.8s + FAILURE）；post_mode 掷骰移到真实确认；
  SpitReady 加退避闸
- **Smoker**：SmokerAct_TryTongue（m_tongueVictim 确认 / 1.2s 超时退避）
- **Boomer**：FIRE（L4D_ActivateAbility_Boomer_Post 事件）≠ HIT（player_now_it 降级为命中反馈）
- **hardcoop_util**：移除 SI_SignalAttack/SI_SignalBoomerHit 对其它 SI bot 的 L4D2_CommandABot
  直接命令（协同 = shared intent，BT 自行消费共享状态）

## 编译与部署

- spcomp64 1.12.0.7220：0 error / 22 warnings（21 既有 + 1 新 unused CND_IsTargetPinned）
- 部署：plugins/AI_HardSI_bt.smx（hash dbdd1c08...），reload 成功，空服冒烟测试通过
  （sm_forcetimer 触发波次 → ai_debug rootBranch 日志显示 Hunter/Jockey/Smoker 分支正常跳变）
- 静态审查（任务书 §22 全部通过）：无 ACT_Acquire* 类型错误、无 ResetMovement 滥用、
  无 CommandABot 代码级调用、IN_ATTACK 均在守卫后、Cooldown 均基于真实确认

## 关联记忆

- l4d2-pressure-system-removed.md / l4d2-tank-wave-mutator.md（压力废弃背景）
- l4d2-rest-tier-override-bug.md（冷静期 tier 遗留——同架构审查背景）