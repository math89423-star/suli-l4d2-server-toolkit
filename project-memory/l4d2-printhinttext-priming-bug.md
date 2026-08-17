---
name: l4d2-printhinttext-priming-bug
description: L4D2 PrintHintText 第一条 hint 必须替换已有 hint 才能正常渲染 CJK，否则变乱码 + 阴影框残留
metadata: 
  node_type: memory
  type: project
  tags: 
    - l4d2
    - sourcemod
    - printhinttext
    - CJK
    - rendering
  originSessionId: 366d1084-b0ac-4bba-aece-201df5e52fe1
  modified: 2026-07-31T17:38:09.130Z
---

# L4D2 PrintHintText Priming Bug

## 现象

`PrintHintText` 发送 CJK（中文）文本时：
1. 文字**先正常显示**
2. 然后**立刻变乱码**（笔画支离破碎）
3. 阴影框**很久不消失**（`PrintHintText("")` 无法清除，引擎自然淡出需数秒）

## 根因

L4D2 的 PrintHintText 有一个已知引擎 bug：[第一条 hint 不会正确渲染，除非它是在替换一个已经存在的 hint](https://forums.alliedmods.net/showthread.php?t=336573)。

社区确认的机制：
- 第一条 `PrintHintText` → 被吃掉/渲染残缺
- 后续 `PrintHintText` 替换已有 hint → 正常
- `PrintHintText("")` → 只清文字，**不清阴影框**，框残留到自然淡出

## 为什么旧系统（bf_killfeedback v3.5.x）没问题

旧系统 `L4D_All_Infected_HUD_HP` 用 PrintHintText **持续刷新**（持久 HP 显示），PrintHintText 通道始终有活跃 hint。bf_killfeedback 的击杀 PrintHintText 永远在 **替换已有 hint**，bug 不触发。

bf v3.5.1 加的 50ms 延迟不是修这个 priming bug，而是修**同帧内两次 PrintHintText 竞争导致背景框 resize → CJK 撕裂**。这两个是**不同的 bug**。

## 新系统（si_hud v1.4.0+）为什么会触发

si_hud v1.3.0 把 HP 显示从 PrintHintText 改成了 PrintCenterText。PrintHintText 通道变为空闲。击杀时的 PrintHintText 成了"第一条 hint"→ 两个 bug 都触发了。

## 修复方案

在 si_hud v1.6.4 中，每次击杀卡片前先 **prime 通道**：

```c
// 立即发送空白 hint prime 通道（不可见，但 channel 被激活）
PrintHintText(client, " ");

// 下一帧发送真正的击杀消息（此时是"替换已有 hint"，正常渲染）
RequestFrame(Frame_ShowKillCard, userId);
//   → PrintHintText(client, "[M16] ☠ HUNTER 猎人(head shot)");
```

## v1.6.4 定论（2026-08-01，重要修正）

- L4D2 hint 是**单槽替换**：每条新 hint 立即替换当前并重置引擎固定 ~4s 计时。
- **主动清除（PrintHintText " " 或 ""）不是清除**——是发一条不可见的空格消息，
  它自己显示满 4s。用户看到的"空阴影框延迟消失"就是**这条空格消息的框**，
  不是 fade 慢（v1.4.1 误判为"框无法清除"）。
- 正确做法：**不主动清除，自然 fade-out**——文字+框同一元素同时淡出（一起消失）。
- SourceMod HintTextMsg（core/HalfLife2.cpp）非 CS:GO 引擎只写 string，**无 lifetime 字段**，
  "协议级 WriteShort(-1) 清除"在 L4D2 无效。

## 关联

- [[l4d2-bf-killfeedback]] — bf_killfeedback v4.0.0 纯音效
- [[l4d2-emoji-pitfall]] — ☠ (U+2620 BMP) vs 💀 (SMP)
- [[l4d2-plugin-inventory]] — 插件清单
