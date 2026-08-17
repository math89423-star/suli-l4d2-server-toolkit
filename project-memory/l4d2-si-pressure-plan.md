---
name: l4d2-si-pressure-plan
description: ⚠️ 已废弃（2026-08-16 用户拍板，见 l4d2-pressure-system-removed）——SI 压力体系升级计划（2026-08-13 定稿入档），被 tank_wave_mutator 波次突变设计替代
metadata: 
  node_type: memory
  type: project
  originSessionId: 84e3242d-ad42-4f7c-b86b-9435fdc99ebc
  modified: 2026-08-16T02:30:00.000Z
---

# SI 压力体系升级计划（2026-08-13）—— ⚠️ 已废弃存档

> **2026-08-16 用户拍板废弃**：压力值被"特感波次有条件突变为 Tank 波次"
> （tank_wave_mutator）替代。本条仅存档历史，勿再实施。
> 全套拆除记录见 [[l4d2-pressure-system-removed]]

计划全文：**仓库根 `SI_PRESSURE_PLAN.md`**（/opt/gameservers/l4d2/data/addons/sourcemod/，未提交 git）。

- **定版不动**：1人2特（基准8，+2/人，类别上限22封顶）；清缴期→冷静期结构；`ss_incap_compensation 1.0` 安全网
- **已批准全套（用户拍板"全套+动态化"，未实施）**：基础收紧 cvar 包 + 动态冷静期（健康8-10/受伤14-18）+ 动态波间隔（16-22/28-35，post-rest 钳位10→6）+ **类-段匹配**（specialspawner 发布 `ss_spawn_dir`，si_comp 按段乘亲和系数：前=Charger/Smoker、中=Spitter/Boomer、后=Hunter/Jockey；零比例类不受影响；终章中性）
- **追加 A-D 待定**：A 倒地围猎波⭐ / B 完美清剿惩罚⭐ / C 反蹲点波 / D 动态清剿阈值
- **用户新构想：环境压力值**（下次详谈）——统一压力指数驱动冷静期/间隔/阈值/围猎强度；A-D 为其执行器；要点：指数定义、计算周期、衰减曲线、输出映射
- **实施顺序**：环境压力值定稿 → 全套代码（specialspawner v2.1.0 + si_comp v2.5.0）→ A-D 整合 → 编译部署空服 reload → git

相关：[[l4d2-specialspawner-config]] [[l4d2-si-composition-manager]] [[l4d2-si-tactical-v4]] [[l4d2-si-ai-audit-v56]]
