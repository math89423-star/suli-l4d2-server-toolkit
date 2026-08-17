---
name: l4d2-ptg-detour-rebuild-loop-fix
description: "PTG v4.6.1: c2m3 过山车机关开启后卡顿 = detour 链与 rebuild 竞态 + 0.5ms 预算饿死 + 无退避循环（F1-F5）"
metadata: 
  node_type: memory
  type: project
  originSessionId: e735d80f-6fa8-4177-bfac-d049effae7b1
  modified: 2026-08-01T15:13:11.337Z
---

# PTG c2m3 过山车卡顿修复（2026-08-01，commit 03a0971，v4.6.1）

## 症状

c2m3（过山车）开启机关后游戏"非常卡顿然后恢复"。日志实证：22:21:30→22:22:14→22:23:54 三轮 detour 链，每轮 40-100s，中间穿插 5951 areas 全量 rebuild（A* 3s）。

## 根因（5 个，按深挖顺序）

1. **F1 竞态**：`Guide_Prep`（dirty rebuild）不取消进行中的 detour 链 → detour 窗口索引指向被替换的 `g_GuideCells` → splice 边界 LOS 必败 → 84s 三次失败后**又触发第二次全量 rebuild**。日志铁证：22:21:35 "Pipeline done" 与 "Detour: splice boundary check failed" 同秒。
2. **F2 预算饿死**：detour 三阶段（BFS/local A*/convert）用 `frame_budget_exceeded()` = 管线 0.5ms 预算（`l4d_path_to_goal_budget` 默认 0.5）→ 每帧只跑 1-5 节点 → 一轮 detour 40-100s。`g_hCvarDetourBudget`（10ms）只用于 `detour_join`，detour 链根本没用它。
3. **F3 失败链浪费**：`Detour_Fail` 做 ±12→±24→±48 三轮，c2m3 cell 91-95 区域（过山车轨道）整片 blocked，窗口内必败，三轮纯浪费。
4. **F4 无退避**：轨道车（mover）持续 blocked → PathIntegrityCheck 每 6s 触发 detour→rebuild 循环（22:21:30→22:22:14→22:23:54 三次重建才收敛）。
5. **F5 事件风暴**：evtNavBlocked 对 mover 连续触发（22:21:30 同秒 cell 91/92/93 三条），每个都排队 detour。

## 修复（commit 03a0971）

- **F1**: `Guide_Prep` 开头 `if (g_bDetourActive) { Detour_ClearLocalState(); 清 active/busy/stage/queued }` + LogMessage
- **F2**: 新增 `DETOUR_BUDGET_MS 2.0`（ptg_types.inc）+ `detour_frame_budget_exceeded()`（ptg_validate.inc，**始终有界**防 SIGALRM）；ptg_detour.inc 三处替换
- **F3**: `Detour_Fail` 删掉 widening 重试，一次失败直接 `NavChanged(true)`
- **F4**: `g_fLastBuildDoneTime` 在 Pipeline done 记录；`Guide_TryLocalDetour` 入口 60s 退避（覆盖 PathIntegrityCheck + evtNavBlocked 两路）
- **F5**: evtNavBlocked 3s 去抖（static float）

## 验证

- 编译 270792 bytes，reload 后 `sm plugins info` Version 4.6.1 确认
- reload 后 135 cells 构建正常（c2m3 两次 iteration 是 REPAIR 正常机制）
- **5 分钟零 detour/dirty/rebuild 日志**（修复前同场景每 40-100s 一轮）

## 遗留（P1 未做）

- errors 日志今日 143MB 可清。

## 追加修复（同日晚，commit 3f9c422）：c2m4 穿屋顶线

玩家报 c2m4 线"指向屋顶/无法逾越"（navArea=0 悬空 cell + dz≈190 竖直穿楼 beam）：
- **F6**: Funnel3D 插值点 snap 失败（trace 未命中或命中他层）→ **跳过不插入**（原来保留悬空插值 Z）
- **F7**: validation 对 dz>140 的 beam 直接 blocked（DZ_TOO_LOW 掉血阈值），nav LADDER/elevator 连接豁免（navArea_has_climb）
- 验证：c2m5（6520 areas）99/121 walkable、**零 dz>140 beam**、A* 1s（HPA 分帧生效）

**HPA 分帧化验证成功**（c2m5 6520 > 5000 旧阈值，现在聚类启发式跑，A* 3s→1s）。

Related: [[l4d2-ptg-dorstate-crash-fix]] [[l4d2-ptg-fallback-loop-fix]] [[l4d2-ptg-v46-deployed]] [[l4d2-ptg-beam-quality-fix]]
