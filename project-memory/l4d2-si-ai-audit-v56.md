---
name: l4d2-si-ai-audit-v56
description: 全特感呆傻行为审计（v5.6.0，30+ 修复）——从 ai_debug 数据推出 7 特感真实行为问题
metadata: 
  node_type: memory
  type: project
  originSessionId: 38fc3311-e549-4c1b-8496-6305d254d598
  modified: 2026-08-05T04:29:00.457Z
---

2026-08-05 全特感呆傻行为审计（用户要求"根据代码推出游戏内真实行为"）。用 ai_debug 日志（L20260805.log，v5.4.2 基线 3558 条采样）做数据驱动定位，6 个并行 agent 深审各特感源码，v5.6.0 落地 30+ 修复（已部署 reload）。

## ai_debug 基线证据（修复前）
- Smoker b9(approachAct) 92%——850u 内也不拉；dist 386-4800u 折返
- Charger b3(breakthroughApproach) 77%——52s 从 3807u 绕到 837u
- Jockey b14(strafeApproach) 79%——1603u 完全不动 6s+；b13 贴脸 38s 只动 204u
- Spitter b11(defaultSpit) 39% 站桩吐 26s + b12(wander) 41% 乱走
- Boomer b12+b14 走位 89%，呕吐分支采样近乎 0

## 六大跨特感共性根因（全在 bt_common.inc / bt_core.inc）
1. **CND_HasLOS 依赖引擎 m_hasVisibleThreats**——插件每 2 帧覆盖朝向/按键后引擎视野更新失真，Smoker 路径实测几乎恒 0 → 拉人 6 分支全灭 → 92% 走位。修复：新增 CND_HasTargetLOS（TR_TraceRayFilter 到 BB target，LOS_TraceFilter 保留幸存者阻挡），替换所有远程攻击分支
2. **Cooldown 在 FAILURE 时也武装**（bt_core.inc）——失败分支每 1.8s/12s 才重试一次（"评估量子"）。修复：只 SUCCESS 武装
3. **ACT_ErraticApproach 每 tick 重掷 ±30° yaw**——移动方向白噪声（Hunter 同模式 v5.5 已修）。修复：0.4-0.9s 节拍缓存
4. **BT_StuckDetour 绕行方向每帧相对当前朝向 +90° 叠加**（旋转成圈）+ 绕行位移被自己的检测取消（只跑 0.75s）。修复：yaw 绝对化 + 绕行期跳过检测 + 连续 3 轮卡死跳一下
5. **CND_IsInRange 量"最近幸存者" vs 动作瞄"黑板 target"** 口径不一致。修复：新增 CND_IsTargetInRange 系列
6. **ACT_CircleFlank/FlankApproach 横移键方向错误**——aim 目标+120° 时按 MOVERIGHT(=目标+210°)，cos120°+cos210° 双向外扩 → 绕圈后退（Charger 52s 绕路根因）。修复：横移键取反 + target 无效自获取（原空 RUNNING 占位冻结）

## 各特感专属修复（v5.6.0）
- **Spitter**：SpitReady 冷却门 ×8 分支 + postSpitHold 改 300-600u 距离带（StrafeRandom 守位/<300u Retreat，修复 v5.4.2 送脸回归）+ postSpitHoldFar 补链（断 600-900u 死循环：postSpitHold ≤600 门槛断链 → defaultSpit 每 tick 按吐+刷新时间戳 → 解锁永不到达）+ mode6Spit 加门（原无条件每 tick 吐饿死全树）+ noLOSApproach 分支 + 吐键移入 target 有效分支
- **Smoker**：选人 4s 时效（原每 2s 最近/最远交替折返）+ 拉人序列移除每 tick 重选 + 全拉人分支 HasTargetLOS/IsTargetInRange + ledge/narrow 补 850 门 + SnapAimToBlackboardTarget + closeRangeStrafe 350→850 + approachAct 加 >850 门控
- **Boomer**：呕吐锁移到真实命中（player_now_it 事件设锁，原按 ATTACK 瞬间锁 10s）+ 按住 ATTACK 至事件/2s 超时（单帧按键被 boomer_vomit_delay 0.1s 风阻吞掉）+ 补刀分支 target 口径 + narrowHoldVomit 删死代码 + IsTargetWatchingAttacker 语义修正（原"我瞄谁"恒 true）
- **Jockey**：8 个地形分支补 AcquireClosestTarget（出生冻结）+ closeRangeStrafe 6s 超时 + hopSeq 700→450（引擎有效 leap 250-400u）+ LOS/距离口径
- **Charger**：全冲锋分支 HasTargetLOS/target 距离（对空气冲）+ blindCharge RandomChance 0.5s 缓存（冲-走闪烁）
- **Tank**：兜底 rockSeq 补 LOS（穿墙扔石）+ openStrat1_Charge 700→150 / ledgePunch 300→150（对空气挥拳，引擎近战 ~110-150u）+ 窄巷 ≤120u 贴脸拳分支 + 处决掷骰 1.5s 节拍
- **调试**：ai_debug 改读 g_iBTLastWinningChild（SUCCESS 分支命中时原读 RunningChild=-1 → "从不攻击"是观测盲区）

## 部署状态
v5.6.0 reload 12:22:06，备份 v55_pre_v56。ai_debug 保持 1。**待玩家实测验证**：Smoker 是否开始拉人（b9 占比应大幅下降）、Charger 冲锋频率、Spitter 站桩吐消失、Boomer 300u 内真吐、Jockey 不再冻结。相关：[[l4d2-ai-hardsi-engine-tuning]] [[l4d2-hunter-sprint-pounce-fix]]

## v5.26 StuckDetour 跳跃脱困增强（2026-08-16，commit 6ce3d8b）

**用户实测**："好多特感被地形卡住很呆，不知道跳跃离开卡住点"。

**根因**：v5.6 的"连续 3 轮卡死跳一下"是**单帧** IN_JUMP——单帧按键被引擎吞
（boomer_vomit_delay 0.1s 风阻同款教训）+ 要等 3 轮（0.4s×3 + 绕行时长 ≈
5-6s）才跳一次 → 玩家看到的"呆"。

**修复**（bt_common.inc BT_StuckDetour）：
1. **停滞即跳**：检测到停滞（0.4s 无位移）立即注入跳跃窗口 0.4s（不用等 3 轮）
2. **跳跃多帧化**：绕行激活期间每决策帧 `BT_AddButton(IN_JUMP)`（跳跃窗口内
   持续注入——多帧跳才能翻过矮墙/瓦砾/铁丝网/几何缝）
3. **连续 3 轮仍卡 → 长跳窗口 0.8s**（翻更高障碍，轮数重置）
4. 脱困（有位移）自动清跳跃窗口；跳跃与绕行方向并存（跳着斜向移动）

部署：AI_HardSI_bt v5.26.0 热加载（19:45），源码
`AI_HardSI_optimized/bt_common.inc` + `AI_HardSI.sp`。
