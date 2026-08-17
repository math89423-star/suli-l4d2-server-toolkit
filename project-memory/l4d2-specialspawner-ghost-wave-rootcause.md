---
name: l4d2-specialspawner-ghost-wave-rootcause
description: v2.0.0 幽灵波根因（句柄双重释放链）→ v2.0.1 四处修复 + v2.0.2 批次守卫，全部与错误日志逐条对应
metadata: 
  node_type: memory
  type: project
  originSessionId: 38fc3311-e549-4c1b-8496-6305d254d598
  modified: 2026-08-05T02:05:36.048Z
---

# L4D2 幽灵波根因（"第二波来袭不播报"）已实锤闭环

2026-08-05 排障结论：v2.0.0 的 bug 链（错误日志 errors_20260805.log 实锤）：

1. **tmrClearCheck 回调内 `delete` 自己的 REPEAT 句柄** → 每次进入冷静期的瞬间双重释放
   （`Invalid timer handle during timer end` error 23，01:07:05 分毫不差）→ 句柄表污染
2. 污染 → **冷静期第 12s 幽灵波 timer 提前触发**（01:07:17 刷 6 只，冷静期契约被打破）
3. 幽灵波刷出走 SCM v2.0.0 的 **PickClass fallback 分支——该分支静默吞掉播报** → 玩家实测"第二波来袭不播报"
4. 双重释放**每波 REST 转换必发** → 幽灵波每波都有 → "一直不播报"是系统性症状
5. 后续 `EnterClearing`/`ResetLifecycle` 裸 delete 抛 `Handle is invalid` → **状态机中断**
   （phase 日志停在 01:07:23 的根因，波次循环进入失控态）

**v2.0.1 四处修复（全部命中错误日志）**：
- tmrSpawnSpecial REST 守卫（`[SS] 防御: REST 期间忽略幽灵波 timer`）
- KillClearTimer 防御删除（IsValidHandle，EnterClearing/tmrRetrySpawn 用）
- tmrClearCheck 回调只置 null + Plugin_Stop，不自删
- ResetLifecycle IsValidHandle 守卫；SCM DetectAndAnnounceWave 提前到 PickClass 之前

**v2.0.2（2026-08-05 10:05 已 reload）**：tmrBatchContinue 相位守卫——非 PRESSURE 忽略
+ 记录（sPhaseNames 数组），g_hBatchQueue 空守卫。堵死最后一个无守卫刷怪入口。

**排障方法论**：错误日志是权威（error 23 + 栈回溯行号 → 逐条对应修复点）；
主日志 phase 行停摆 = 状态机中断信号；长 RCON 响应（sm plugins list 78 插件）会截断，
用 `sm plugins info <名>` 确认加载状态。

部署状态：v2.0.2 已 reload（Timestamp 10:05:12），0 真人玩家未压力实测——等玩家进服
验证：冷静期无幽灵波 + 每波 [SI波次] 播报 + phase 日志持续流转。
相关：[[l4d2-specialspawner-config]] [[l4d2-si-composition-timing-pitfall]]
