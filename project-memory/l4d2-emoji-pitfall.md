---
name: l4d2-emoji-pitfall
description: 💀 emoji 不显示，改用 ☠ — Source 引擎只支持 BMP，不支持 SMP emoji
metadata: 
  node_type: memory
  type: project
  tags: 
    - l4d2
    - encoding
    - plugin
    - pitfall
  originSessionId: 6f33ecab-1b6f-47fe-839f-af44e4dcff6d
  modified: 2026-07-29T08:08:04.753Z
---

# L4D2 Emoji 编码坑

## 问题

击杀反馈插件想用 💀 骷髅 emoji 作为击杀标记，实测在游戏中不显示。

## 根因

- **💀 U+1F480** — 4 字节 UTF-8，位于 SMP (Supplementary Multilingual Plane, Plane 1)
- Source 引擎的位图字体只支持 BMP (Basic Multilingual Plane, Plane 0)
- 任何 SMP 字符（现代 emoji、部分古文字等）都不会渲染

## 解决方案

**☠ U+2620** — 3 字节 UTF-8 BMP 字符，SKULL AND CROSSBONES（传统文字符号，非现代 emoji）

- 位于 Miscellaneous Symbols 块 (U+2600–U+26FF)
- 和中文、★（已广泛使用）同一层级，Source 引擎字体支持
- 视觉效果等同 💀，只是编码路径不同

## 判定规则

以后想在 L4D2 里用特殊符号，先看 Unicode 码位：

| Plane | 范围 | 字节数 | L4D2 |
|-------|------|--------|------|
| BMP (Plane 0) | U+0000–U+FFFF | 1-3 字节 | ✅ |
| SMP (Plane 1) | U+10000–U+1FFFF | 4 字节 | ❌ |

快速判断：`printf '\\U%x' 0x1F480` 输出 4 字节 → 不支持。
`printf '\\U%x' 0x2620` 输出 3 字节 → 支持。

## 关联

- [[l4d2-bf-killfeedback]] — 击杀反馈插件
