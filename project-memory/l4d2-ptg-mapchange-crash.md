---
name: l4d2-ptg-mapchange-crash
description: PTG 崩溃根因：Phase 3 + post-build init 同帧执行超 CPU 预算 → SIGALRM（已修复 2026-07-26）
metadata: 
  node_type: memory
  type: project
  tags: 
    - l4d2
    - ptg
    - crash
    - bug
    - fixed
  modified: 2026-07-26T12:29:31.562Z
  status: fixed
  originSessionId: 1318302d-333d-4f0f-b190-03d741249a49
---

# PTG 崩溃根因与修复（第二轮 — 治根）

## 根因（真正的）

`OnFramePrep` 的 `STAGE_PREP` 批处理管线中，Phase 3（`DetectNavMeshBridges`）运行完后**没有设置 `budget_spent = true`**，导致 post-build init 在同一帧内紧接着执行。

**同一帧内执行的操作**：
1. `DetectNavMeshBridges()` — BFS flood-fill（O(N²) ArrayList.Erase(0)） + 空间哈希查询 + 跳跃/掉落/间隙检测（射线追踪）
2. Post-build init：
   - 遍历全部 nav area 找救援车辆（`L4D2Direct_GetTerrorNavAreaFlow` + `L4D_GetNavArea_SpawnAttributes` × N）
   - `AStar_IdentifyStart()` — 遍历全部 nav area（× N）
   - `AStar_IdentifyGoal()` — 遍历全部 nav area（× N）
   - `AStar_Init()` — 创建 4 个 ArrayList 各 N 个元素 + 填充
   - `AStar_SetStart()` — 堆 push + AStar_Heuristic
   - `DetectNonMeshConnections_Init()`

两项合计远超 Source 引擎帧预算（~33ms @ 30fps）→ **SIGALRM 崩溃**。

## 之前的"修复"为什么没治根

1. `f9c3c44` 把 `AStar_BuildNodeIndex` 分帧了 — 但这只是 Phase 0，Phase 3 + post-build 还是同帧
2. `f07705b` 加了 `g_iBuildPhase` 和 `budget_spent` 守卫 — 但 Phase 3 故意不设 `budget_spent`（注释："we want post-build to run next"），这是个**故意的优化**但误判了 CPU 开销
3. Funnel 代码被禁用（替换为直接路径转换）— funnel 不是根因，只是另一个压力源

## 真正修复（2026-07-26）

```sourcepawn
// Phase 3 修复：DetectNavMeshBridges 完成后设 budget_spent=true
// 跳过 Phase 4，直设 g_iBuildPhase=-1，post-build 在下一帧独立运行
if (!budget_spent && g_iBuildPhase == 3)
{
    if (g_hCvarNonMesh != null && g_hCvarNonMesh.BoolValue)
        DetectNavMeshBridges();
    g_iBuildPhase = -1;        // 直跳 post-build sentinel
    budget_spent = true;       // ← 关键修复：defer post-build 到下一帧
}
```

删掉了原来的 Phase 4（g_iBuildPhase=4 → -1 的中间步骤），Phase 3 直设 -1。

## 验证

- c1m1_hotel（1252 nav areas）: Pipeline 完成，16 guide cells，**零崩溃**
- 容器运行稳定，RestartCount=0

## 修改的文件

- `/home/ubuntu/l4d2-server/sourcemod/scripting/include/l4d_path_to_goal.inc` — Phase 3 加 budget_spent
- Commit: `14a872d fix(ptg): split Phase 3 from post-build init across frames`

## 关联

- [[l4d2-ptg-funnel-bug]] — funnel string-pulling（不是根因，单独修了）
- [[l4d2-ptg-timer-bug]] — TIMER_REPEAT 空服不触发（已另修复）
- [[l4d2-deployment-rules]] — 部署规则

**Why:** Phase 3 的 BFS + 桥检测与 post-build init 的全量遍历 nav area 在同一帧内叠加，CPU 超预算触发 SIGALRM。之前的"修复"都在框架层面修补但没有改变 Phase 3 和 post-build 同帧的事实。

**How to apply:** 如果未来再出现崩溃，检查 `OnFramePrep` 中是否有任何 phase 的 `budget_spent` 漏设导致与后续重操作同帧。优先用 `LogMessage` 在每帧开始时打印 phase 号来定位。
