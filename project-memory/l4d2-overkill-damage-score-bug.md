---
name: l4d2-overkill-damage-score-bug
description: AGM 导弹等超额伤害注入导致 si_hud 伤害分爆炸（几十万分），钳制到目标最大血量修复
metadata: 
  node_type: memory
  type: project
  originSessionId: 152e2ef5-e8e5-4c25-94f8-db8f5c6bd640
  modified: 2026-08-15T07:53:23.329Z
---

**症状**：商店火力支援IV-AGM导弹（artillery6）一发实战可得几十万分。

**根因**：si_hud 伤害分直接读引擎上报的伤害量，但 AGM 秒杀特感时注入的是巨额伤害（`l4d2_shop.sp` V1_Detonate：核心区特感 **900000**、小僵尸/Witch **10000**；⚠ v1.9.1 起 1/2 圈层特感/Tank/Witch 统一 **99999**，见 [[l4d2-agm-missile]]），引擎的 `player_hurt.dmg_health` / `infected_hurt.amount` / Witch `OnTakeDamage` 的 damage 参数会**原样上报注入值而非实际扣血**。250 血 Hunter 被算成 900000 × 倍率 × 0.1 系数 = 9 万分/只，一发命中 5-8 只 = 几十万分。

**击杀分不受影响**：`PointsForSI` 已用 `m_iMaxHealth` × 25% 计算，本来就对。只有**伤害分**信任了引擎上报值。

**修复（si_hud v1.13.1, 2026-08-15）**：伤害分计算前钳制伤害到目标最大血量，三处：
- `Event_PlayerHurt`（特感）：`dmg` 钳到 `m_iMaxHealth`（Prop_Data）
- `Event_InfectedHurt`（小僵尸）：`amount` 钳到实体 `m_iMaxHealth`（通常 50）
- `WitchTakeDamage`（女巫，SDKHook pre 阶段）：`damage` 钳到当前 `m_iHealth`

用 maxHP 作上界：满血特感精确，残血特感略高估但幅度有限（AGM 通常打满血新刷特感）。此修复对所有"超大伤害注入秒杀"的插件路径通用。

关联 [[l4d2-si-hud-scoring]] [[l4d2-c1m2-missile-asset]]（AGM 素材）。✅ 2026-08-15 15:44 编译部署 + reload 生效（sm plugins info 确认 v1.13.1 running）。

⚠ 踩坑：reload 时有玩家在线 → 触发 si_hud 热重载副作用（在线玩家钱包清零，见 [[l4d2-si-hud-wallet-persistent]]）。以后 si_hud reload 尽量等空服。
⚠ si_hud_version cvar reload 后仍显示旧值（1.13.0）——CreateConVar 对已存在 cvar 不更新值的已知怪癖；判断版本以 `sm plugins info l4d2_si_hud` 为准，不看 version cvar。
