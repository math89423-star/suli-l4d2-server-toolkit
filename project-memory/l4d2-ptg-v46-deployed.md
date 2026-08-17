---
name: l4d2-ptg-v46-deployed
description: PTG 寻路插件 v4.6 已部署（2026-07-31），5 批次的架构变更要点与验证结论
metadata: 
  node_type: memory
  type: project
  originSessionId: 9d2eddc2-1933-4c13-9888-2347f0614917
  modified: 2026-08-01T02:17:54.684Z
---

PTG (`l4d_path_to_goal`) v4.6 已于 2026-07-31 部署到服务器并验证通过（c1m1_hotel：Pipeline done 54 cells，REPAIR fixed=16 beaconed=8，无崩溃）。源码仓库 `/opt/gameservers/l4d2/data/addons/sourcemod/` 已提交 8 个 commit（v4.6 batch1-5 + 2 个修复）。

**关键架构变更（维护时必读）：**
- 看门狗：30s 总时长检查已删（在 `Guide_Prep` pipeline.inc），改为 `g_fLastPrepProgressTime` 进度检测（OnFramePrep 每帧刷新，Timer_AutoCheck 检查 10s 无推进，`PREP_STALL_SECONDS` types.inc）。只杀卡死不杀慢。
- `g_iMapGeneration` 现在 OnMapStart+OnMapEnd 双递增，三处跨图防护（pipeline:130/validate:35/249）真激活。
- `round_start_post_nav` 软置脏（`NavChanged(true)`），不再全量 Cleanup；dirty 块条件放宽为 `!guide_prep`。
- fallback 有 60s 退避（`g_iFallbackStage=3`，`g_fFallbackBackoffUntil`）。
- post-build init（pipeline phase -1）子状态机 `g_iPostStep` 0-4；STAGE_SMOOTH 子状态机 `g_iSmoothStep` 0-4；IdentifyGoal BFS 拆 Init/Frame/Finish。⚠️ 子状态机各 case 完成分支必须置 `budget_spent=true`（case 2 曾漏置导致首次构建失败，commit 9c5994a）。
- HPA >5000 区跳过（`HPA_SKIP_THRESHOLD`）；portal cache 无消费者（ReconstructPath 用 area center），SMOOTH 不再算 portal。
- 死亡玩家画路径用死亡位置（player_death 记录，120s 有效）；动态 beam 密度（近区 600u 逐 cell，远区均分预算）。
- REPAIR 有 `g_bGuideCellsBusy` 互斥（绘制快照、请求入队延迟补画）。
- TryHull 用 TraceFilterStatic（accuracy 开=Walkable）；SpatialHash 512；桥接截断保留部分集。
- A* 耗尽 → `g_bAStarPartialPath` + `g_hPartialBeacon` 断链 beacon（独立于 REPAIR 的 g_hBeaconCells）。
- 大图懒加载：`l4d_path_to_goal_lazy_large_maps`（>8000 区不预构建）。
- 局部绕行 ptg_detour.inc：nav_blocked/PathIntegrityCheck → `Guide_TryLocalDetour`（窗口 ±12 cells 局部 A*，失败 2× 扩窗 → 全量）。detour 全局在 types.inc（validate.inc 先 include 的坑）。
- 机关区：`l4d_path_to_goal_radio_goal`（finale_radio_start 时 goal 改到 prop_finale_machine 操作点 + `g_hRadioBeacon` 信标）。

**坑：** docker logs 的 [PTG] 日志有 stdout 缓冲滞后，验证要看 `/opt/gameservers/l4d2/data/addons/sourcemod/logs/L*.log`（权威）。

**后续修复（2026-08-01, e2f5155）：** SMOOTH 子状态机泄漏（smoothStep 只在成功分支重置 + fallback 跳入不重置 → case 4 空 Handle 崩溃循环）+ 退避不生效无限重试，见 [[l4d2-ptg-fallback-loop-fix]]。
