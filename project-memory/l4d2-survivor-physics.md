---
name: l4d2-survivor-physics
description: L4D2 幸存者物理数值表（跳跃/坠落伤害/下蹲/台阶/重力）——社区公认常量，引擎 cvar 已移除
metadata: 
  node_type: memory
  type: reference
  originSessionId: cc2853a6-d1b3-491b-b9dc-49d38e01bd2c
  modified: 2026-08-04T05:00:47.435Z
---

# L4D2 幸存者物理数值表（2026-08-04 整理）

## 数值表

| 项目 | 数值 | 说明 |
|------|------|------|
| **跳跃高度** | **66u** | 可跳上 66u 高台，>66u 跳不上 |
| **坠落伤害** | **66u 起**掉血，每 +100u ≈ 25 伤 | 166u≈25、266u≈50、466u 摔死 |
| **下蹲高度** | 45u | 站立高度 72u |
| **台阶高度** | 18u | sv_stepsize |
| **重力** | 800 u/s² | sv_gravity |

## 来源与坑

- **社区公认常量**（多年实测共识），非本服实测
- 引擎 cvar 查询失败：`survivor_fall_damage_multiplier` / `sv_gravity` / `sv_stepsize` / `sv_maxspeed` 在 build 2.2.4.3（2026-06-30）RCON 全 `Unknown command`——新版引擎已把物理参数硬编码移除，`find` 也查不到
- 记忆目录里没有专门的幸存者物理表（此前 2026-08-04 搜索确认）

## PTG 插件应用

`BuildVirtualEdges` 虚拟边高度差阈值 = **60u**（≤ 跳跃 66u 且 < 坠落阈值 66u，跳得上+摔不伤的安全上限）。历史：90u 放行跳楼边 → 45u 误砍可跳台阶 → 60u 定稿。

相关：[[l4d2-ptg-v5-flowline]] [[l4d2-weapon-values]]
