---
name: l4d2-deathcheck-disabled
description: 团灭判定恢复官方——cge_l4d2_deathcheck 已禁用（全队倒地即判负）
metadata: 
  node_type: memory
  type: project
  originSessionId: 38fc3311-e549-4c1b-8496-6305d254d598
  modified: 2026-08-05T03:49:41.033Z
---

2026-08-05 团灭判定恢复官方原版：`cge_l4d2_deathcheck.smx`（[L4D, L4D2] No Death Check Until Dead，fbef0102 编写）→ 改名 `.disabled` + 热卸载。

**背景**：该插件阻止 mission lost 直到所有人类幸存者死亡 → 服务器出现"全部倒地不重开，只有全灭才重开"。

**恢复后**：全队倒地（incapacitated）或死亡 → 立即判负重开（官方行为）。引擎侧 `director_no_death_check` 确认为 0。

**如需恢复**：改回 `.smx` 扩展名并 `sm plugins reload`。相关：[[l4d2-plugin-inventory]]
