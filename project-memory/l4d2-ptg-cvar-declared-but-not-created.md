---
name: l4d2-ptg-cvar-declared-but-not-created
description: PTG v4.0 ConVar 声明了但从未 CreateConVar → 所有高级功能永久禁用
metadata: 
  node_type: memory
  type: project
  tags: 
    - l4d2
    - ptg
    - bug
    - convar
    - fixed
  originSessionId: 9e5d22b4-186e-40be-9764-f729a9121cb7
  modified: 2026-07-27T09:18:22.808Z
---

# PTG v4.0 高级功能全部未启用

## 根因

在 `ptg_types.inc` 中声明了 11 个 v4.0 ConVar 变量：

```cpp
ConVar g_hCvarFunnel3D, g_hCvarFunnelZStep;
ConVar g_hCvarRepairEnable, g_hCvarRepairAttempts;
ConVar g_hCvarBeaconEnable;
ConVar g_hCvarThetaStar, g_hCvarThetaLosMax;
ConVar g_hCvarHpaEnable, g_hCvarHpaCellSize;
ConVar g_hCvarFlowWeight, g_hCvarZCostFactor;
```

**但 `l4d_path_to_goal.sp` 的 `OnPluginStart()` 中从未调用 `CreateConVar` 创建它们。**

代码中所有使用点都有 null 检查：
```cpp
if (g_hCvarThetaStar != null && g_hCvarThetaStar.BoolValue)
if (g_hCvarFunnel3D == null || !g_hCvarFunnel3D.BoolValue) return;
```

因为 ConVar 从未创建，这些检查全部失败 → 以下功能**永久禁用**：

| 功能 | 作用 | 影响 |
|------|------|------|
| Theta* | A\* 视线捷径、减少锯齿 | 路径点多、不平滑 |
| HPA* | 大图分层加速 | 5000+ nav area 地图效率差 |
| 3D Funnel | 多层 Z 轴过渡 | 寂静岭等多楼层图路径被大量拦截 |
| STAGE_REPAIR | 自动修复穿墙光束 | 阻挡的光束直接丢弃 |
| Beacon | 断路点信标柱 | 玩家看不到路径断在哪里 |

## 症状

在三方图（尤其是寂静岭等多楼层大地图）上，`!ptg` 后只显示起点附近的一两个点，其余全部消失。原因是：
- 没有 Theta* → A\* 路径点在 nav mesh 网格线上，大量对角穿越墙体
- 没有 3D Funnel → 多层过渡点缺失，beam 被 Z-gap 过滤器拦截
- 没有 STAGE_REPAIR → hull trace 判定为阻挡的 beam 无法修复
- 没有 Beacon → 阻挡点只显示微小圆点，在暗色恐怖图中几乎看不见

## 修复（2026-07-27）

在 `OnPluginStart()` 中，`g_hCvarNonMesh` 创建之后、`g_hCvarMPGameMode` 之前，补上全部 11 个 CreateConVar。

修改文件：`/home/ubuntu/l4d2-server/sourcemod/scripting/l4d_path_to_goal.sp`

已编译部署到容器 `/addons/sourcemod/plugins/l4d_path_to_goal.smx`。

## 教训

> **声明了的功能，CreateConVar 就必须跟上。** 不能依赖 null check fallback 当"默认禁用"——这会在毫无日志告警的情况下静默阉割所有高级功能，让人以为"插件能跑就没问题"，实际上核心能力根本没上线。

检查方法：部署后通过 RCON 直接查询 cvar 是否存在：
```
l4d_path_to_goal_funnel_3d
l4d_path_to_goal_theta_star
l4d_path_to_goal_repair_enable
l4d_path_to_goal_hpa_enable
l4d_path_to_goal_beacon_enable
```
返回 min/max 范围即为存在；返回 `Unknown command` 即为未创建。

Related: [[l4d2-ptg-funnel-bug]] [[l4d2-ptg-timer-bug]] [[l4d2-ptg-mapchange-crash]]
