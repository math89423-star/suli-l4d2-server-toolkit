---
name: l4d2-ptg-v47-status
description: PTG v4.7 重构状态：v4.7.4 已部署并验证（c3m4 explored_finale null 崩溃修复，Pipeline done 无崩溃）；v4.7.3 效果已确认（excluded 上涨/blocked 下降）；待玩家实测 c3m3 + 移除诊断日志 + git commit
metadata: 
  node_type: memory
  type: project
  originSessionId: 46a536f1-83ae-41c2-9955-154273150483
  modified: 2026-08-02T02:22:22.627Z
---

# PTG v4.7 重构状态（2026-08-02）

用户 4 条投诉：线质量差（浮空/穿墙/绕环）、大地图覆盖不足、不可达误判（高台）、偶发卡顿 → v4.7 portal 重构（真实共享边路径点 + 人类能力边过滤 + 性能）。

**已确认修复（部署验证通过）：**
- v4.7.1：coarse-first 钩子提前置 `guide_ready=true` 静默杀死管线（OnFramePrep 守卫 `!guide_ready`）。修复后 "Pipeline done" + "Hull validation" 恢复出现。
- v4.7.2：`Portal_ComputeBatch` 批次游标 bug —— 循环只处理 count=100 个 area，但结束无条件 `g_iPortalBatchIdx = nodeCount` 宣告完成 → 只分类前 100 个 area（diag 310/13）。修复后分类全量：`enumerated=3945 lookupMiss=0 classified=1992 (cache=1759 excluded=233)`（00:46:20 日志）—— excluded>0 = 人类能力过滤首次真正生效。

**未解决：** Hull validation 25/33 → 29/35 (83%)，blocked 6/35 (17%)，与 v4.6.1 基线 18% 持平；每次构建 side:2-3（侧偏 18u 才过 = portal 贴墙）+ stair:0 vault:0。归因：min_overlap 默认 12u < 玩家 hull 32u，窄缝 portal 中心坐墙。

**v4.7.3（历史：2026-08-02 早间 cp 未重启 → 后已重启生效并测试，见上方实测段）：**
- `l4d_path_to_goal_portal_min_overlap` 12→24（窄缝转 excluded，A* 绕真走廊）
- ptg_validate.inc blocked 段坐标诊断 `HV-blocked[%d] len dz p1 a1 p2 a2`（临时，归因后移除）
- 源码 md5：/tmp/ptg-v473.smx = 5ffdebcab5df36dc3b1f71cade4c8ba5；plugins 里当前文件的 md5 应与之一致（用户已 cp）

## v4.7.3 实测（2026-08-02 上午，服务器已重启过、v4.7.3 生效）

- ✅ excluded 上涨：00:46 (v4.7.2) 233 → 09:54 (v4.7.3) 1230（33966 enumerated）
- ✅ Hull blocked 下降：00:46 6/35 (17%) → 09:54 1/9 (11%)
- ✅ HV-blocked 拿到坐标：`HV-blocked[0] len=201 dz=-2 p1=(-5712,2137,138)`（c3m? 09:54）
- ❌ **c3m4 崩溃**（10:01:55）：`Invalid Handle 0 (error: 4)` @ ArrayList.FindValue / ptg_pipeline.inc:719 OnFramePrep
  - 根因：STAGE_JOIN 的 `explored_finale.FindValue` 无 null 保护；初始化在 STAGE_SMOOTH 且被 `g_bFoundRescueVehicle` 包裹——dirty rebuild 时 SMOOTH 没走到初始化 → JOIN 直接用 null 崩溃 → 管线卡死 → **please wait**
  - 修复 v4.7.4：STAGE_JOIN 进入 finale 探索前 `if (explored_finale == null) explored_finale = new ArrayList();`（ptg_pipeline.inc，1 行）

## v4.7.4（2026-08-02 已热重载部署，已验证）

- **验证通过**：10:12 reload 后两次构建 "Pipeline done: 38 guide cells ready" 无崩溃
- 备份 `plugins/l4d_path_to_goal.smx.bak.v4.7.3`；smx md5 与 /tmp/ptg-v474.smx 一致

## 待办

1. 玩家实测 c3m3/c3m4 无 please wait、引导线正常
2. 效果稳定后移除诊断日志（HV-blocked 临时坐标输出）
3. git commit 仍挂起（v4.7.1-v4.7.4 工作区改动；本机找不到 git 仓库本体——旧 /home/ubuntu/l4d2-server-pack 与 l4d2-package 是标准 SM 部署包且已于 2026-08-02 清理删除；编译源 /opt/gameservers 已是新版）

**约束：** 服务器有玩家时禁止任何操作（[[l4d2-dont-touch-server]]）；SM 日志 `/opt/gameservers/l4d2/data/addons/sourcemod/logs/L*.log` 才是权威；编译 `cd scripting && ./spcomp64 l4d_path_to_goal.sp -o /tmp/xxx.smx -i./include`；外网被限（curl/valve wiki 不通），.nav 离线解析器写不了，HV-blocked 坐标 + 运行时数据足够归因。
