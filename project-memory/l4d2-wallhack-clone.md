---
name: l4d2-wallhack-clone
description: 透视特感（!shop 商品）最终定稿 — 全局蓝色高亮（6000/3分钟/播报）；克隆方案废弃原因 + 三个致命坑
metadata: 
  node_type: memory
  type: project
  originSessionId: 03f69862-a229-435f-8ff1-ec1287370f0a
  modified: 2026-08-12T15:17:27.336Z
---

# L4D2 透视特感（si_hud v1.7.79 定稿，2026-08-02）

> 商店"透视特感"：**4000 积分 / 3 分钟 / 全局蓝色高亮**（v1.8.2 用户改回，
> 2026-08-03 部署；v1.8.1 定稿为 4000/5 分钟；v1.7.79 定稿为 6000/3 分钟）；
> 生效期间不可重复购买（v1.0.10 起拦截，WALLHACK_CAP 续费封顶已删除）；
> 死亡/切图/重开/闲置失效，结束后可再买。购买全服播报剩余时长 + 结束前 30 秒提醒。
> 提交 ebc209c 起（git: addons/sourcemod）

## 最终实现（v1.7.67 起，用户验证通过）

- **直接给特感实体加发光**——与商店物品同机制：`m_iGlowType 3` +
  `m_nGlowRange 999999`（大数而非 0，防"0=禁用"语义）+ `m_glowColorOverride`
  蓝色 `0|0<<8|255<<16|255<<24`。轮廓完美贴合动作（用户实测通过）
- **全队可见**（co-op 团队增益，用户认可）；任一购买者生效 → 全部特感
  蓝色（特感/Tank/Witch 全包，Witch 走 g_hWitchList）
- 0.5s 心跳计时器幂等补光新刷新的特感；最后一位购买者结束立即清光
- **reload 安全网**：OnPluginStart 调 WallhackClearGlow 清残留发光
- **播报（v1.7.68，用户需求）**：购买时 PrintToChatAll
  "[商店] %N 购买了特感透视，剩余生效时长：300 秒"（v1.8.1 起读 WALLHACK_DURATION）；结束前 30 秒
  一次性提醒 "[商店] 特感透视剩余 30 秒"（g_hWallhackWarnTimer 随
  效果生命周期杀除；回调内先置空防杀已关句柄）

## 克隆方案（v1.7.64-66）废弃原因——三个致命坑

1. **prop 不播特感动画** → 冻结人偶轮廓不贴动作（用户否决的根本原因；
   社区"克隆+SetTransmit"方案的前提视觉不成立）
2. **SM 1.12 PushArray 传 enum struct 只拷贝首字段**（实测铁证：同目标
   10 克隆/秒 churn + 垃圾 target 偶发 0 → "Client index 0" 异常 733 次）
   → 必须用固定数组或显式 size
3. **CancelMenu 触发回调 client/item=-3** → handler 必须 `item>=0&&client>=1`
   防护；L4D2 vgui 面板 CancelMenu/CancelClientMenu 都关不掉（面板关闭
   仅客户端 ESC/超时）——!buy 二次关闭功能最终效果待用户确认

## 死亡残留发光修复（l4d2_shop v1.7.5，2026-08-12，commit 40673ba + be6b309）

**症状**：透视生效期间，特感（用户报 Spitter）/ Witch 死亡后蓝色透视框不消失。
**根因**：① WallhackApplyGlow/WallhackClearGlow 都 `!IsPlayerAlive` 跳过 → m_iGlowType 3 残留在尸体上没人清；② 0.5s 心跳 ApplyGlow 每轮把死亡残留实体（包括 Witch 尸体）重新上光 → 框永不消失；③ Event_PlayerDeath 只处理队 2（幸存者），队 3 特感死亡无清理路径。
**修复**：
- Event_PlayerDeath 队 3 分支立即 `SetEntProp m_iGlowType 0`；Witch 分支用 `event.GetInt("entityid")`（= Witch 实体索引，si_hud 同款检测）+ IsWitchEntity → 清光 + g_hWitchList 剔除（Witch 死亡走 player_death，entityid 字段即实体号）
- 心跳 ApplyGlow 对 `!IsPlayerAlive(i)` 特感改为清光跳过；Witch 用 `Prop_Data m_iHealth<=0` 判定死亡 → 清光 + 表剔除
- ClearGlow 对死亡特感不再跳过（全队 3 一律清）；失效/死 Witch 一并剔除表
- 兜底 `WallhackClearRagdolls()`：全图扫 physics_prop_ragdoll，HasEntProp 守卫下有 m_iGlowType 且非 0 的清 0

**教训**：发光挂在实体 prop 上 = 死亡/失效实体必须自清理 + 心跳不能盲补光。HasEntProp 守卫防 SM 1.11+ 无 prop 实体崩溃。

**部署状态**：2026-08-12 23:16 RCON 热更完成（`sm plugins reload l4d2_shop`，日志确认 "loaded v1.7.5"）。reload 副作用：在线玩家的透视效果被清除（OnPluginStop 终止），需重新购买。

## 其他经验

- [[l4d2-bf-kill-hud]] — 商店主体（分类菜单 + 商品表 v1.7.64）
- [[l4d2-printhinttext-priming-bug]] — 同类"引擎实际行为与直觉不符"
