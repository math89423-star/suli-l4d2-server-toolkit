# AI_HardSI v5.23 更新日志

**发布时间**：2026-08-16
**核心变更**：🏗️ 行为树架构审查修复（云端审查任务书实施，v5.22 基础设施 + v5.23 特感修复）

---

## 背景

按云端 AI_HardSI 行为树审查与修复任务书实施结构性修复，核心目标：
> "行为树负责明确决策，底层输入与导航有清晰控制权，技能成功由真实游戏事件确认，
> 高级战术分支不会被通用 RUNNING 行为遮蔽。"

压力值相关条目（任务书 §11）已按废弃处理跳过——压力系统由 tank_wave_mutator 波次突变
独立负责，AI 行为层不感知压力值。

## v5.22 基础设施（bt_core.inc / bt_common.inc / AI_HardSI.sp）

### 1. BT Control Mask —— 控制权统一（任务书 §2）
- 新增 `BT_ControlFlags`（MOVE/VIEW/ATTACK/DUCK/JUMP/FULL）+ `BT_TakeControl/BT_ReleaseControl/BT_HasControl`
- `BT_AddButton/BT_RemoveButton/BT_SetAimAngles` 自动声明接管对应输入类别（输出即声明）
- 新增细粒度清除：`BT_ClearMoveDirection/BT_ClearAttack/BT_ClearDuck`（替代无差别 `BT_ResetMovement` 滥用）
- `BT_ApplyControlFrame`：被接管的输入类别先清 Valve 原版意图再叠加 BT 输出

### 2. Think Rate ≠ Control Rate（任务书 §2.4）
- 原 TICK_INTERVAL=2 降频导致"BT 帧 / Valve 帧"交替接管（BT 要埋伏、Valve 向前跑）
- 现在：决策（跑树）每 2 帧一次；**控制输出每帧应用**（非决策帧沿用上次决策的累积输出 + 控制声明）
- 消除两套 AI 抢方向盘的抖动，Hold/Ambush 真正静止

### 3. BT Abort 生命周期（任务书 §3）
- 新增 `BT_AbortNode`：Selector/Sequence 在 SUCCESS/FAILURE/RUNNING 三条退出路径统一收尾旧 RUNNING 子树
- WAIT 节点时间戳随 Abort 清除（修复"Wait 3s 跑 1s 被抢占 → 5s 后重入立即 SUCCESS"）
- Cooldown 状态保留（抢占后保持冷却，防止被抢占分支立刻重入刷冷却）

### 4. 统一 Target 校验（任务书 §4）
- 新增 `SI_IsValidTarget / BT_TargetSatisfies / BT_ValidateBlackboardTarget`
- flags: TARGET_ALIVE / NOT_INCAP / NOT_HANGING / NOT_PINNED / PINNABLE / HAS_LOS

### 5. 统一技能状态机（任务书 §16）
- `enum SIAbilityState { IDLE, TRYING, CONFIRMED, RECOVERY }` + 全套 helper
- 按 IN_ATTACK ≠ 技能成功原则：真实事件到达才 CONFIRMED，超时短退避重试，不假成功不进正式冷却

### 6. Wave Sync 就位补 LOS（任务书 §12）
- `Wave_EvaluateSync` 就位判定原"注释承诺 LOS、代码只查距离"——隔墙/楼上/门后也被计入 ready
- 补 trace 视线检查：距离 ≤ readyRange **且** 视线通畅才算就位

### 7. 技能确认事件
- `ability_charge` 事件 → `g_fChargerChargeConfirmed` 标记（Charger 真实冲锋唯一依据，声明前移至 include 之前）

## v5.23 特感修复

### Hunter（bt_hunter.inc）
- **[P0] root selector 遮蔽修复**：`sprintApproach` 从第 12 位移到 routeAmbush/routeFlank **之后**
  （新顺序：...close→fast→routeAmbush→routeFlank→crouchPrep→sprint→crouchApproach→wander），
  战术分支不再被恒 RUNNING 的冲刺遮蔽
- **[P0] WallPounce 类型错误**：`target = ACT_AcquirePinnableTarget(client)` 把 BT_Status 当 client index
  （结果恒 0/1，瞄准永不执行）→ 改为判断返回状态 + 从黑板读回 target + 有效性校验
- **[P1] 扑击序列统一守卫**：narrow/coord/disruption/openStrat0/1 统一补/替换为 `CND_TargetIsPinnable`
  （挂边/倒地/被控目标不可扑，打上去空转）

### Jockey（bt_jockey.inc）
- **[P0] hopSeq 重建**：`Sequence[OnGround→AcquirePinnableTarget→HasTargetLOS→InRange(450)→TargetIsPinnable→AlternatingHop]`
  —— Pinnable 守卫前移到攻击动作**之前**（原守卫在攻击后，副作用先行）
- **[P0] 8 个地形分支 Acquire 前置**：`AcquirePinnableTarget` 移到 `HasTargetLOS` 之前（消除"先验证旧目标再换目标"）
- **[P1] HarasserRide 补 pinnable 守卫**：目标倒地/被控时不再空按 IN_ATTACK
- mode1 锁链分支经核实已符合顺序（Acquire 先于距离校验），零改动

### Charger（bt_charger.inc）
- **[P0] 冲锋确认状态机**：新增 `ChargerAct_TryCharge` 替换原"按 ATTACK + SUCCESS"动作
  - `ability_charge` 事件确认（g_fChargerChargeConfirmed，2s 时效窗防陈旧跨轮误消费）→ SUCCESS arm 外层 Cooldown(12.0)
  - 1.1s 未确认 = 引擎拒绝 → 0.5-1.0s 退避 + FAILURE（**绝不锁 12s**，任务书 §8 验收 21.4）
  - 冷却源唯一：保留外层 Cooldown(12.0)，内部不用 SI_AbilityStartCooldown（防 24s 双倍）
  - 11 处冲锋分支 + BlindCharge + StepBackCharge 全部接入

### Spitter（bt_spitter.inc）
- **[P0] 吐技能退避重试**：三个吐动作 1.5s 超时**不再假装成功锁 8s**
  - 超时 → `SI_AbilityBackoff(0.3-0.8s)` + FAILURE（落走位分支）
  - `SpitterCnd_SpitReady` 加退避闸（全部 8 个吐分支自动获得重试间隔）
  - `_spitter_post_mode` 掷骰从按压瞬间移到真实确认（g_bSpitterSpitFired）时——失败尝试不再污染吐后行为
  - 保证：`_spitter_spit_time` 写入点只剩 3 处确认分支，8s 解锁链路语义不变

### Smoker（bt_smoker.inc）
- **[P0] tongue attempt ≠ confirmed**：新增 `SmokerAct_TryTongue` 替换 6 处 `ACT_Attack`
  - `m_tongueVictim > 0`（引擎真实拉中，与 pinSeq 同判据）→ CONFIRMED + SUCCESS arm 外层 Cooldown(1.8)
  - 1.2s 未拉中 → 0.5s 退避 + FAILURE（失败尝试不再消耗冷却窗口）
  - 拉中后 pinSeq 下一 tick 无缝接管拖拽

### Boomer（bt_boomer.inc）
- **[P0] VOMIT_FIRED ≠ VOMIT_HIT 拆分**：
  - FIRE 确认：新增 `L4D_ActivateAbility_Boomer_Post` 事件驱动（引擎真实呕吐触发）→ 10s 自锁 + 80/20 后置掷骰
  - HIT 反馈：`player_now_it` 降级为"命中反馈"（SI_SignalBoomerHit 开团 + just_vomited）
  - 吐空无人命中不再误判"没释放"；FIRE 事件缺失时 HIT 兜底行为不劣化

### 协同层（hardcoop_util.sp）
- **[P1] CommandABot 冲突移除**：`SI_SignalAttack` / `SI_SignalBoomerHit` 删除对其它 SI bot 的
  `L4D2_CommandABot(BOT_CMD_ATTACK)` 直接命令接管（任务书 §13）
  - 协同 = shared intent：窗口/集火/命中信息经 `g_fSIWindowEndTime / g_iSIPinTarget / g_bSIBoomerHit` 共享状态
    由各 SI 的 BT 自行消费决策（CND_IsAttackWindow / ACT_AcquirePinTarget / CND_IsBoomerActive）
  - 保留 `L4D2_StartAssault`（全特感恐慌，无个体意图冲突）与 `L4D2_RushVictim`（尸潮 rush）

## 编译结果

- SourcePawn 1.12.0.7220：**0 error / 22 warnings**（21 个为既有未使用符号 + ZombieClass tag，
  1 个新增 unused `CND_IsTargetPinned`——原守卫被替换后无引用，无害保留）
- 静态审查（任务书 §22）：`= ACT_Acquire*` 类型错误 0 处、`BT_ResetMovement` 滥用 0 处
  （仅保留 AI_HardSI.sp 决策帧开头正统调用）、`L4D2_CommandABot` 代码级调用 0 处、
  IN_ATTACK 全部位于守卫之后、Cooldown 全部基于真实技能确认

## 未解决 / 后续关注

0. **【勘误】Tank 投石"按=假成功"实际存在**（v5.23 交付时误判为"无此问题"）：
   `rockCluster Cooldown(5.0)` 在按键时刻武装（bt_tank.inc:708），而真实释放事件
   `L4D_TankRock_OnRelease`（826-853）只做瞄准校正未接入冷却 → 投石动画 ~1s 导致
   引擎冷却内提前按键被吞，实际投石频率约砍半。修复方案见
   `/tmp/next-round/tank-review-plan.md` P1-1（照搬 Charger/Smoker Try+事件确认+退避模式，
   只改 bt_tank.inc 不动 AI_HardSI.sp）。另 P1-2：协同拳依赖 `m_hasVisibleThreats`
   （BT 接管下失真，bt_tank.inc:525）大概率静默失效，需换 pin 直测 trace LOS。
1. **Boomer FIRE 事件**：`L4D_ActivateAbility_Boomer_Post` 在目标 left4dhooks 版本是否稳定触发
   待实机观察（不触发则退化为 HIT 兜底+退避，不劣于 v5.6）
2. **Smoker 无"舌头飞行中"标志**：目标横跳躲舌时会产生 1.2s 空按周期（0.5s 退避节流），观感不佳时
   后续可 hook `L4D_ActivateAbility_Smoker_Post` 区分"已发射未命中"
3. **Spitter 竞态**：超时判定与 ability_spit 同帧先后时，残留标记由下次尝试消费——事件证明真实吐出，
   语义正确仅时间戳略晚（与 Boomer v5.6 同款）
4. **Tank 本轮未改**（任务书 §18 建议最后）：近战簇 Cooldown(1.5) 与引擎对齐无误（见上条勘误，
   投石才是真正缺口）
5. **调试能力**：现有 `ai_debug`（0/1）仅 root 分支级；任务书 §19 的 0/1/2/3 分级 + Branch ID 统计
   未实施（设计已就绪 `/tmp/next-round/debug-system-design.md`，建议下轮 P0）

## 部署

- 产物：`scripting/compiled/AI_HardSI.smx` → `plugins/AI_HardSI_bt.smx`（v5.23.0）
- 空服验证：reload 成功、4 插件 running、特感 bot 行为树正常 tick（ai_debug rootBranch 日志）、0 运行时错误