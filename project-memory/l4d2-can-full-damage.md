---
name: l4d2-can-full-damage
description: ✅已解决（2026-08-02 v1.2.1）：打爆罐子的幸存者自己不掉血不震退=引擎归属者豁免（旁路扣血不调 hook）；注入三路径方案 + 火炮 inflictor 参数铁律
metadata: 
  node_type: memory
  type: project
  originSessionId: 44850004-0478-4acc-a2ca-a4f01f8a7381
  modified: 2026-08-02T12:24:21.747Z
---

# L4D2 打爆罐子自伤修复（l4d2_can_full_damage v1.2.1，2026-08-02 用户实测通过）

**问题**：玩家打爆罐子（地图/商店/火炮任意形态），自己贴脸不掉血不震退（队友/特感正常掉血）。
**根因**：引擎旁路规则——爆炸伤害归属=击杀者（打爆者）；归属者本人被完全豁免（伤害+震退）。该伤害**不调 OnTakeDamage hook**（FFDIAG 实测零记录）、与 cvar 无关（FF factor/forgiveness 改回原版测试无效）。wiki 说原版贴脸掉 5-30——实测本服务器归属者≈0（旁路豁免）。

## 注入三路径（插件 l4d2_can_full_damage.sp）

罐子爆炸瞬间对打爆者注入伤害+stagger，**attacker=world(0)**（gl_splash_fix v2.1.4 套路：世界归属无主→不触发豁免/FF 缩放；武器实体当 attacker 会被引擎解析归属到武器主人=自己→又豁免，20:08:17 实测注入 20 不掉血）。

1. **prop_physics / prop_dynamic**（地图罐子=prop_dynamic！CAN-LIKE 诊断实测；prop_physics 是生成态）：hook 罐子 OnTakeDamage 记录最后玩家攻击者 → OnEntityDestroyed 注入
2. **weapon_propanetank 等武器形态**（捡过/扔出的罐子）：引擎武器伤害路径**不调 TakeDamage hook**（打爆者拿不到）→ **爆炸侧反推**：爆炸打其它罐子时 hit 里 inflictor=爆炸源+attacker=打爆者 → 0.01s 延迟 BoomInject 补注入（防重复 g_bInjected）
3. 伤害公式：sm_can_dmg_max 30 × (1-dist/350)，贴脸≈30；stagger 用 L4D_StaggerPlayer

## 排查踩坑（防回退）

- **罐子 classname 三形态**：prop_physics（生成态）/ **prop_dynamic（地图罐子！）**/ weapon_*（拾取丢弃态）——IsCanClass 全列
- **SDKHook 返回 false ≠ 挂不上**：同一实体重复挂同回调返回 false 但 hook 实际生效（20:02:13 有 hit 记录证明）——不要被 ret=FAIL 吓住
- **地图罐子=prop_dynamic**：sweep 只扫 prop_physics 会漏掉（20:12:09 CAN-LIKE 诊断发现 8 个）
- 爆炸传播（波及 hit）发生在 DESTROYED 之后（日志 2 秒差是时间戳精度/互转干扰）
- 用户测试的罐子反复互转（created/DESTROYED 循环）——weapon 形态 hit 拿不到

## 相关

- [[l4d2-tank-spawn-explode]]（罐子爆炸机制 + v1.7.93 正解）
- [[l4d2-artillery-strike]]（火炮 v1.7.98 定稿：inflictor=召唤者铁律）
