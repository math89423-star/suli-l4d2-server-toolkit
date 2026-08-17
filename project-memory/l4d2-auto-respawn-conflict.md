---
name: l4d2-auto-respawn-conflict
description: 复活币失效根因 — l4d2_auto_respawn 未卸载，player_death 后无条件复活绕过 si_hud 限次（2026-08-02 已修复）
metadata: 
  node_type: memory
  type: project
  originSessionId: 33147fa7-db39-4682-94eb-5431058b1de5
  modified: 2026-08-02T15:42:53.981Z
---

# L4D2 复活币失效根因（已修复 2026-08-02）

## 现象
用户反馈复活币没起作用，死亡后仍无限制复活。

## 根因
`l4d2_auto_respawn.smx` v2.2 **仍在加载运行**（smx 还留在 plugins/ 目录，2026-07-22 部署），而 si_hud v1.7.28+ 已把复活限次功能并入（changelog 写明"该插件已卸载"但**卸载步骤漏执行**）。

- l4d2_auto_respawn：hook `player_death` → `sm_respawn_delay`(35s) 后**无条件** `L4D_RespawnPlayer`——无限制、无硬币判断、无总开关
- si_hud：`si_hud_respawn_enable 1` / `base 2` / `delay 15` / `coin_start 2` / `coin_max 5`，次数用完→扣复活币→都没有→躺尸——逻辑本身正确

双插件并存时：si_hud 正确让玩家躺尸后，auto_respawn 的 35s 计时器仍把他拉起来 → 看起来就是无限复活。

## 修复
1. `mv plugins/l4d2_auto_respawn.smx plugins/disabled/l4d2_auto_respawn.smx.disabled`
2. 更新 PLUGINS.md 标注禁用
3. `docker restart l4d2-server`（smx 移除需重启生效）
4. 重启后**必须手动注入** `nb_update_frequency 0.033`（l4d2-start.sh 的注入只在 compose up 流程执行，docker restart 不触发——见 [[l4d2-tickrate-setup]]）
5. 验证：`sm plugins list` 无 auto_respawn；`sm_respawn_delay` 报 Unknown command（确认其属主已卸载）；`si_hud_respawn_*` 全部在位

## 教训
- si_hud changelog 声称"已卸载"的插件要核对 plugins/ 目录实际文件 + `sm plugins list` 实时加载态，不能只看源码注释
- 复活类玩法（限次/复活币）与任何无条件自动复活插件互斥，部署前 grep 所有 `L4D_RespawnPlayer` 调用点

## 关联
- [[l4d2-si-hud-scoring]] — si_hud 计分体系
- [[l4d2-server-quick-reference]] — 复活时间配置（已更新为 si_hud_respawn_delay）
