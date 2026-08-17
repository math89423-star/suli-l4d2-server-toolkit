---
name: l4d2-tank-spawn-explode
description: ✅实测通过（v1.7.98 2026-08-02）：爆炸罐 = prop_physics + 罐模型直生；weapon_* 不可炸（propdata）；引爆 inflictor=召唤者铁律 + 打爆者自伤注入（l4d2-can-full-damage）
metadata: 
  node_type: memory
  type: project
  originSessionId: 9497bfe5-ae98-4821-a86e-4b1d5751a883
  modified: 2026-08-02T12:24:41.931Z
---

# L4D2 可爆炸罐子：✅ 已解决（v1.7.98，2026-08-02 用户实测通过）

**v1.7.98 补充（2026-08-02）**：引爆参数 `TakeDamage(ent, ent, buyer)`（attacker=罐子, inflictor=召唤者）——**爆炸归属跟随 inflictor**，v1.7.94 把 inflictor 改成 ent 导致爆炸伤害全灭（详见 [[l4d2-artillery-strike]]）。打爆罐子的幸存者自己不掉血=引擎归属者豁免（旁路不调 hook）→ l4d2_can_full_damage 插件注入修复（[[l4d2-can-full-damage]]）。已 commit f0b540a。

v1.7.80-92 六版本未解的核心问题，**v1.7.93 用户实测通过**（火炮罐子落地爆炸 + 商店罐可打炸）。**正解：直接生成 `prop_physics` + 罐模型 = 地图罐子等价物，死亡/点燃过热 → 引擎爆炸全原版（音效/火球/伤害/友伤缩放）。**

## 两个坑的教训（防止回退）

1. **weapon_* 类名罐子不可炸**（v1.7.80-91 全线失败的根因）：爆炸能力由模型 propdata（`physgun_interactions onbreak:explode_fire`）承载，只有 prop_physics 破碎时触发；weapon_* 不走 propdata 破碎路径。
2. **give+drop 双死穴**（v1.7.92 失败）：①`drop` 命令掉的是**当前手持武器**，不是新给的罐子（GivePlayerItem 塞 slot4，玩家手持主武器 → 罐子留在手里）；②就算掉出，掉落保持 weapon_* 类名不炸（"捡起再扔才炸" = 引擎互转）。**禁再用 GivePlayerItem+drop 生成罐子。**

## 根因（社区+引擎证据链，全部查证过）

1. **爆炸能力由模型 propdata 承载**：模型的 `$keyvalues` 里 `physgun_interactions { onbreak explode_fire }` + `prop_data` 爆炸参数（props_shared.h/cpp 机制，Valve 维基 Prop Interactions 页）。触发条件 = **prop_physics 破碎/死亡**（CPhysicsProp 走 propdata 破碎流程）。
2. **weapon_* 类名实体不走 propdata 破碎路径** → 生成态 weapon_propanetank 死亡静默消失（v1.7.91 实锤 hp=-99942 无声无火）。"玩家捡起再丢下会炸" = 引擎把 prop_physics↔weapon_propanetank 互转，丢回世界态即恢复 prop_physics。
3. **社区定论**（两个独立插件殊途同归）：
   - [L4D1 & L4D2] Weapon Prop Give Fix（Marttt, t-331053）：`give propanetank` 掉出 weapon_propanetank 不可 break/ignite/explode；**正确 classname 是 prop_physics**。机制：等实体无主（m_hOwnerEntity==-1）→ 读 pos/ang → Kill → 原地重建 `prop_physics` + `DispatchKeyValue model` + `DispatchSpawn`。180+ 服务器在用。
   - Physics fix（disawar1, t-178076）：同问题，实体创建后 0.01s 重建为 physics prop。
   - Fireworks Party 帖："you have to pick up and drop the crate for it to explode" = L4D 引擎已知行为。

## v1.7.93 实现（已编译，scripting/l4d2_si_hud.sp）

- **火炮罐**（Timer_ArtSpawnCan）：`CreateEntityByName("prop_physics")` + `DispatchKeyValue model`（propanecanister001a 70% / oxygentank01 30%）+ `DispatchKeyValueVector origin`（直接生成在落点上空，不经世界原点）+ `DispatchSpawn` + `m_takedamage=2` → Art_LaunchCan（health 500 防燃烧中途过热自爆 ≈31s，点火 fallT+burn，落地后 TakeDamage 99999 DMG_BLAST → 引擎死亡爆炸）
- **商店罐/桶/烟花**（ShopSpawn）：Art_ExplosiveModel 映射 4 类（propanetank/oxygentank/gascan/explosive_box001 模型），生成 prop_physics + trace 落地面 + glow + takedamage/health 100。**可捡可扔可炸完整原版体验**（E 捡起引擎自动转拾取态，扔出转回 prop_physics）。
- 删除：v1.7.92 give+drop 全部（Timer_ArtCanDrop/Timer_ShopCanDrop/ShopSpawn buyer 参数）；v1.7.87-90 手搓爆炸（Art_DoExplosion 等）；si_hud_art_damage cvar（爆炸伤害由 propdata 决定，原版 200 falloff）
- precache：4 模型（propanecanister001a/oxygentank01/gascan001a/explosive_box001.mdl）
- v1.7.87 手搓 env_explosion 的教训（无音效/一击必杀）不再相关——引擎爆炸自带音效/火球/友伤缩放

## 实测结果（2026-08-02 用户确认）

- 火炮罐子爆炸 ✓（核心目标达成，音效/火球/伤害原版）；商店罐打炸 ✓（"现在确实可以了"）
- 未逐项确认：空中提前打炸、油桶/烟花、捡起扔出（同机制，风险低）
- 假 1.7.93 插曲：上次会话改了 PLUGIN_VERSION=1.7.93 但代码仍是 v1.7.92 give+drop → 用户 18:38 部署测试失败（罐子在手上/要拾取才炸）→ 排查时先查 `sm plugins info` 的 Hash/Timestamp 对照编译时间，别信版本号。cvar si_hud_version 跨 reload 保留旧值（显示 1.7.85）也是同一类坑

## 遗留

- ✅ v1.7.80-93 已 commit + push（e41c0f2 等 4 个提交，2026-08-02）
- 火炮支援1（原「区域火炮空袭」）正式命名，**价格用户定稿暂定 1 分**（非 TEMP-TEST，随时可调）；火炮支援II 同 1 分
- 15 个 si_hud_art_* cvar 中 si_hud_art_damage 已删
- 相关：[[l4d2-artillery-strike]]（火炮I 机制描述已过时，以本文为准）
