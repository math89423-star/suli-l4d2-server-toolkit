---
name: l4d2-hardsi-boomedprop-crash
description: m_hasBeenBoomed 在本游戏版本(2.2.4.3)网络数据表不存在 → v4.0.2 Prop_Data→Prop_Send 是假修复（每晚数万异常）;v4.1.2 真修复 = L4D_OnVomitedUpon_Post 事件跟踪,22:14:30 后异常归零
metadata: 
  node_type: memory
  type: project
  originSessionId: ddf12f1e-34c7-4e92-89ed-86a89d6ed8b2
  modified: 2026-08-03T14:19:38.478Z
---

# AI_HardSI m_hasBeenBoomed 崩溃（2026-08-02 发现 + **2026-08-03 v4.1.2 真正修复**）

## ⚠️ 更正（2026-08-03 晚）：v4.0.2 的"修复"是假修复

v4.0.2 把 Prop_Data 改成 Prop_Send 只是**换了失败方式**——`m_hasBeenBoomed` 在
本游戏版本（2.2.4.3, left4devops 镜像）的**网络数据表里根本不存在**（`sm_dump_netprops`
全表实测无此属性）→ GetEntProp 依旧每晚数万异常（22:10 实测 3642 条/分钟），
BT tick 持续被中断。**v4.1.2（2026-08-03 22:14 热重载）真正修复**：
- 改用 `L4D_OnVomitedUpon_Post` 事件跟踪胆汁状态（`g_fSurvivorBoomedUntil[]`，
  ≈10s 失效，`Event_PlayerSpawn` Pre 对幸存者清零）→ `SI_IsSurvivorBoomed()`
- 替换 4 处 GetEntProp 调用点：hardcoop_util 747/808 + bt_spitter.inc:84 + bt_smoker.inc:221
- 验证：22:14:30 后异常归零（此前 3000-5000 条/分钟）；备份 /tmp/AI_HardSI_bt.smx.bak.v4.1.1
- 编译：AI_HardSI_optimized 目录内 `../../scripting/spcomp AI_HardSI.sp -o../compiled/AI_HardSI_bt.smx -i../include`（12 个 warning 全是预存的 symbol never used）

## 症状（发现时）

玩家实测"特感进攻欲望过低、v4.0.1 出生/蠕动修复没改善"。查 errors 日志实锤:
**当天 42,454 个异常里 42,418 个（99.9%）是同一个**:
`Property "m_hasBeenBoomed" not found (entity N/player)`
- `[8] Line 236, AI_HardSI.sp::OnPlayerRunCmd`（= BT_Tick 内）
- `[3] Line 273, bt_boomer.inc::OnPlayerBoomed`（= SI_SignalBoomerHit 内）

## 根因

`m_hasBeenBoomed` 是 **Prop_Send** 网络属性，代码用 **Prop_Data** 读 → 抛异常。
两处漏网（20260801 的 BoomedPropFix 只修了 bt_spitter.inc:84 / bt_smoker.inc:221，漏了 hardcoop_util.sp）:
- `hardcoop_util.sp:747` — SI_GetCoordinatedTarget 候选循环内（SI_IsBoomerActive 时必炸）
- `hardcoop_util.sp:808` — SI_AnySurvivorBoomaBiled（无调用方，僵尸代码）

## 破坏链（为什么"进攻欲望过低"）

Boomer 吐中 → SI_SignalBoomerHit → 开 5.5s 攻击窗口 + 全队突击 → 窗口内所有走协同分支的 SI
（Charger coordSeq、Hunter mode4/6 coordPounce、Smoker 3 处协同分支、CommandABot 循环）
→ SI_GetCoordinatedTarget → 抛异常 → **SourceMod 异常展开整个调用栈 → BT_ApplyMovement/
BT_ApplyAngles 被跳过 → 该帧 BT 输出全丢**。

效果：每次 Boomer 吐后 5.5s 窗口（本应是最猛的全队进攻时刻）插件 AI 完全失效，
只剩 vanilla AI（75% 帧本来就归它）。协同集火/酸液配合/地空协同全瘫；
BlockCharge 不跑 → vanilla AI 自由释放 charge → "出生对空气冲"在窗口期复活。

## 修复（v4.0.2,2026-08-02 13:32 部署,51733 bytes）

1. `hardcoop_util.sp:747` / `:808` → `Prop_Send`
2. `bt_charger.inc` CND_ChargerSpawnProtect 加 freshSpawn 兜底（`_charger_spawn_at` 在
   AI_HardSI.sp Event_PlayerSpawn 记录;覆盖运出复活出生即实体 / player_spawn 重发黑板重置）
3. 移除 narrowHoldSeq（HoldChokepoint 站桩是 Tank/Boomer 动作,Charger 走廊 400-600u 站桩不冲）；
   narrowChargeSeq 400→fChargeProx(750)
4. `TICK_INTERVAL` 4→2（BT 帧率 25%→50%,原版 AI 主导帧减半）
5. cfg: `sourcemod.cfg` sm_cvar ai_charge_proximity 500→750。**坑:AI_HardSI.cfg 是旧插件名
   (AI_HardSI.smx)遗留死配置,SM 只为 AI_HardSI_bt.cfg 自动 exec —— 实际生效只有 sourcemod.cfg**

验证:sm plugins info Version 4.0.2 running;errors 日志 13:17 会话轮转后无新 m_hasBeenBoomed。
备份:plugins/AI_HardSI_bt.smx.bak.20260802_v401_pre_v402（回滚:cp 回去 + reload）。

## 后续状态

- ✅ git commit：`b870267`（2026-08-03 清理批次时提交，v4.0.2 全量）
- ✅ 自然验证：v4.0.2 部署后无复发（后续版本见 [[l4d2-ai-hardsi-engine-tuning]]）
- 版本线：v4.0.2（本修复）→ v4.0.3（审计校准）→ v4.0.4（Boomer 射程对齐）——全部已部署

相关：[[l4d2-si-spawn-fixes]] [[l4d2-si-tactical-v4]] [[l4d2-ai-hardsi-engine-tuning]] [[l4d2-dont-touch-server]] [[l4d2-source-code-location-pitfall]]
