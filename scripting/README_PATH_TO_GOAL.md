# l4d_path_to_goal — A* 逃生路径导航插件

> 版本: 1.55 | 作者: gvazdas, zyiks | A* 引擎: 2026-07-25

## 概述

为 Survivor 队伍实时绘制通往终局逃生点的激光引导线。基于 Source 引擎 Nav Mesh 的 **A\* 图搜索**，自动检测跳跃点、翻越点、蹲行通道、间隙跳跃等玩家可行但 Nav Mesh 未标记的连接。

`!ptg` / `!guide` / `!wheretogo` — 双击切换引导线开关。

---

## 架构

### 管线（6 阶段）

```
STAGE_PREP     构建节点索引 → 识别起点/终点 → 初始化空间哈希
     ↓
STAGE_ASTAR    A* 搜索（分布到多帧，每帧 ≤48 节点）
     ↓
STAGE_SMOOTH   重建路径 → Theta* 视距平滑 → 漏斗去冗余
     ↓
STAGE_JOIN     连接救援载具路径（终局）
     ↓
STAGE_VALIDATE 8 策略 Hull Trace 验证（剔除穿墙线）
     ↓
STAGE_END      引导就绪 → 渲染激光束
```

### 帧预算

所有阶段共享 `l4d_path_to_goal_budget`（默认 0.5ms/帧）。每帧处理完预算后通过 `RequestFrame` 延续，绝不阻塞主线程。

### A* 搜索

```
节点 = Nav Area（可通行区域）
边   = Adjacent（方向连接）
      + Ladder（梯子）
      + Elevator（电梯）
      + 非网格连接（自动检测，见下）

代价 g(n) = 欧几里得距离 × 类型系数
启发式 h(n) = 到目标 Nav Area 的 3D 欧几里得距离（可接纳、一致）

类型系数：
  ADJACENT   1.0    平地行走
  LADDER     1.5    爬梯
  ELEVATOR   2.0    乘电梯
  JUMP_UP    1.8    跳上高台
  JUMP_DOWN  1.2    安全跳下
  VAULT      2.5    翻越齐腰障碍
  GAP_JUMP   3.0    跑跳跨间隙
  CROUCH     1.5    蹲行通道
  STEP_DOWN  1.1    逐级跳下
  BREAKABLE  5.0    可破坏障碍
  CONDITIONAL 10.0  机关/触发门
```

### Theta* 平滑

在 A* 展开邻居时，检查当前节点的父节点能否**直接看到**邻居（有 LOS）。如果能，跳过当前节点——路径更直、航点更少。

### 非网格连接自动检测

地图加载时一次性完成（分布到多帧）。对每对空间上接近但 Nav Mesh 无连接的 Nav Area：

| 类型 | 检测条件 | 验证方法 |
|------|---------|---------|
| JUMP_UP | dz: 32-72, xy<100 | 抛物线跳跃 Hull Trace (apex 64hu) |
| JUMP_DOWN | dz: 64-250, xy<150 | 垂直下降 Trace + 落地地面检测 |
| VAULT | \|dz\|: 40-100, xy<72 | 高平面水平 Trace + 两侧垂直 Trace |
| GAP_JUMP | \|dz\|<40, xy: 80-280 | 中点无地面 + 跳跃弧 Hull Trace |
| CROUCH | dz<40, xy<256 | 低 Hull (36h) 通过而标准 Hull (72h) 不通过 |
| STEP_DOWN | dz: -72~-32, xy<80 | 逐级垂直下降 Trace |
| BREAKABLE | NAV_BASE_BREAKABLEWALL 属性 | 接受 blocked area 为高代价连接 |

---

## 关键数据结构

### Cell（导引点）
```cpp
enum struct Cell {
    float flow;         // 流距离（已废弃，保留兼容）
    Address navArea;    // 所属 Nav Area 地址
    float center[3];    // 世界坐标（高于地面 16hu）
}
```

### 二叉堆（A* 优先队列）
```cpp
enum struct HeapEntry {
    int nodeIndex;    // g_hAStarNodes 中的索引
    float fScore;      // g + h
    float gScore;      // 实际路径代价（用于惰性删除检测）
}
```

### 节点索引（并行数组，O(1) 查找）
```
g_hAStarNodes[N]      // int: Nav Area 地址
g_hAStarCenters[N][3]  // float: 中心坐标（高于地面 16hu）
g_hAStarAreaToIndex    // StringMap: "地址" → 索引
```

### 空间哈希
```
g_hSpatialHash         // StringMap: "cx_cy_cz" → ArrayList{area, center}
单元大小: 256 units
查询: 检查 3×3×3 邻居单元（±1 per axis）
```

---

## 配置 Cvar

| Cvar | 默认值 | 说明 |
|------|--------|------|
| `l4d_path_to_goal_enable` | 1 | 总开关 |
| `l4d_path_to_goal_max` | 32 | 最大激光束数 |
| `l4d_path_to_goal_survivor` | 1 | 允许生还者使用 |
| `l4d_path_to_goal_infected` | 1 | 允许特感使用 |
| `l4d_path_to_goal_spec` | 1 | 允许观战使用 |
| `l4d_path_to_goal_alive` | 0 | 0=全部, 1=仅存活, 2=仅死亡 |
| `l4d_path_to_goal_budget` | 0.5 | 每帧 CPU 预算 (ms)，0=无限 |
| `l4d_path_to_goal_detour_budget` | 10.0 | detour_join 预算 (ms) |
| `l4d_path_to_goal_finale` | 1 | 终局连接: 0=总是, 1=终局开始后, 2=载具到达后, 3=永不 |
| `l4d_path_to_goal_finale_auto` | 0 | 终局载具到达后自动显示路线 |
| `l4d_path_to_goal_auto` | 0 | 自动脉冲引导模式 |
| `l4d_path_to_goal_auto_duration` | 1.0 | 引导线持续时间 (s) |
| `l4d_path_to_goal_auto_interval` | 25.0 | 自动脉冲间隔 (s) |
| `l4d_path_to_goal_gap_dz_max` | 200.0 | 最大垂直间隙（超过则抑制） |
| `l4d_path_to_goal_gap_xy_ratio` | 2.0 | XY/Z 抑制比例 |
| `l4d_path_to_goal_gap_vertical` | 1 | 绘制垂直桥接线 |
| `l4d_path_to_goal_beam_min_dist` | 32.0 | 最小光束间距 |
| `l4d_path_to_goal_stitch_steps` | 75 | 路径缝合最大步数（旧管线） |
| `l4d_path_to_goal_trace_hull` | 1 | 启用 Hull Trace 验证（剔除穿墙线） |

---

## 管理命令

| 命令 | 权限 | 说明 |
|------|------|------|
| `l4d_path_to_goal_recalculate` | ROOT | 强制重新计算引导路径 |
| `l4d_path_to_goal_print` | ROOT | 打印当前 g_GuideCells 列表 |
| `l4d_path_to_goal_recomputeflow` | ROOT | 强制触发 TerrorNavMesh::RecomputeFlowDistances |
| `l4d_path_to_goal_rescue` | ROOT | 强制呼叫救援载具（L4D2） |
| `l4d_path_to_goal_ground` | ROOT | 检测当前位置是否在地面附近 |

---

## 修改指南

### 调整 A* 代价系数

修改 `GetConnectionCost()` 函数（`l4d_path_to_goal.inc` 中）：
```cpp
case CONNECTED_LADDER: return 1.5;  // 改为 1.2 会让 A* 更愿意走梯子
```

### 调整非网格连接检测参数

修改 `DetectNonMeshConnections_Frame()` 中的检测条件：
```cpp
// JUMP_UP 原条件: dz ∈ [32, 72], xy < 100
// 修改 dz 范围或 xy 阈值来控制检测灵敏度
if (!noJumpArea && !otherNoJump && dz >= 32.0 && dz <= 72.0 && xyDist < 100.0)
```

### 添加新的连接类型

1. 在 `ConnectionType` 枚举中添加新值
2. 在 `GetConnectionCost()` 中添加代价
3. 在 `DetectNonMeshConnections_Frame()` 中添加检测规则
4. 在 `GetNonMeshConnections()` 中处理方向性

### 修改帧处理速率

调整 `ASTAR_NODES_PER_FRAME` 常量（默认 48）。值越大路径计算越快，但单帧 CPU 消耗越高。

### 添加手动配置的路径点

可以扩展 `configs/ptg_goals.cfg`（尚未实现）来允许管理员手动指定目标 Nav Area ID，覆盖自动检测。

### 调试

启用 DEBUG 模式（`l4d_path_to_goal.inc` 顶部 `#define DEBUG 1`）：
- 级别 1: 基础日志（帧耗时、cell 数量）
- 级别 2: 详细日志（每个阶段的详细信息）
- 级别 3: 极端日志（每个连接、每次 trace）

编译后查看服务器日志：`grep "\[PTG\]" logs/L4D2_*.log`

---

## 文件清单

| 文件 | 说明 |
|------|------|
| `scripting/l4d_path_to_goal.sp` | 插件入口：命令注册、自动引导、备用管线 |
| `scripting/include/l4d_path_to_goal.inc` | **核心引擎**：管线、A*、空间哈希、非网格检测、渲染 |
| `scripting/include/gvazdas_navmesh_utils.inc` | Nav Mesh 工具函数（投影、裁剪、随机落点） |
| `gamedata/l4d_path_to_goal.txt` | SDK 签名：TerrorNavMesh::RecomputeFlowDistances |
| `translations/l4d_path_to_goal.phrases.txt` | 多语言翻译 |

---

## 依赖

- **left4dhooks** (≥ 最新版): `L4D_GetAllNavAreas`, `L4D_NavArea_GetAdjacentAreas`, `L4D_NavArea_IsConnected`, `L4D_NavArea_GetLadder`, `L4D_NavArea_GetElevator`, `L4D_GetNavArea_AttributeFlags`, `L4D_GetNavArea_SpawnAttributes`, `L4D2Direct_GetTerrorNavAreaFlow`, `L4D2Direct_GetMapMaxFlowDistance`
- **dhooks**: `TerrorNavMesh::RecomputeFlowDistances` 动态钩子
- **sdktools**: `TR_TraceRayFilter`, `TR_TraceHullFilter`, `TE_SetupBeamPoints`
