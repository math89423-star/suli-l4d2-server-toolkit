---
name: l4d2-witch-death-double-event
description: Witch 死亡双事件实锤（player_death 先发 + infected_death）— 终局：音效统一 si_kill.mp3（v4.4.7 用户拍板，witch_kill.mp3 从未到客户端）+ si_hud v1.7.59 统一女巫双 hook
metadata: 
  node_type: memory
  type: project
  originSessionId: f91b546c-e23d-45b1-b43f-6e6212ca8a4e
  modified: 2026-08-02T07:16:39.825Z
---

# L4D2 Witch 死亡双事件 + last-ent 排除机制（2026-08-02 终局）

## 引擎行为（实锤）

**Witch（NPC）死亡发两个事件**：`player_death`（entityid=witch，走 SurvivorKilledWitch）+ `infected_death`（NPC 归在 infected 事件体系，受伤走 infected_hurt 已先实锤，死亡同样）。日志实证：`[streak] settle kills=2 score=505` = 女巫固定分 500 + 小僵尸误入账 5 分，两事件都触发。

**infected_death 无 entityid 字段** → 区分 witch/小僵尸只能靠"last-hit 实体"回退（g_iLastCommonEnt 机制）。

## 教训：v1.7.56 修复自断防御

v1.7.56 修 infected_hurt witch 误加分时把分支改成**提前 return 不记录实体** → g_iLastCommonEnt 永不为 witch → v1.7.56 同时加的 Event_InfectedDeath 排除变**死代码** → Witch 死亡误当小僵尸（† 横幅覆盖女巫横幅 + 5 分误入连杀 + 伤害分网格串台）。**修复事件 A 时动了事件 B 依赖的状态，且没互相验证。**

## v1.7.58 修复（si_hud）+ v4.4.4（bf_killfeedback）

- si_hud `Event_InfectedHurt` witch 分支：**只记录 g_iLastCommonEnt = entId，加分排除保留** → 死亡排除（2052-2063）重新生效
- si_hud 小僵尸击杀卡读 dmgPts 前校验 classname 非 witch（防伤害分串台显示）
- bf_killfeedback：新增 infected_hurt hook 跟踪 last-hit 实体（witch 也记），Event_InfectedDeath 开头加 witch 守卫（classname 含 witch → return）；**共享 0.1s 冷却会吞音效**（player_death 先播 witch_kill.mp3，infected_death 的 csgo 后到被挡或反过来）——修复后女巫音效只走 player_death 分支

## 终局定论（2026-08-02，全部已验证/部署）

- **事件顺序实锤（v4.4.6 调试日志）**：Witch 死亡 **player_death 先发**（entityid=witch，走 SurvivorKilledWitch），infected_death 后到（<0.1s，被共享 0.1s 音效冷却挡住）。之前假设"顺序不定/冷却吞音效"全错。
- **女巫音效缺失根因 = witch_kill.mp3 从未到达客户端**：PLAY 调用日志实锤已执行（`[BF-debug] player_death witch: PLAY 'battlefield/witch_kill.mp3'`），服务端无任何逻辑问题；客户端有声的 si_kill.mp3 正常 → 纯分发问题。
- **用户拍板：废弃独立音效文件**——Tank/Witch/近战击杀音效全部统一 `battlefield/si_kill.mp3`（bf_killfeedback **v4.4.7**，三个 cvar `bf_kill_sound_tank/witch/melee` 默认值全改），爆头保留 si_headshot_kill.mp3。tank_kill/witch_kill/melee_kill.mp3 留在服务端但不被引用（无害，可清理）。
- **si_hud v1.7.59：统一女巫 OnTakeDamage 双 hook**（"击中女巫不显示伤害分"排查）：原 Event_WitchSpawn（v1.7.16 加分）+ OnEntityCreated（v1.7.25 显示）各挂一个 SDKHook_OnTakeDamage，调用顺序不定 → 显示读 g_iDmgPtsKiller 时加分可能未入账。合并为单 hook `WitchTakeDamage`（先入账 → 再 ShowWitchHP，同函数顺序保证），统一从 OnEntityCreated 挂载；删 Event_WitchSpawn 与 Witch_OnTakeDamage。加分门控 damage_enable、显示门控 hp_enable+hp_show_witch 互不影响。
- 女巫横幅修复（v1.7.58）玩家已验证"看到横幅了"。

## 关联

- [[l4d2-si-hud-scoring]] — 击杀分体系（Witch 固定 500）+ v1.7.60-63 连杀/音效档重构
- [[l4d2-bf-killfeedback]] — 音效链路闭环（v4.4.7 统一 si_kill.mp3）
- [[l4d2-bf-kill-hud]] — si_hud 主记忆
