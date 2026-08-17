---
name: l4d2-loot-drop-v180
description: 击杀掉落 v1.8.0 定稿掉落表 — 小僵尸1% / 特感4%单件 / Tank 3件 / Witch 35-35-15-15
metadata: 
  node_type: memory
  type: project
  originSessionId: 80f85ddb-7525-4c46-b293-14a39d34a830
  modified: 2026-08-03T07:45:25.452Z
---

# L4D2 击杀掉落 v1.8.0（2026-08-03 部署，commit 952dc39）

源码/配置：`scripting/l4d2_loot_drop.sp` + `cfg/sourcemod/l4d2_loot_drop.cfg`（仓库 addons/sourcemod）

## 掉落表

| 来源 | 概率 | 物品 |
|------|------|------|
| 小僵尸 | 1% (`sm_loot_common_chance` 1.0) | 胆汁/土制炸弹 50/50，1 件 |
| 特感 | **4% 单次 roll，有且只有 1 件** | 燃烧瓶 1% (`sm_loot_si_molotov` 1.0) + 药品组 1% (`sm_loot_si_meds` 1.0，止痛药/肾上腺素 50/50) + 弹药包组 2% (`sm_loot_si_packs` 2.0，燃烧/高爆 50/50) |
| Witch | 必掉 4 选 1 | 高爆弹包 35% / 燃烧弹包 35% / 医疗包 15% / 电击器 15% |
| Tank | 必掉 **3 件** | 装备 4 选 1（医疗包/电击器/M60/榴弹各 25%）+ 投掷物（土制40/燃烧瓶30/胆汁30）+ 小药（止痛药/肾上腺素 50/50）|

## 变更要点

- 特感：5 独立 roll（合计 7%）→ 单次 roll 4%（原 10% 版本之前）；删 `sm_loot_si_adrenaline/pills/explosive/incendiary`，新增 `sm_loot_si_meds`/`sm_loot_si_packs`
- Tank：5 件（医疗包必掉+3投掷物+M60/榴弹）→ 3 件，医疗包不再必掉
- Witch：池里燃烧瓶→燃烧弹包，权重 25/25/25/25 → 35/35/15/15

## 坑

- **引擎对 Witch/特感死亡也触发 infected_death** → `Event_InfectedDeath` 必须 classname=="infected" 守卫，否则 Witch/特感死亡会额外触发小僵尸 1% 双掉落
- `sm_loot_si_molotov` def 残留 2.0（引擎残留坑，见 [[l4d2-source-code-location-pitfall]]），值由 cfg exec 拉回 1.0；改 cfg 后必须 reload 插件
- 2026-08-03 14:41-14:57 曾有临时改动把 common_chance 设 2.0（非登记改动，reload 后已回 1.0）

相关：[[l4d2-shop-default-prices]] [[l4d2-si-hud-scoring]] [[l4d2-announcements]]

## v1.9.0 移除 Tank 的 M60/榴弹掉落（2026-08-17 用户拍板）

**原因**：M60/榴弹可补给弹药（弹药堆补丁）后全程持续作战，Tank 再掉落不合理。
**改动**：装备池 4 选 1（医疗/电击/M60/榴弹）→ **2 选 1（医疗包/电击器 50/50）**，
Tank 必掉 3 件结构不变（装备+投掷物+小药）。
