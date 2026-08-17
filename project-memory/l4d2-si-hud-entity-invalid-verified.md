---
name: l4d2-si-hud-entity-invalid-verified
description: si_hud Event_InfectedDeath "Entity -1 is invalid" 报错验证——新版 v1.13.3 守卫已覆盖，已确认修复无需改码
metadata:
  node_type: memory
  type: fix
  modified: 2026-08-16T01:50:00.000Z
---

**现象**（`errors_20260816.log` 00:08:55，仅 1 次）：`l4d2_si_hud.smx` 在 `Event_InfectedDeath` 报 `Entity -1 (228) is invalid`，栈：GetEntPropString ← entity.inc:768 GetEntityClassname ← .sp:2385。

**根因**：00:08 运行的旧版 `Event_InfectedDeath` 里 `g_iLastCommonEnt` / `entityid` 拿到 -1 无守卫直接 `GetEntityClassname`。错误栈行号 2385 与当前 .sp 所有 GetEntityClassname 调用点（2325/2468/2504/3424）均不符 → 实锤是旧版本代码。

**验证结论（2026-08-16 上午）**：**已修复，无需改码**。
- 当前 v1.13.3（01:01 编译 / 01:04 部署 / 09:48 已 reload 确认运行态）四处调用全部有守卫：
  - `Event_InfectedDeath` witchEnt（line 2468）：`witchEnt >= 1 && witchEnt < 2048`
  - `Event_InfectedDeath` ent（line 2504）：`ent >= 1 && ent < 2048`
  - `Event_InfectedHurt` entId（line 2325）：`entId >= 1 && entId < 2048`
  - `IsWitchEntity`（line 3424）：`entity <= 0 || !IsValidEntity(entity)` 双保险
- 00:08 之后 errors 日志再未出现该错误（截至 09:46 仅有 block_bot_kick 已知噪音，见 [[l4d2-block-bot-kick-translation-noise]]）
- 09:48 `sm plugins reload l4d2_si_hud` 成功（`[SM] Plugin [L4D2] SI HUD reloaded successfully.`，precache 日志正常），运行态确认 v1.13.3

**加固（2026-08-16 用户拍板"去做吧"，已完成部署）**：`Event_InfectedDeath` 两处范围守卫（witchEnt line 2465 / ent line 2498）追加 `&& IsValidEntity(...)`，防"索引在 [1,2048) 内但实体已删除"的边界。改动后 spcomp64 编译 0 错误（Code 85544B），09:56 cp 到 plugins/ + `sm plugins reload l4d2_si_hud` 成功（`reloaded successfully`，errors 日志无新增），运行态 Hash ed5e4260→**9b7d0181**，版本号保持 v1.13.3 未 bump。旧 smx 备份 `plugins/l4d2_si_hud.smx.bak-v1.13.3-pre-isedit`，源码编辑前备份 `/tmp/l4d2_si_hud.sp.v1.13.3-before-isedit`。