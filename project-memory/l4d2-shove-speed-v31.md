# L4D2 推搡加速（已废弃回退 v2.0，2026-08-17）

> **⚠ 2026-08-17 14:24 用户拍板废弃回退**：极端值（penalty=0 + z_gun_swing_interval 0.35）实测仍无明显变化 → 不要此功能。已恢复 v2.0（penalty/2 减半）+ z_gun_swing_interval 0.7，守护 job 与插件 cfg 已清理，commit `ccaa9ba`。**教训：改 z_gun_swing_interval 连近战都该加速一倍却没变化，引擎推搡间隔或另有机制（未深究，用户放弃）**。

---

# 原实现记录（已回退）

> 用户需求：配合特感增强，推搡速度 +30%（10s 10 次 → 13 次）；实测无感后拍板**极端值 +100%**。
> commit `26f65f8`（v3.0）+ `b5b9ace`（v3.1 极端值定稿）。

## 引擎推搡机制（踩坑后实锤）

- 推搡冷却 = `z_gun_swing_interval`（基础挥击间隔，服务器 0.7）× 疲劳系数
- 疲劳 = netprop `m_iShovePenalty`：每次推搡引擎设 [min,max] 区间值——coop 模式
  cvar `z_gun_swing_coop_min_penalty`(5) / `z_gun_swing_coop_max_penalty`(8)；vs 模式 3/6
- **⚠ 关键坑：引擎在推搡瞬间用当时的 penalty 计算冷却**——插件 0.1s 后覆盖太晚，
  target=1 与原来减半后的 2-4 差别太小 → 用户实测"没感觉到明显变化"
- 没有 z_shove_* 专用 cvar（z_shove_penalty/interval 都不存在）；推搡与近战**共用**
  z_gun_swing_interval → 改它会连带近战挥击加速（用户已接受：应对特感增强）

## 定稿配置（极端值，推搡 ~+100%）

| 项 | 值 | 说明 |
|---|---|---|
| `sm_shove_penalty_target` | **0** | 推搡后 penalty 直接设 0（无疲劳；v2.0 是 /2） |
| `z_gun_swing_interval` | **0.35** | 基础间隔 0.7→0.35（-50% 间隔 = +100% 频率） |

- 插件 v3.1：Timer_SetShovePenalty 直接 SetEntProp(m_iShovePenalty, target)；
  监听 IN_ATTACK2 新按下 + L4D_OnShovedBySurvivor_Post（双保险）
- **持久化**：cfg/sourcemod/l4d2_shove_fatigue_scaler.cfg 已写 0（AutoExecConfig
  不会覆盖已存在文件——手动改）；z_gun_swing_interval 0.35 已加入守护 job
  `/tmp/aihardsi_guard.sh`（每 45s 校正，防换图/重启复位，同 punch/nb_update 机制）
- 只处理玩家（IsFakeClient 排除），bot 推搡不受影响

## 若用户嫌太快/太慢（不再改代码）

- 推搡频率 ↔ `z_gun_swing_interval`（推搡+近战同变）
- 只调推搡不动近战：不可行（引擎共用间隔，无独立推搡间隔 cvar）

相关：[[l4d2-deployment-rules]]（推搡疲劳整数除法记录：原 /3 清零无限制→插件 /2 轻微疲劳）
