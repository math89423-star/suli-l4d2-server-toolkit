---
name: l4d2-c1m2-missile-asset
description: ✅ 已被火力支援IV-AGM导弹（artillery6）使用（v1.8.0，2026-08-15）：模型 f18_agm65maverick.mdl + explosion_huge_* 粒子 + 三音效；素材明细见 [[l4d2-agm-missile]]
metadata: 
  node_type: memory
  type: project
  originSessionId: 0af04725-63ca-46d2-b24b-87cd8e513c61
  modified: 2026-08-16T14:20:00.000Z
---

# ✅ 已投入使用（2026-08-15 v1.8.0）

本素材的调研结论已被「火力支援IV-AGM导弹」（artillery6/kind6）完全采用（l4d2_shop.sp
3947+ 行）：模型 f18_agm65maverick.mdl（prop_dynamic_override 手推轨迹，无 .phy
不能用 prop_physics）+ explosion_huge_e/b/c/h/flames/burning_chunks/smoking_chunks
粒子 + overpass_jets/terrain_rumble1/Tanker_Explosion 三音效。全部原版零客户端
分发 ✓。完整实现/参数/坑 → [[l4d2-agm-missile]]。

2026-08-03 挖 c1m2 武器店飞弹素材（火炮支援插件想用的原版飞弹，用户指引"社区必有"→ 服务端 VPK 实证）：

- **模型路径（已实证）**：`models/missiles/f18_agm65maverick.mdl`（AGM-65 小牛导弹，VPK 索引 `pak01_dir.vpk` 直接 grep 到，含 `.dx90` 变体）。**原版资产 → 客户端自带 → 无分发问题**，避开 [[l4d2-meatwall-hulk]] 式死结
- **音效**：`missile_loop_1.wav`（c1m2 BSP 内有引用）
- **c1m2 实体层无静态 rocket 实体**（实体文本全扫无 rocket/missile）→ 飞弹由 VScript `vscripts/c1m2_streets.nut`（VPK 内）动态生成
- **未完成**（用户叫停"不纠结了"）：FGD 里 `rocket` 实体的键值定义（Damage 等）+ nut 的生成参数（origin/angles/Speed）——下次直接从 VPK 提取 nut 文件读，目录 `vscripts/c1m2_streets`
- **服务器 BSP 是镜像重排格式**：lump 偏移全 0、数据顺序排布，实体文本在偏移 846212 处起（标准解析器读不了，dd 提取即可）
- 待办方向：`CreateEntityByName("rocket")` 直生（社区已有类似用法），或照 nut 抄 spawn 参数；与 [[l4d2-artillery-strike]] 火炮支援集成
