---
name: l4d2-ai-hardsi-engine-tuning
description: AI_HardSI 引擎数值实测校准（v4.0.3→v4.0.5 已部署）+ Tank cvar 审计结论 + 待办（Tank 高级玩法四件套 v4.1）
metadata: 
  node_type: memory
  type: project
  originSessionId: 4203ecd8-3ff3-46b2-89ff-a6d930a85ed1
  modified: 2026-08-04T16:04:24.602Z
---

# AI_HardSI 引擎数值校准（v4.0.3 → v4.0.5 → v4.1）

## 背景

玩家实测特感 AI 弱 → 三类根因审计（代码未装载 / BT 分支不可达 / 数值未调优）。
**铁律（用户强调）：不验证不乱填** —— 任何数值改动前必须空服 RCON 实测引擎真实值。
全量实测表在源码目录 `scripting/AI_HardSI_optimized/ENGINE_CVARS.md`（git 仓库内，持续维护）。

## 引擎实测关键数值（2026-08-03 空服 rcon）

- `z_charge_interval`=**12**（冲锋冷却）→ 插件冲锋簇 `Cooldown(12.0)` 对齐
- 冲锋覆盖 ≈940~1190u（warmup 0.5s + duration 2.5s × max 500u/s）→ `ai_charge_proximity` 750 合理（**无引擎 500 上限：ai_ChargerChargeDistance 不存在**）
- `z_spit_interval`=**20** → 插件干预 8.0（对齐 post-spit 自锁，零无效按键）
- `z_vomit_range`=**300**（Boomer 呕吐射程！）→ v3.5 自创 500/550 超射程，Boomer 站桩对空气无限无效呕吐；v4.0.4 全系 8 处 → 300
- `z_spit_range`=**900** → Spitter 分支 800/900 已验证对齐
- `z_jockey_ride_damage`=4（骑乘 DPS）、`z_tank_attack_interval`=1.5
- **不存在的 cvar**（查询确认，勿再引用）：ai_ChargerChargeDistance / ai_fast_pounce_proximity / ai_straight_pounce_proximity / smoker_tongue_range / z_tongue_reach / z_hunter_pounce_range / hunter_pounce_interval / z_spit_damage / z_vomit_speed / boomer_vomit_interval —— 射程速度多为引擎硬编码
- RCON 工具链：rcon.source 库 Broken pipe 不可用 → **手写 socket 协议**（脚本见 ENGINE_CVARS.md 第五节，含密码复用）

## 已部署（2026-08-03，commit a019565；plugins/AI_HardSI_bt.smx = v4.0.5 running）

v4.0.5（commit a019565，备份 .bak.20260803_v404_pre_v405）：
- **Witch 死树整删**（bt_witch.inc）：Witch 是实体非客户端，无 OnPlayerRunCmd 入口/无 player_spawn 绑定，树从未被 tick（用户拍板：风险高收益低，移除）
- **Tank 13 个 ai_tank_* cvar 审计**：punch_jump/instakill/punch_damage/rage_multiplier 接入；bhop 冷却恢复（原每 33ms 无冷却连跳）+ chain 重置；wall/evade 恢复（v3.2 丢失）；aggro 由 BhopEligible 消费
- **追击逻辑**（玩家抱怨"连跳追击过于困难"）：bhop min_dist 200→**500**（威胁圈内落地走，连跳只用于远程拉近）；处决门控 800u 内有站立活人则不补刀（追杀未倒地>补刀）
- **引擎对齐**：近战簇 Cooldown(1.5)=z_tank_attack_interval；**岩石簇 Cooldown(5.0)=z_tank_throw_interval**（openStrat0+rockSeq 共享一个 Cooldown，双节点会轮流触发=没锁）
- **z_tank 全量 27 cvar 入库** ENGINE_CVARS.md；关键：throw_force=800/rock_radius=100/walk_speed=100/damage_slow 200-400u（400u 内枪火减速 Tank，与 min_dist 500 配合）
- **无 Tank 速度/追击类可调 cvar**（除 z_tank_speed=210）→ "Tank 增强"只能走插件行为层

- Smoker：6 拉人分支 `Cooldown(1.8)`（> 引擎舌头冷却）+ ledgeRetarget 加 CND_IsNearLedge 门控（孤立度选人恢复）+ IsInRange(850)（引擎硬编码 ~1100u，保守）
- Charger：11 冲锋分支 `Cooldown(12.0)` + `ai_charge_proximity` 源码 CreateConVar 750（**防重启掉回 500**）
- Hunter：5 攻击序列 `Cooldown(1.0)` + highPounceSeq 1000-1600u 距离门控（消除跳-蹲抖动）；fPounceRange fallback 1000 无 cvar 支撑但实战验证
- Spitter：`z_spit_interval` 20→8 干预
- Boomer：呕吐距离 8 处 350/500/550→300（mode1/narrow/openS0/openS1/semi/approach 全系）

## ⚠️ reload 副作用

reload 插件 → **在场 bot 的 BT 绑定重置 → 原版 AI 接管直到下次重生**。玩家在场时 reload 前必须说明（2026-08-03 用户自己在线时确认过，当场生效）。

## v4.1 Tank 高级玩法四件套（2026-08-03 已部署，commit ecb2ef8，备份 .bak.20260803_v405_pre_v41）

用户定调：无脑连跳贴脸一拳秒杀 = 低级做法；强调协同配合 + 战术。四件套全部落地：
1. **Tank × 协同配合**：coordPinSeq（targetSelector 顶部：窗口+pin → 锁定被 pin 者）+ coordPunchSeq（meleeSelector 顶部：窗口内 ≤300u **直测 pin**（勿用 CND_IsInRange——它量最近生还者）+ 拳杀）；mode 6 保持小队分散（不 SignalAttack）；非 mode6 出拳 = 开团信号
2. **追击优化**：damager 距离门控 ai_tank_damager_max_dist=800（风筝手免疫）；窗口期由 coordPinSeq 自然无视风筝手
3. **地形秒杀**：~~设计实现后经用户拍板整体移除~~（2026-08-03，commit 0df1464）—— Tank 拳只作用于汽车/树干等物理实体、不作用于爆炸物，罐类爆炸链路不可靠，"不确定宁愿用原版"。propKillSeq + 全套函数 + 3 cvar 已删。**遗留：3 个旧 ai_tank_prop_* cvar 因 SM 卸载不清理残留内存（无代码读取，重启服务器后消失）**
4. **飞石精准+预判**：TankAct_AimRock 提前量（lead=vel×dist/800 水平向，clamp ai_tank_rock_lead_max=400）+ `L4D_TankRock_OnRelease` 释放校正（**GlobalForward 声明 public 即接收**，Plugin_Changed 改 vecVel → MRES_ChangedHandled；真实 |vecVel| 自修正 bhop 自身速度 +400~500u/s 与动画期 1s 视角漂移；原版 AI 投石同享）
- 引擎基准：石头 vVel = 视线方向×800 + 自身速度 + z+80（l4dd 核对）
- 新 cvar 8 个：ai_tank_coord / rock_predict / rock_lead_max / rock_pitch_offset（弹道弧线垂直补偿，默认 0，**待空服实测标定**）/ prop_kill / prop_punch_damage / prop_blast_radius / damager_max_dist

## v4.1.1 Boomer 伏击站桩修复（2026-08-03 部署，重启生效）

玩家反馈"特感出生远不动被电脑处死"。代码审计：
- **唯一远距离无限站桩分支 = Boomer ambushSeq**（bt_boomer.inc v4.0 加的，根 selector 第 2 位）：
  `narrow + 目标>300u → ACT_AmbushHold`——无距离上限（2000u 也站）、无超时，
  站桩不按移动键且优先级高于所有 approach 分支 → 出生在窄地形的 Boomer 无限站桩
  直到被 ss_suicide_time 处决。其他 6 特感远距离均有 approach/wander 兜底，无此问题。
- 修复（bt_boomer.inc + bt_common.inc + AI_HardSI.sp，version 4.1.1）：
  ① 目标 >1500u 不伏击直接 approach（IsInRange(1500) 上限）；② ACT_AmbushHold 加
  UserParam1 超时参数（Boomer 设 8s，≤0=不超时保持原行为；仅 Boomer 用此节点）；
  超时后 _ambush_start 残留 = 本生命永久转主动接近，重生恢复。
- 备份 `plugins/AI_HardSI_bt.smx.bak.20260803_v41_pre_v411`；编译 54564 bytes。
- reload 副作用：在场 bot BT 绑定重置 → 原版 AI 接管直到重生（本次随服务器重启生效）。

## v5.1 站桩修复 + 诊断（2026-08-04 编译，reload 待服务器空闲）

用户报告"特感有时候原地傻站"（多种类型都有）。代码审计 4 类站桩路径：
1. **Charger BlockCharge 兜底**（根 child9，bt_charger.inc）：冷却期落进 = 不按移动键站桩 + 每 2 tick 推引擎 m_timestamp +0.1s → 引擎冲锋永久不就绪 → 站 12s → 冷却到尝试冲锋仍是挠击 → 循环
2. **Tank 根 SEQUENCE 整树 FAIL**（bt_tank.inc）：melee/rock/bhop 全冷却或门控不满足（近身 <500u 禁跳）→ attackSelector 全 FAIL → 无任何输出（引擎跳也被 OnPlayerRunCmd 每帧清）→ 近身时每 1.5s 一拳之间全站
3. **Spitter 吐后 40% 据守**（v5.0 设计，HoldPosition 完全静止，最长 8s）
4. 通用：全插件无寻路（面向目标+IN_FORWARD），隔墙/高差顶墙站

附带发现：**Tank_OnPlayerHurt 递归栈溢出**（Tank instakill 的 SDKHooks_TakeDamage 再触发 player_hurt → 递归；08-04 10:15-12:47 共 5 次 "Not enough space on the stack"，16:17 重启加载 v5.0 后暂未复发，同结构仍在）。

修复（v5.1.0，备份 .bak.20260804_v50_pre_v510，smx 60584 bytes）：
- Charger child9 BlockCharge → AcquireClosestTarget+StrafeMoveToTarget（冷却期走位逼近不按 ATTACK，防挠击语义保留；m_timestamp 推后仅保留出生保护分支）
- Tank attackSelector 末位 + ACT_MoveToTarget 兜底（不重新选人，沿用黑板 target）
- Spitter postSpitHold HoldPosition → StrafeRandom（守位语义保留、横向移动）
- Tank instakill 0.2s 同受害者时间戳防护（g_fTankLastInstakillAt）
- **ai_debug cvar（默认 0）**：每 2s 打印各特感 `rootBranch 序号 / terrain / dist` 到 SM 日志；分支号对照各 bt_*.inc 树构建器注释优先级 → 傻站报告直接定位分支

⚠️ 待办：reload 副作用 = 在场 bot BT 绑定重置 → 原版 AI 接管直到重生；部署前确认服务器空闲（静默规则）。ai_debug 用完记得关。

## v5.2 站桩/原地跳第二波（2026-08-04 23:54 编译装盘，reload 待服务器空闲）

用户报告"Smoker/Jockey 站桩 + Hunter 原地跳跃"——v5.1 只修了 Charger/Tank/Spitter，Smoker/Jockey/Hunter 问题独立存在：
- **[通用] ACT_StrafeApproach**（横移+前进）：替换 Smoker(≤350)/Jockey(≤300) closeRangeStrafe 的 StrafeRandom（原只横移不前进 = 原地左右晃，观感站桩）
- **[通用] BT_StuckDetour 顶墙绕行**：全插件无寻路 = 隔墙/高差顶墙站桩主因；0.75s 位移 <20u 判停滞 → W+横移斜插沿墙滑动 1.5-2.5s；接入 12 个 approach action（MoveToTarget/StrafeMoveToTarget/ErraticApproach/Wander/Retreat/FlankApproach/HugWall/CircleFlank/SprintApproach/CrouchApproach/ApproachOutside/StrafeApproach）；定义必须在文件头部（SourcePawn 单遍编译）
- **[Jockey] AlternatingHop 跳模式**：yaw 瞄准黑板 target + IN_FORWARD（原 yaw 不变+无前进 = hopSeq ≤700u 有 LOS 时原地跳；CND_IsInRange 是最近生还者距离非黑板 target）
- **[Hunter] HasHighGround 上限 200→85**：>85u 高台必跳失败（蹲跳 ~85u）= 高台/房檐下 35% 概率每 tick 原地反复跳；**+ ClimbHighGround 2s 跳跃冷却**（跳后走位，冷却期 FAIL → selector 落 approach）
- 版本 5.2.0，smx 61775 bytes（v5.1=60584），备份 `.bak.20260804_v51_pre_v52`
- ✅ **已 reload（2026-08-04 23:54，用户指示，空服确认）**：Version 5.2.0 running，errors 日志零新增，主日志干净
- **git 同步未做**：本机全盘无 suli-l4d2-server-toolkit 仓库（无 .git），源码改动未同步 git
- 调试工具：ai_debug=1 → 每 2s 打印根分支号到 SM 日志，对照各 bt_*.inc 树构建器注释定位傻站分支；**v5.2 生效后待玩家实测**（Smoker/Jockey 顶墙、Hunter 高台跳、Charger/Tank/Spitter v5.1 修复一并生效）

## v5.3 放完技能傻站 + Hunter 扑空循环（2026-08-05 00:04 编译装盘，reload 待确认）

v5.2 实战反馈两个新症状，根因 + 修复：
- **[Smoker 拉中傻站]** pinSeq → SteerPinToAcid **无酸时返回 SUCCESS = 引擎钉住不动**（v5.0 只处理了拖酸）。修复：无酸 → 背对目标后退拖拽（m_tongueVictim 目标，距目标 ≥850u 停后退防断舌），真人拉扯观感
- **[Hunter 跳一下扑一下]** 插件 fPounceRange fallback=1000 但引擎 `hunter_pounce_ready_range=500`（模块自设）→ **600-1000u 按 ATTACK 引擎扑不出** → 扑空 → missEsc 逃跳 → 再扑 = 循环。修复：**创建 ai_fast_pounce_proximity cvar=500**（v4.0.3 确认从未创建，一直用 fallback；模块启动时 FindConVar 存在性判断防 reload 重复创建告警）+ fallback 1000→500；ai_straight_pounce_proximity=200 顺带创建；sprint/crouchPrep/highPounce 边界随 fPounceRange 自动收窄
- **[通用绕行增强]** BT_StuckDetour 绕行时朝向偏转 ±90° + IN_FORWARD 沿墙走（v5.2 只加横移键 = 横移方向也贴墙时死锁）；StrafeRandom 接入（Spitter 守位横移贴墙受益）
- 版本 5.3.0，smx 62401 bytes，备份 `.bak.20260805_v52_pre_v53`
- ⚠️ 装盘未 reload（玩家在玩，静默规则）；reload 副作用 = 在场 bot 回原版 AI 直到重生
- 待实测：Smoker 拉中后退拖拽是否断舌/观感、Hunter 500u 扑击命中率（可调 ai_fast_pounce_proximity）

## 待验证（部署后）

- 空服标定 ai_tank_rock_pitch_offset（石头弹道弧线垂直误差）
- 实战：C 冲倒/H 扑倒/Sp 吐到/J 骑上 → Tank 是否冲进窗口拳杀被 pin 者；贴车/贴罐生还者被 Tank 转打 prop 爆炸击杀；长距投石命中移动靶
- BT 节点预算 ~648/768（每加功能前先数）

相关：[[l4d2-hardsi-boomedprop-crash]] [[l4d2-si-tactical-v4]] [[l4d2-dont-touch-server]] [[l4d2-source-code-location-pitfall]] [[l4d2-tank-ai-fix]]
