---
name: l4d2-ptg-timer-bug
description: SourceMod TIMER_REPEAT bug on empty servers and the recursive one-shot fix
metadata: 
  node_type: memory
  type: project
  tags: 
    - l4d2
    - sourcemod
    - timer
    - bug
  originSessionId: ded8d4bd-d556-469e-9377-5067501a8436
  modified: 2026-08-12T15:14:58.783Z
---

## Root Cause

`CreateTimer(interval, callback, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE)` created in `OnPluginStart` DOES NOT FIRE on empty servers (no players connected).

## The Fix: Recursive One-Shot Timers

Instead of TIMER_REPEAT, call `CreateTimer` inside the callback itself to reschedule:

```sourcepawn
// OnPluginStart — start with a one-shot (no TIMER_REPEAT flag)
g_hAutoCheckTimer = CreateTimer(2.0, Timer_AutoCheck, _, TIMER_FLAG_NO_MAPCHANGE);

// In the callback — reschedule before any early returns
Action Timer_AutoCheck(Handle timer)
{
    if (!g_hCvarAutoEnable.BoolValue)
    {
        g_hAutoCheckTimer = CreateTimer(2.0, Timer_AutoCheck, _, TIMER_FLAG_NO_MAPCHANGE);
        return Plugin_Stop;
    }
    
    // RESCHEDULE HERE (after early return, before logic)
    g_hAutoCheckTimer = CreateTimer(2.0, Timer_AutoCheck, _, TIMER_FLAG_NO_MAPCHANGE);
    
    // ... logic ...
    
    return Plugin_Stop;
}
```

**Why:** This was the working pattern in the lost v3 intermediate source (ptg_v3.smx, 45376 bytes). Recompiling with TIMER_REPEAT produces a binary where the timer chain never fires on empty servers.

**How to apply:** Always use recursive one-shot timers for any timer that needs to run on empty L4D2 servers. TIMER_REPEAT is unreliable when no players are connected.

## v5.0.1 补充：递归 one-shot 的幽灵定时器泄漏（2026-08-12）

在 v5.0.0 的 Timer_ToggleRedraw 里，"回调开头就排下一次 + `!anyOn` 时把全局句柄置空 return" 的写法有泄漏：
回调开头已 `CreateTimer` 排了下一轮，句柄存进全局；然后判 `!anyOn` 把全局置 null + return Plugin_Stop —— 刚排的那轮定时器没有句柄可杀，成了幽灵定时器。反复开关/玩家掉线多次后累积并发多个幽灵定时器，各自循环重排，互相叠加（会重复画线、重复扣减，玩家看到"第二个玩家开启没反应"类假象之一）。

**铁律**：递归 one-shot 的下一轮必须**干活干完再排**（回调末尾排 + return Plugin_Continue；无活可干直接 return Plugin_Stop，不排）。全局句柄在回调开头先置空（本回调已到期），排下一轮时重新赋值。参考 [[l4d2-ptg-v5-flowline]] v5.0.1。
