---
name: l4d2-common-limit-scaling
description: 小僵尸数量按人数动态缩放 — sm_max_common_base/extra/cap 三个 cvar
metadata: 
  node_type: memory
  type: reference
  originSessionId: 51364c0c-ce77-4658-919d-81f67701d287
  modified: 2026-07-27T07:37:39.979Z
---

# L4D2 小僵尸动态数量

**插件：** `l4d2_max_common.smx` (v1.3)
**源码：** `sourcemod/scripting/l4d2_max_common.sp`
**配置文件：** `cfg/sourcemod/l4d2_max_common.cfg`（首次加载自动生成）

## 公式

`z_common_limit = min(30 + max(0, 人数 - 4) × 6, 120)`

## 新增 ConVar

| ConVar | 默认值 | 含义 |
|---|---|---|
| `sm_max_common_base` | 30 | 4 人基础值 |
| `sm_max_common_extra` | 6 | 每多 1 人 +6 |
| `sm_max_common_cap` | 120 | 封顶 |

## 原有 ConVar

| ConVar | 默认值 | 含义 |
|---|---|---|
| `sm_max_common_enabled` | 1 | 开关 |
| `sm_max_common_leniency` | 5 | 超出阈值后额外容忍数 |
| `sm_max_common_timer` | 3.0 | 超阈值后等待 N 秒才开始删除 |
| `sm_max_common_cooldown` | 5.0 | 无超额 N 秒后退出清理模式 |

## 管理命令

`sm_common_limit` / `sm_common_count` — 显示当前人数、动态上限、公式参数

## 生效方式

每秒检测一次人数并更新 `z_common_limit`，换图时 AutoExecConfig 重新加载 cvar。
