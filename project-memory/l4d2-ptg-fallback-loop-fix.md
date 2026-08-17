---
name: l4d2-ptg-fallback-loop-fix
description: PTG fallback 死循环 + SMOOTH Invalid Handle 崩溃修复（2026-08-01，commit e2f5155）
metadata: 
  node_type: memory
  type: project
  originSessionId: 3d1f1a4d-ccaa-483b-af60-c0ded45016f6
  modified: 2026-08-01T02:16:09.942Z
---

# PTG fallback 死循环 + SMOOTH 崩溃修复（2026-08-01）

## 症状（errors_20260801.log / L20260801.log）

1. **Invalid Handle 0 (error 4)** at `ptg_pipeline.inc:551`（`g_GuideCells.Length`），每 ~12s 一次，一天 274+ 次（昨日 errors 75MB）
2. **"A* node index is empty"** 每 2s 重试，729 次/天；"Entering 60s backoff" 打印后 2s 又重试 —— 退避形同虚设

## 根因（两个独立 bug）

**Bug A — g_iSmoothStep 泄漏（崩溃根因）：**
- `g_iSmoothStep`（SMOOTH 子状态机 0-4）只在 case 4 **成功**分支重置
- fallback 路径直接跳 `STAGE_ASTAR`（跳过 STAGE_PREP），`Guide_Prep_Fallback` 不重置子状态机
- 上一次构建 `<2 cells` 中止时 `g_GuideCells` 被 delete 且 smoothStep 留在 4 → 下次 fallback 进入 SMOOTH case 4 → 对 null 取 `.Length` → 异常 → RequestFrame 链死 → watchdog 10s 重置 → fallback 重试 → 循环
- 成功构建会把 smoothStep 归 0 → 自愈（01:46 "Pipeline done: 54 cells" 后恢复正常）

**Bug B — 60s 退避不生效：**
- Timer_AutoCheck 里退避门在 `stage < 2` 块；retry 块匹配 `stage >= 2`（含 stage=3 退避态），且进退避时 `g_iFallbackRetries` 已清零 → `0 < 2` → 立即重试

**上下文：** tumtara 无 nav mesh（[[l4d2-tumtara-pitfalls]] 坑 #3）→ 节点索引必然建不出 → 若无 Bug B 就是安静的 60s 周期（2 标准 prep + 2 fallback + 60s 退避），有 Bug B 就是 24/7 刷屏

## 修复（commit e2f5155，4 处）

1. `Guide_Prep()`（ptg_pipeline.inc）：入口重置 `g_iBuildPhase/g_iPortalBatchIdx/g_iPostStep/g_iIGStage/g_iSmoothStep`（watchdog 重置后这些会残留）
2. `Guide_Prep_Fallback()`（l4d_path_to_goal.sp）：入口重置 `g_iSmoothStep/g_iPostStep/g_iIGStage`（fallback 跳过 STAGE_PREP，不吃修复 1）
3. SMOOTH case 4：null 守卫（→ smoothStep=0 重建）+ `<2 cells` 中止分支也重置 smoothStep
4. Timer_AutoCheck retry 块：补退避检查（stage>=3 时 `GetEngineTime() < g_fFallbackBackoffUntil` 直接 return）

## 验证（2026-08-01）

- tumtara：退避周期 10:13:49 → 10:14:47（~58s 静默）✓；errors 计数部署后 0 新增 ✓
- c1m1_hotel：标准构建 "Pipeline done: 54 cells" + REPAIR fixed=16 与基线一致，无回归 ✓
- 部署方式：`sm plugins reload l4d_path_to_goal`（0 玩家，铁律 #8 不重建容器）

## 踩坑教训

- **子状态机（g_iBuildPhase/g_iPostStep/g_iIGStage/g_iSmoothStep）必须在每个管线入口重置**——"被跳入"的路径（fallback 跳过 STAGE_PREP）是泄漏载体
- **SourcePawn 1.12 禁止 if 嵌套块里的 `break`**（error 024 "break out of context"）——switch case 内想提前退出须用 if/else 结构
- 看门狗（Timer_AutoCheck）重置管线时不调 Guide_Cleanup，只清 guide_prep/stage 两个字段——所以 Guide_Prep 入口重置是唯一兜底

Related: [[l4d2-ptg-v46-deployed]] [[l4d2-ptg-mapchange-crash]] [[l4d2-tumtara-pitfalls]]
