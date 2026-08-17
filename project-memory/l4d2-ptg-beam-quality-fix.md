---
name: l4d2-ptg-beam-quality-fix
description: PTG 假线/穿墙线修复（2026-08-01，commit 69d14c1）——REPAIR snap + 画线跳过 + snap 空间 A* + filter 修正
metadata: 
  node_type: memory
  type: project
  originSessionId: 3d1f1a4d-ccaa-483b-af60-c0ded45016f6
  modified: 2026-08-01T02:54:10.772Z
---

# PTG 假线/穿墙线修复（2026-08-01，commit 69d14c1）

## 症状（用户反馈："很多假线多段线"）

导航线在空中/穿透地板、断成多段。c1m1 基线数据：**24/53 线段（45%）过不了 hull 验证**。

## 根因链（按排查顺序）

1. **REPAIR 写回未 snap 坐标**：Strategy 1 Z 抬升 ±48~144、Strategy 3 线性插值中间点、Strategy 4 nav-area-center 绕行点——全不贴地 → 悬浮线/穿楼板线
2. **画线无视验证**：g_bBeamWalkable 只在 validate/detour 被读，**画线循环根本不看** → blocked 线段照画直线穿墙
3. **funnel Z 过渡吸错楼层**：插值点在楼板内，500u trace 吸到错误楼层地面（+16 偏移）→ 跨层线段穿楼板（profiled: dz≈226-240, navArea=null 端点）
4. **搜索空间 ≠ 画线空间（最深层）**：A* 用 nav-center 坐标搜索，画线用 snap 后坐标——所有 nav-center 级几何检查（Theta* LOS、geom penalty）全失效。迭代验证：snap 空间 A* 后路径变长（71 cells）但 blocked 不降
5. **filter 把可动实体当墙**：`TraceFilterWalkable` 阻挡 prop_physics（可推开）、func_breakable（可撞碎）、func_physbox——玩家能走的路径被判定 blocked（45% blocked 的真凶）
6. **垂直层间过渡误杀**：楼梯井/跳台段（dz>100, XY<120）hull 直线 trace 穿楼板 → Strategy 0 放行阈值原来 XY<40 太严

## 修复（7 处）

| # | 位置 | 修复 |
|---|------|------|
| 1 | validate.inc REPAIR 4 策略 | 写回前 `GroundSnapPosition`（trace down +2）+ 重测 traversable，不过则降级 beacon |
| 2 | guide.inc 画线主循环 | forward/backward 跳过 walkable==0 线段，断点 cell 处重新起线（beacon 柱子标记缺口） |
| 3 | astar.inc funnel | snap 约束在段落 Z 区间 [zMin-20, zMax+20]，+16→+2 |
| 4 | astar.inc A* 搜索 | `AStar_SnapCenter` 懒 snap（缓存，每 node 1 次 trace）；EdgeCostVisible + Theta* LOS 全用 snap 坐标；ASTAR_NODES_PER_FRAME 200→100 |
| 5 | validate→A* 迭代反馈 | blocked 线段 nav 边对入 `g_hBlockedEdges` → A* 惩罚 ×5 → 重建（GEOM_ITER_MAX=3），MapStarted/OnMapEnd 清表 |
| 6 | utils.inc filter | `TraceFilterWalkable` 放行 prop_physics/func_breakable/func_physbox（可推开/可撞碎）；新增 `TraceFilterWalkableStrict` 供 snap trace 用（AStar_CellFromNode/SnapCenter/GroundSnapPosition/funnel） |
| 7 | validate Strategy 0 | 垂直段放行 dz>100 && XY<120（原 XY<40） |

新 cvar：`l4d_path_to_goal_geom_penalty`（默认 1）。

## 效果（c1m1_hotel 实测）

- blocked：24/53 (45%) → 22/63 (35%)
- 无悬浮线、无穿墙假线；断点有 beacon 柱子
- 剩余 blocked = 真墙穿墙（唯一 nav 路径，无替代几何，PTG 层级救不了）

## 教训

- **A* 搜索空间必须等于画线空间**——任何 nav-center 级几何检查（LOS/惩罚）都基于错误坐标，全无效
- **验证标准必须等于玩家能力**——L4D2 玩家能推/能撞碎的东西不是墙
- 迭代反馈（validate→禁边→重算）是对的，但地图 nav 图若只有单一路径，绕不开
- SourcePawn 单遍编译：stock 函数必须在使用前定义；if 嵌套块内不能 `break`

## 遗留

- 多跳绕行（Repair_TryLocalReroute）在 c1m1 上 fixed=0（无替代路径）——在大图上可能有用
- 35% blocked 若想再降：hull 尺寸/策略级调整，或地图 nav 重做

Related: [[l4d2-ptg-fallback-loop-fix]] [[l4d2-ptg-v46-deployed]]
