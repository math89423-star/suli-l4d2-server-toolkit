---
name: l4d2-flow-path-validation
description: flow 梯度下降方案实验验证结论（2026-08-04）：引擎 flow=弧长递增朝出口；c1m1 覆盖 75.1% 零断链、LOS 1.7%；tumtara 无 nav 安静退出
metadata: 
  node_type: memory
  type: project
  originSessionId: 3b815306-9932-46c4-a273-89e0ccf4f19a
  modified: 2026-08-03T16:29:45.014Z
---

# flow 梯度下降寻路方案验证（2026-08-04，实验插件 l4d2_flow_path_test）

背景：PTG（l4d_path_to_goal v4.8.3）已弃用（[[l4d2-ptg-disabled]]），新方案 = 引擎 flow 场 + 4 向邻接梯度下降，替代 11k 行自建 A* 管线。实验插件仍在服务器 plugins/（无害：仅 ADMFLAG_ROOT 命令，无后台活动），空服时可继续用。

## 关键结论

1. **引擎 flow 语义 = 从地图起点沿 nav 的弧长（弧长位置），递增方向 = 出口方向**。PTG 代码早已暗示（get_flow_iStart 找 flow>=玩家 的 cell、IdentifyStart 找 flow 最小 PLAYER_START、detour_join target=g_fMaxFlow）。初次实现方向反了（递减=朝出生点），1.1% 可达 → 修正递增后 0 断链。
2. **c1m1_hotel（官方图）实测**：
   - 4 向梯度上升：870/1252 (69.4%) 到达出口，**断链 0**
   - 轻量 BFS 桥（无 flow area 4 向 BFS 到最近有 flow 区，深 60）：+71 (5.6%)，平均桥深 3
   - 最终覆盖 941/1252 (75.1%)；剩余 311 area = 引擎全部连接（含 jump/ladder）也不可达的区域（屋顶/装饰区，玩家到不了）
   - **LOS 质量：2/112 段 blocked (1.7%)**（vs PTG 45%→17%→11%）
   - 单次路径计算 **0.9ms**（出生点 113 步 flow 0→15994 穿越全图）
3. **tumtara（无 nav）**：L4D_GetAllNavAreas 返回空（areas=0），安静退出零报错（vs PTG forever fallback 刷屏）。
4. 4 向邻接不含 jump/ladder —— 引擎 flow 用全部连接传播（comp#0 398 areas 有 flow 但 4 向断链 = 电梯/跳台挂载区），故纯 4 向梯度会在电梯口断 → beacon 降级（玩家看到线到电梯口自然坐电梯）。

## 命令速查（实验插件）

- `sm_flowtest [x y z]` — 梯度上升画线 + LOS 统计（无活玩家时自动从 PLAYER_START 出发；RCON 测法）
- `sm_flowtest_all` — 全图逐 area 可达性 + 桥接统计（c1m1 ~313ms）
- `sm_flowtest_map` — 4 向连通组件统计 + flow 覆盖

## 待验证（等空服）

- c1m1 多点 LOS（不同楼层/走廊/门洞）
- 机关开启后 flow 实时变向（c2m3 过山车）
- 三方大图（l4d_yama_1 2504 areas；4567 areas 大图）覆盖 + 卡顿
- 正式版：共享边中点（L4D_NavArea_GetCorner）替代 area center 连线，消除残余 1.7% blocked

相关：[[l4d2-ptg-disabled]] [[l4d2-ptg-v48-optimization]] [[l4d2-dont-touch-server]]
