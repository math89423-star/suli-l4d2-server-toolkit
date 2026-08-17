---
name: l4d2-ptg-funnel-bug
description: PTG ReconstructPath funnel string-pulling SIGALRM — 根因已定位为 SourcePawn VM 压力模式，非算法逻辑 bug
metadata: 
  node_type: memory
  type: project
  tags: 
    - l4d2
    - ptg
    - bug
    - sigalrm
    - funnel
    - fixed
  modified: 2026-07-26T05:39:24.731Z
  status: fixed
  originSessionId: cd7edea0-8c56-4bbb-ba74-cc609629eaf6
---

# PTG Funnel String-Pulling SIGALRM Bug

## 根因

**算法逻辑没有 bug。** SSFA 是严格 O(n) bounded loop。真正原因是 SourcePawn JIT 无法正确处理多个 `float[3]` 局部数组在嵌套作用域中声明 + `const float[3]` 函数参数传递的组合。

具体触发的压力模式：
1. `float tmp[3]` 在两个不同 `if` 块中声明 —— SP 编译器 hoist 到函数作用域后 JIT 产生错误代码
2. `TriArea2D(const float a[3], const float b[3], const float p[3])` 在 tight loop 中被反复调用，const 数组引用传递对 VM 造成压力
3. `float[3]` 对拷赋值（`tmp = portalLeft`）与 `GetArray` 交替使用可能触发栈内存踩踏

## 修复方案（2026-07-26 applied）

**保留完整 SSFA 算法**，消除所有 SP VM 压力模式：

1. **TriArea2D 内联** —— 用标量叉积替代 const float[3] 函数调用
2. **float[3] 缓冲区提前声明** —— 在函数作用域声明 `pl[3], pr[3], le[3], re[3], swp[3]`，loop 体内零声明
3. **数组 swap 改为逐元素赋值** —— 不用 `tmp = portalLeft`，用 `swp[0]=pl[0]; pl[0]=pr[0]; pr[0]=swp[0]` 逐分量
4. **加入安全迭代计数器** —— `funnelIter < portalCount + 16` 防止意外
5. **加入 portalEps 索引越界检查** —— `if (plIdx < 0 || prIdx >= portalEps.Length) break`

## 附带修复

`evtFirstSpawn` 的 `EventHookMode_PostNoCopy` → `EventHookMode_Post`，修复 `Invalid game event handle 0` 错误。

## 验证结果

- c1m1_hotel 地图 1252 nav areas → 15 portals → 16 guide cells
- A* path found → smoothing → Hull validation: 11/15 walkable
- **无 SIGALRM 崩溃**
- **无 event handle 错误**

## 修改的文件

- `/home/ubuntu/l4d2-server/sourcemod/scripting/include/l4d_path_to_goal.inc` — `AStar_ReconstructPath()` 的 funnel loop 重构
- `/home/ubuntu/l4d2-server/sourcemod/scripting/l4d_path_to_goal.sp` — `evtFirstSpawn` hook mode 修复

**Why:** Funnel string-pulling 是正确的路径优化算法，删除它会导致路径不平滑。根因在 SourcePawn VM 层面，重构后既保留了算法又避免了 VM bug。
**How to apply:** 已在 c1m1_hotel 测试通过。如果未来其他地图仍出现 SIGALRM，优先检查是否有新的 `float[3]` 局部数组声明被引入到 funnel loop 中。

Related: [[l4d2-ptg-timer-bug]]
