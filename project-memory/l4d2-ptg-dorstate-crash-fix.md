---
name: l4d2-ptg-dorstate-crash-fix
description: "PTG \"Please wait\" 根因 = func_door 读 m_eDoorState 崩溃卡管线（v4.6.1）+ 同日修的 AI_HardSI/SM 组合管理器"
metadata: 
  node_type: memory
  type: project
  originSessionId: e735d80f-6fa8-4177-bfac-d049effae7b1
  modified: 2026-08-01T13:49:08.164Z
---

# PTG "Please wait..." 根因修复（2026-08-01，commit 5007d9a）

## 症状 → 根因链路

玩家双击 PTG 永远回 "Please wait..."（`CmdRequestGuide` l4d_path_to_goal.sp:399 `ptg_wait` 分支）：
`guide_ready` 永远 false ← 管线卡死（看门狗每 10s 重置）← `DetectNonMeshConnections_Frame` 中断 ← **trace filter 回调里抛异常**。

## 根因（ptg_utils.inc）

`m_eDoorState` 是 **prop_door_rotating 专属（Prop_Send）**；`func_door`/`func_door_rotating` 没有 → `GetEntProp` 抛 `Property "m_eDoorState" not found` → 引擎 trace 回调里抛异常中断整个 TR_TraceRayFilter → 管线永不完成。l4d_yama_1（2504 areas 三方图，含大量 func_door）从 16:49 起每 12s 刷一次，errors 日志 81MB→143MB/天。

## 修复

1. **func_door 系列** → datamap `m_toggle_state`（CBaseDoor 基类属性，必存在）：0=TS_AT_TOP 开 / 1=TS_AT_BOTTOM 关 / 2=开中 / 3=关中。阻塞条件 `toggle==1 || toggle==3`。
2. **prop_door** → 精确 `strcmp(class,"prop_door_rotating")` 才读 m_eDoorState；其他 prop_door* 变体保守视为阻塞。
3. `TraceFilterWalkableStrict`（ground-snap 用）同样两处修复。

**坑：本机 include 太旧（SM 1.10 时代）没有 `TryGetEntProp`**（SM 1.11+ native），不能用它兜底，只能精确匹配 classname。

## 验证

- yama 图：reload 前 m_eDoorState 最后一条 20:39:12；reload 后 1s 内 `Pipeline done: 116 guide cells`，零新增
- c1m1_hotel：`Pipeline done: 80 guide cells` + REPAIR 正常，无回归

## 同日连修的两个独立刷屏 bug

**AI_HardSI_bt（m_hasBeenBoomed，全天 11 万+ 次，每秒 70-130 次）**：`bt_spitter.inc:84` / `bt_smoker.inc:221` 用 `Prop_Data` 读 `m_hasBeenBoomed`，但它是 **Prop_Send** 属性 → 每帧抛异常。改 Prop_Send 后 21:45 起归零。

**si_composition_manager（每次换图报错）**：`ScheduleNextModeRotation` 的 `delete g_hModeTimer` —— timer 恰在换图边缘 fire 时引擎已关闭 handle 但变量还指着 → invalid。修法：`if (g_hModeTimer != null && IsValidHandle(g_hModeTimer)) KillTimer(...)` 后置 null。

## 踩坑教训

- **trace filter 回调（TR_TraceRayFilter 的 filter 函数）里任何 GetEntProp 抛异常都是致命的** —— 它中断的是引擎回调，整个管线静默卡死，只有看门狗能兜底
- **AI_HardSI 编译产物名 ≠ 部署文件名**：`AI_HardSI.sp` 编译输出 `AI_HardSI.smx`，但部署名是 `AI_HardSI_bt.smx`（编译必须 `-o AI_HardSI_bt.smx`）。这次 cp 了 scripting 里的旧编译物导致**误降级**（Jul 29 44940 vs 服务器 51115），reload 旧版后错误照刷才发现
- 修插件先确认 `git status` 里源码版本 vs 服务器二进制版本（本次源码 v3.7 == 服务器 v3.5 (3.7) 一致）

Related: [[l4d2-ptg-v46-deployed]] [[l4d2-ptg-fallback-loop-fix]] [[l4d2-si-composition-manager]]
