---
name: l4d2-no-defibrillated-event
description: "L4D2 没有 \"defibrillated\" 游戏事件 — 电击复活也走 revive_success，需状态镜像区分"
metadata: 
  node_type: memory
  type: reference
  originSessionId: dafad0ff-6c8c-4d29-b792-2858510a4960
  modified: 2026-07-31T12:16:53.809Z
---

# L4D2 无 "defibrillated" 事件坑

**L4D2 的 `revive_success` 是唯一的复活事件**，同时覆盖：救助倒地队友、挂边拉起、电击复活。游戏二进制（server.so）里搜不到 `defibrillated`/`revived` 事件字符串。

- `HookEvent("defibrillated", ...)` 会在 OnPluginStart 抛异常 `Game event does not exist` → 插件加载失败（已创建的 cvar 会残留注册）
- 区分三种来源的正确做法：轮询镜像事件前状态 prop
  - `m_isHangingFromLedge`=1 → 挂边拉起
  - `m_isDead`=1 → 电击复活（死亡躯体保留期间持续为 1，电击前稳定）
  - 两者皆否 → 救助倒地
- 事件字段：`revive_success` 的 `subject`=被救者、`rescuer`=救人者；`pills_used` 的 `subject`=吃药者、`user`=递药者（自己吃则相等）

实例：[[l4d2-rescue-heal-plugin]]（2026-07-31 首版因 HookEvent defibrillated 加载失败，改状态镜像后修复）
