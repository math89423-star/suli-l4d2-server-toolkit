# AI_HardSI v5.23.1-5.25 实机修复链（扑击恢复/节奏/导航/冷静期/波次）

**日期**：2026-08-16（下午实机联调，用户在场边测边改）
**状态**：已部署 v5.25 + git 提交推送（6ad9677）

## 重大教训 1：引擎 press 链路 vs 每帧输入注入

**现象**：v5.23 Think/Control 分离（非决策帧持续注入 BT 上次按键）→ Hunter 近距离
按 IN_ATTACK 不扑（日志实锤：267u root 4 攻击序列循环、80u 落 semi 走位）。
**机制**：L4D2 引擎 bot 的技能（扑击/冲锋）由引擎 AI 自己的按键序列帧发起；
持续注入 IN_ATTACK（恒 1）+ 清 Valve 输入 = 剥夺引擎 press 时机。
**结论**：**Think/Control 分离在 L4D2 引擎 bot 上不可行** → v5.23.2 回退 v5.22 帧语义
（决策帧 BT 输出、非决策帧 Plugin_Continue）。任务书 §2.4 目标与引擎机制冲突时以引擎为准。

## 重大教训 2：蹲姿门控 vs 站立技能

**现象**：v5.23 Hunter 攻击分支全要 CND_IsDucking（蹲姿），Jockey 无需蹲 → 对照发现
Jockey 站立 leap 正常而 Hunter 蹲姿链路脆弱（决策帧按蹲、Valve 帧站起抖动）。
**修复**：7 个攻击分支删 IsDucking（站立即可扑，Jockey 同构）；扑击门控 1500→1000
（引擎有效射程 v4.0.1 实测，超射程白按 = v5.3 教训重现）。

## 用户设计确认（波次节奏，2026-08-16 用户口述）

1. 每图首波：ss_first_time=15s（玩家离开安全区后）
2. 清缴期：≤120s 硬上限强制下一波（ss_rest_force=120）
3. 剿灭 ≥70%（阈值=max(2, 刷新量×0.3)）→ 冷静期 25-35s + 播报下一波时间
4. **下一波是 Tank 波 → 冷静期 ×1.5（37.5-52.5s）** —— v5.25 补实现：
   tank_wave_mutator SS_OnWaveRest 里恢复基准 25/35 + Tank 判定 ×tank_wave_rest_scale(1.5)；
   specialspawner EnterRest 改为**先通知 forward 再抽 rest**（倍率作用于本波）
5. 波次数量 = **人数×2.5 最少 10**：基准 ss_spawn_size=10 + 每多 1 人 +2.5
   （公式 10+2.5×(n-4) = 2.5n，上限天然一致）

## Hunter 节奏微调（用户：连续扑太变态）

- ai_hunter_pounce_interval=0.4（每次扑击停顿，PounceReady 条件+MarkPounce；
  冷却 FAIL 落走位分支不站桩——不用 Cooldown 节点，吸取 v5.9 教训）
- ai_hunter_pounce_spread=±30°（扇形随机角度，SectorOffset 替换高斯）
- 过顶扑 30%→40%（越过目标落身后回头扑杀）

## 导航层整改（任务书 §14 路线 A，全特感共性）

- **BT_AimIfNear 远近分流**：>600u 不覆盖视角 → Valve 原生导航找路（防直线撞墙）；
  ≤600u 才接管瞄准。接入 MoveToTarget/StrafeMoveToTarget/StrafeApproach/
  StrafeRandom/HugWall/Hunter Sprint/Crouch
- **BT_ObstacleAhead** 前瞻探测（前方 120u）；StuckDetour 检测 0.75→0.4s +
  绕行方向左右探测选通（非随机 ±90°）
- **Charger TryCharge 冲锋前直线通路 trace**（600u 有墙不冲，0.4-0.8s 退避绕行）

## 波次数量修复

- 用户："为什么只刷 6 只？人数×2.5 最少 10" → 基准 ss_spawn_size 6→10
  （specialspawner 默认 + si_comp g_fCfgBaseSpawnSize 双处同步；si_comp 在
  OnConfigsExecuted 捕获基准，改 cvar 无效必须改基准捕获）

## 诊断日志（保留中，稳定后可移除）

- specialspawner: REST countdown 构成（rest/postRest/total/spawnTimeMax/avgRest）
- si_comp: PinSpawnTiming 钉值（min/max/interval/prev）
- 曾用它们定位 57s 播报 = reload 窗口句柄竞态（55.0 假钉值，自愈）

## 部署与版本

- AI_HardSI_bt v5.24.0（内容 v5.25，版本号未 bump）；specialspawner 2.4.4；
  tank_wave_mutator v2.5.0；si_comp v2.7.x
- 编译：AI_HardSI 0 error / 24 warnings；特殊 spawner 1 既有 warning；其余 0
- git: 6ad9677（9 文件 +404/-151），本地=远端 0/0
## v5.26-5.34 补充（同日傍晚，用户逐项拍板，提交 b3bbf46）

**角色体系**：
- 角色 60/40（v5.30）：进攻者 60% / 骚扰者 40%（原 50/50；更早 100% 骚扰者）
- Hunter 恢复骚扰分支（v5.26，v5.21 曾禁用）：游走 ≤5s（ai_harass_max_hold 硬超时/
  到嘴边放行/机会性扑击）→ "骚扰≠一定不攻击，游走一会再攻击"
- Jockey 骚扰期更积极：机会骑乘冷却 10→5s、距离 450→520

**Charger 战术体系（用户设计逐步落地）**：
- 高处震落冲锋（v5.27）：dz 80-250u + 脚下支撑 → 冲支撑点 impact 震落
- 跳起空中冲锋（v5.28）：先跳空中起步（幸存者分不清锁定目标）
- 墙冲震荡（v5.29）：侧向偏移 40-80u（两轮收窄：150-250→60-120→40-80，
  impact 半径 ~100-150u 考量）；撞墙后贴身近战
- 双层概率（v5.31）：直冲:墙冲=7:3；直冲内 跳:地=4:6 → 30/28/42
- 情境化（v5.33）：墙冲概率动态——孤立 12% / 密集 55% / 贴墙 45% / 兜底 30%
- 障碍处理（v5.34）：≤300u 障碍=白挨打不冲（走位绕行）；300-600u 障碍墙冲 60%

**Tank**：投石确认（TryThrowRock + OnRelease 事件，动画吞键问题恢复频率）；
协同拳 LOS 直测（m_hasVisibleThreats 失真）；投石瞄眼睛高度（脚底=低抛命中差）

**Spitter/Smoker 命中率**（v5.32）：Smoker 胸口+飞行时间预判；Spitter 预判
改距离/1100×0.7（原固定 0.8s 远近失真）

编译 0 error；git b3bbf46 已推送 0/0
