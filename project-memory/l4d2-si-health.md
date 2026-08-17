---
name: l4d2-si-health
description: L4D2 特感血量配置 — Tank/Witch 实际值与播报值对齐
metadata: 
  node_type: memory
  type: project
  tags: 
    - l4d2
    - server
    - tank
    - witch
    - health
  originSessionId: 52c7c187-adc5-4eed-af5c-4cd538009447
---

# L4D2 特感血量配置

## 难度

`z_difficulty Hard`（server.cfg）

## Tank 血量

### 实际设置（hp_scaler）

**插件**: `l4d2_tank_hp_scaler.smx`
**配置**: `cfg/sourcemod/l4d2_tank_hp_scaler.cfg`
**公式**: `Tank HP = 存活幸存者 × sm_tank_hp_per_survivor`
**当前值**: `sm_tank_hp_per_survivor 3000`

| 幸存者 | Tank HP |
|--------|---------|
| 4 | 12,000 |
| 6 | 18,000 |
| 10 | 30,000 |

### 播报（tank_announce）

**插件**: `l4d2_tank_announce.smx`（第三方编译插件，无源码）
**配置**: `cfg/sourcemod/l4d2_tank_announce.cfg`
**内部公式**: `l4d2_tank_minimum + l4d2_tank_health × (幸存者 - 4)`

⚠️ 必须与 hp_scaler 对齐：`minimum = 4 × 3000 = 12000`, `health = 3000`

**2026-07-22 修正**: `health 2500→3000`, `minimum 8000→12000`，使播报值 = 实际值。

hp_scaler 同时通过 `SyncAnnounceCvars()` 动态覆写 `l4d2_tank_minimum`，修正静态配置确保即使动态同步失效，播报也正确。

## Witch 血量

- `l4d2_witch_minimum 1000`
- `l4d2_witch_Multiples "0.8;1.0;1.5;2.0"`（Easy/Normal/Hard/Expert）
- Hard 下: 1000 × 1.5 = **1,500 HP**
- `l4d2_witch_health 0`（0=不额外增量）

## 普通特感血量

引擎默认 Hard 难度值，无插件修改。

## 关联记忆

- [[l4d2-server-quick-reference]] — 多特感刷新配置
- [[l4d2-announcements]] — 公告文本（含 Tank 血量描述）
