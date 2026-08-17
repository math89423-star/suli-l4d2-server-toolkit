---
name: l4d2-respawn-gear
description: 复活套装 v1.5.1（2026-08-03 用户拍板）：复活币死亡复活自动发 M60+消防斧+止痛药+土质炸弹 + 满血100；si_hud v1.9.2 全局 forward SH_OnClientRespawned → shop 监听；闲置/接管引擎自管不处理
metadata: 
  node_type: memory
  type: project
  originSessionId: f3dda53e-a801-4112-9add-65c88345feb2
  modified: 2026-08-04T09:01:33.360Z
---

# 复活套装（l4d2_shop v1.5.1+ + l4d2_si_hud v1.9.2+）

**v1.12.0（2026-08-04）触发条件明确**：复活币已废除，自动复活 = 免费命（1次/图）或积分复活（6000）；**两种复活成功都发套装**（Timer_RespawnTeleport 统一发 forward，本就如此，v1.12.0 显式确认）。复活体系全貌见 [[l4d2-revive-system-v1120]]。

**用户拍板（2026-08-03）**："我们只管通过复活币的死亡复活。固定装备一把 m60、一把斧头、一个止痛药、一个土质炸弹，并且复活 100 满血。闲置就不管了，由引擎自行控制。"

## 架构（跨插件通信方向：si_hud → shop）

- **si_hud v1.9.2**：`CreateGlobalForward("SH_OnClientRespawned", ET_Ignore, Param_Cell)`，在 `Timer_RespawnTeleport`（复活 0.5s 后、`IsPlayerAlive` 已确认）末尾 `Call_StartForward` + `Call_PushCell(client)` 触发。所有自动复活路径（复活次数 + 复活币）都汇到 `Timer_Respawn`，故统一在此发放。
- **shop v1.5.1**：定义同名 `public void SH_OnClientRespawned(int client)` 即自动接收（SM 全局 forward 机制，无需注册）。校验 in-game + 幸存者队 + alive 后发装备 + 满血。
- 契约声明在 `include/l4d2_si_hud.inc`（`forward void SH_OnClientRespawned(int client);`）。

## 配置（cfg/sourcemod/l4d2_shop.cfg 自动生成）

| cvar | 默认值 | 说明 |
|---|---|---|
| `sm_shop_respawn_gear` | `weapon_rifle_m60,weapon_melee\|fireaxe,weapon_pain_pills,weapon_pipe_bomb` | 逗号分隔；近战用 `weapon_melee\|脚本名`；空 = 关闭 |
| `sm_shop_respawn_health` | `100` | 复活血量（0 = 引擎默认） |

## 实现要点

- **近战**：`CreateEntityByName("weapon_melee")` + `DispatchKeyValue(ent, "melee_script_name", "fireaxe")` **必须在 DispatchSpawn 前**（同 SpawnMelee 的 v1.7.77 铁律）+ `EquipPlayerWeapon` 上身。
- **非近战**：`GivePlayerItem(client, cls)` 后 `EquipPlayerWeapon` 补装备（幂等）。
- 日志标签 `[respawn-gear]`（含 FAILED 路径）。

## 坑

- **include/ 被裁剪无 forward.inc** → `DestroyForward` 未定义编译 error 017；不手动销毁，SM HandleSystem 在插件卸载时自动释放全局 forward 句柄（OnPluginEnd 已留注释说明）。
- **闲置/接管不处理**（用户拍板引擎自管）：`SH_OnClientRespawned` 只在复活流程触发，闲置回来接管 bot 不触发——商店买的装备被 bot 带走是引擎原生行为，已明确不修。

## ⚠️ bot 接管（2026-08-03 v1.9.5/v1.6.3，已编译未部署）

**根因**：本服引擎**不会自动复活幸存者 bot**；原 l4d2_auto_respawn（无条件复活含 bot，无 IsFakeClient 检查）2026-08-02 禁用后，si_hud 复活系统（v1.7.32d 的 `!IsFakeClient` 跳过 bot，注释"引擎有自己的重生逻辑"不成立）→ bot 死透。用户拍板：bot 与玩家一样由 si_hud 接管。

**改动**（fixer agent 完成）：
- `l4d2_si_hud.sp:2088` Branch C 删 `!IsFakeClient(victim)` → bot 走免费次数（每图 base 1）→ 币（bot 恒 0）→ 躺尸
- `l4d2_si_hud.sp:1247` reload 初始化循环 bot 也补 `g_iRevivesLeft`（原跳过 → reload 后场上 bot 死透）
- `l4d2_shop.sp:1041` SH_OnClientRespawned 加 `IsFakeClient` 守卫 → **bot 不发复活套装**（防接管白嫖 M60；用户改主意可去掉）
- L4D_RespawnPlayer 对 bot 有效（left4dhooks native，旧 auto_respawn 同款）；chat/hint 对 bot 无害空操作
- **✅ 2026-08-03 17:14 已部署**：sm plugins reload（si_hud 先 shop 后）+ 版本 cvar 手动校正（reload 残留旧值坑：si_hud_version 1.9.4→1.9.5、l4d2_shop_version 1.5.1→1.6.3）+ 日志 0 错误；RCON 命令用 `sm plugins reload`（`sm_reload` 别名无效返回 Unknown command）
- 空服验证（待）：杀 bot → 20s 复活 + [respawn-gear] 无 bot 条目 + 每图仅 1 次免费复活

## v1.9.6 复活清尸（2026-08-03 23:14 已部署）——大难题修复

**症状（用户报告）**：玩家复活后尸体（survivor_death_model）还躺原地；残留尸体可被电击器再次电击 → Defib_Fix 的 GetPlayerByCharacter 找到活人 → "活人从尸体上站起来"目标错乱。

**根因**：si_hud 复活走 `L4D_RespawnPlayer`（强制复活），引擎不清理死亡模型（只有电击器 defib 流程引擎才删）。尸体残留 → 电击器把它当有效目标。

**修复（双层）**：
- **Defib_Fix v2.0.2**：AskPluginLoad2 新增 `CreateNative("L4D2_KillSurvivorDeathModel", ...)`——按 `g_iDeathModelOwner[entity]`（已有的死亡模型→玩家映射，CSurvivorDeathModel::Create detour 记录）遍历删除目标玩家尸体，返回删除数。
- **si_hud v1.9.6**：`Timer_Respawn` 中 `L4D_RespawnPlayer(client)` 后调用该 native（`GetFeatureStatus(FeatureType_Native, ...)` 检查，Defib_Fix 未加载时静默跳过）。覆盖全部自动复活路径（免费次数+复活币）。

**验证**：两插件 reload 成功；`sm plugins info Defib_Fix` Version 2.0.2（myinfo 权威）；cvar 存在 = OnPluginStart 完整执行 = detour+native 全成功。cvar `defib_fix_version` 显示 `def. 2.0.1` 是 v2.0.1 旧实例 cvar 残留（**SM reload 不清 cvar，CreateConVar 复用保留旧值**——记忆 54 行已记载此坑，本次再次验证），当前值已 RCON 校正 2.0.2，无害。

## 状态

- ✅ 2026-08-03 16:01 热重载生效（先 si_hud 后 shop；reload 成功 + cvar 注册验证通过）。
- 版本号 cvar 坑：CreateConVar 对已存在 cvar 保留旧值（l4d2_shop_version 停在 1.4.2 / si_hud_version 停在 1.9.1），已 RCON 手动校正为 1.5.1/1.9.2。
- 待玩家实测：死亡复活后装备+满血（日志 [respawn-gear]）。
- 未 commit git（v1.0.2-v1.5.1 均未提交）。

相关：[[l4d2-shop-decoupled]]（商店解耦架构）[[l4d2-artillery-strike]]（火力支援）[[l4d2-dont-touch-server]]（静默规则）

## v1.11.0 主武器随机池（2026-08-17 用户拍板）

**原因**：M60/榴弹可补给弹药后全程持续作战，复活套装不再发 M60。
**改动**：`sm_shop_respawn_primary_pool`（新 cvar，8 把随机 1）：
2连喷（autoshotgun/spas）+ 4AR（rifle/sg552/ak47/desert）+ 2连狙（sniper_military/
hunting_rifle，用户指定）；`sm_shop_respawn_gear` 默认改为
`weapon_melee|fireaxe,weapon_pain_pills,weapon_pipe_bomb`（去掉 M60）。
⚠ 改代码默认值不会更新运行中的 cvar，需 RCON 同步（已做）。
