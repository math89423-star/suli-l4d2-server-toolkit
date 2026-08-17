---
name: l4d2-ptg-v48-optimization
description: PTG v4.8 卡顿优化：soft rebuild（dirty/geom rebuild 复用 node index+portal cache）+ geom 阈值 REPAIR + detour 失败注入 blocked edges + IG BFS 并入桥；效果差根因=goal 锁死 start 组件
metadata: 
  node_type: memory
  type: project
  originSessionId: fadf12b2-db44-47a1-bb4e-ad3f6fc7fd7a
  modified: 2026-08-02T16:58:20.404Z
---

# PTG v4.8 卡顿+效果优化（2026-08-03，已编译未部署）

## 触发
用户实测：大型三方图（4567 nav areas）PTG 效果极差 + 很卡。

## 卡顿根因（日志实证 00:13-00:16 c?大图）
1. **每 60-120s 一次全量 rebuild**（PathIntegrityCheck/detour 失败 → NavChanged(true) → dirty → Guide_Prep）
2. **每次 rebuild portal 分类全量重算**：enumerated=18954 对、classified=9481 对、GetAdjacentAreas 18268 次，~1.3s+ 每帧吃满 0.5ms 预算
3. **geom-iter 强制第二遍全量 rebuild**：validation 有 1 条 blocked 就 Guide_Cleanup+Guide_Prep（00:15:54 实锤 "4 blocked beams recorded — rebuilding path" 后 1 秒内又跑一遍全量分类）
4. **detour 失败不记忆**：blocked 区域物理不变，rebuild 后依旧 blocked → 循环

## 效果差根因
5. **IdentifyGoal BFS 只用 nav 连接不用 non-mesh 桥** → 断裂 nav 三方图（3581/4567 unreachable, 14 bridges）goal 锁死在 start 组件（实测 z=16 地下室）→ 引导线指向错误方向。A* 搜索本身用桥（GetNonMeshConnections），但 goal 选择被组件限制。

## v4.8 修复（5 处，均已编译 305644 bytes）
1. **Soft rebuild**（ptg_pipeline.inc）：`Guide_Prep(bool soft)` + `Guide_CleanupSoft()`。dirty/geom rebuild 复用 A* node index + portal cache（g_bPortalReady 保留）+ HPA + bridges，跳过 phase 0-3 直接 post-build→A*。入口 `g_bSoftRebuild = soft && !g_bForceFullRebuild`。
   - **`g_bForceFullRebuild` 只在 evtPostNav（round_start_post_nav）设置**（nav 数据真变了）；其余 dirty 源（detour 失败/geom iter）soft。
   - Portal_ComputeBatch 入口 `if (g_bPortalReady) return true` 跳过分类
   - Timer_AutoCheck dirty 分支 → `Guide_Prep(true)`
   - soft 降级保护：`g_hAStarNodes <= 1 || !Portal_Active()` 时降级 full
2. **Geom-iter 阈值化**（ptg_validate.inc）：blocked ≤8 且 ≤25% beams → **直接 Guide_RepairBlocked()，不重建**（REPAIR 有 Z-step/偏移/细分/局部A*/beacon）；超阈值 → blocked edges 入表 + `Guide_Prep(true)` soft rebuild
3. **Detour_Fail 注入 blocked edges**（ptg_detour.inc）：失败时 blockedIdx±2 窗口的 cell 对写入 g_hBlockedEdges（"%d|%d" navArea 格式，与 validation/EdgeCostVisible 一致）→ 下次 A* penalty 绕开 → 收敛
4. **IG BFS 并入 non-mesh 桥**（ptg_astar.inc AStar_IdentifyGoal_Frame）：邻居扩展加 GetNonMeshConnections(areaInt, AdjNN) 并 PushArray 到 ConAdj（与 AStar_SearchFrame 同模式）→ goal 可落到真出口组件
5. **移除 HV-blocked 诊断日志**（v4.7.3 临时）

## 验证清单（部署后看日志）
- `[PTG] Soft rebuild — reusing node index + portal cache` 出现
- dirty rebuild 后 **无新 Portal diag 分类增长**（portal 只全量一次/局）
- `Geometry: N/M blocked beams below repair threshold — REPAIR in place`（小 blocked）
- `Detour failed ... N edges recorded as blocked — soft rebuild`
- IG BFS 后 `A* goal: max-flow reachable index X (... bfs_nodes=N)` —— N 应接近全图（桥并入后），z 应对应真出口

## v4.8.1-4.8.3 演进（2026-08-03 部署完成）
- **v4.8.1**：reload 中途接管（OnPluginStart 末尾 `GetCurrentMap` 非空 → `MapStarted()`）——否则 reload 后 map_started=false 直到下次换图，PTG 完全失效
- **v4.8.2**：A* maxNodes 100 → `g_iAStarNodesPerFrame`（自适应 300）；**cfg `l4d_path_to_goal_budget` 5.0→1.5**（5ms/帧=30% 帧预算 = "很卡"直接来源，改 cfg/sourcemod/l4d_path_to_goal.cfg；detour_budget 0→10）
- **v4.8.3**：正式版（移除 V8DIAG 诊断）
- 已验证：geom 阈值（≤8 直接 REPAIR / >8 soft rebuild）、soft rebuild 复用 portal cache（日志无 Portal diag 重算）、IG BFS 桥并入（bfs_nodes 986→1050→5145/6334，goal z 16→506）、budget 1.5ms
- **A* 全展开仍是大图构建瓶颈**（6334 节点图 soft rebuild ~9 秒，但每帧 1.5ms 渐进无感）；后续可提 astar_budget_ms 或缓存邻居表
- 遗留：PARTIAL path（goal 不可达组件）→ 死路 beacon 是正确降级；64 桥图中 A* 仍到不了 goal（farthest z=552 组件）

## 部署状态
- 编译：`cd /opt/gameservers/l4d2/data/addons/sourcemod/scripting && ./spcomp64 l4d_path_to_goal.sp -o /tmp/ptg-v483.smx -i./include`
- **v4.8.3 已部署运行**（sm plugins info Version 4.8.3 2026-08-03）；v4.7.4 备份 plugins/l4d_path_to_goal.smx.bak.v4.7.4
- **RCON 必须用 admin 容器**：`docker exec l4d2-admin python3 -c "from rcon.source import Client; ..."`（config.json 密码；本机 legacy 脚本 AUTH 是假象、challenge 响应全零、ident=1 无响应）
- errors_20260801/02.log 已清（173MB+36MB）
- git 未 commit（v4.7.1-4.8.3 工作区改动挂起，含 l4d2_shop_artillery2.sp/mapcycle_custom.txt 等其他插件改动）

Related: [[l4d2-ptg-v47-status]] [[l4d2-ptg-detour-rebuild-loop-fix]] [[l4d2-ptg-beam-quality-fix]] [[l4d2-source-code-location-pitfall]]
