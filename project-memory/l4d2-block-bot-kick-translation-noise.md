---
name: l4d2-block-bot-kick-translation-noise
description: Block Invalid Bot Kick 插件 FindTarget 翻译短语缺失报错——用户拍板不修不重写，仅作已知噪音记录
metadata:
  node_type: memory
  type: decision
  modified: 2026-08-16T01:40:00.000Z
---

`plugins/block_bot_kick.smx`（"Block Invalid Bot Kick" v1.0 by claude，2026-07-19 编译，源码未保留——编译时路径 `/tmp/block_bot_kick.sp`）在调用 `FindTarget`（helpers.inc 老 API）匹配失败/多匹配时，报翻译缺失：

```
Language phrase "More than one client matched" not found (arg 4)   ← Blaming: block_bot_kick.smx
Language phrase "No matching client" not found (arg 4)             ← Blaming: block_bot_kick.smx
```

**根因推断**：两个短语在根目录 `translations/common.phrases.txt` 中**存在**（第 29/13 行），但插件仍报 not found → 疑似源码漏了 `LoadTranslations("common.phrases.txt")`。`.smx` 二进制被 SourceMod 1.12 字符串混淆，strings/python 多种解码均提取不到可读串，无法确认/反编译；网上插件库（fbef0102/L4D1_2-Plugins 等）无同名源码。

**触发场景**：玩家对 bot 执行踢人命令且目标名模糊（多匹配/无匹配）时触发，属 cosmetic 提示语缺失；核心功能（阻止无效踢 bot）不受影响。

**决策（用户拍板 2026-08-16）**：**不修、不重写**。插件上线一个月，从未有玩家反馈问题。报错只进 errors 日志（`errors_20260816.log` 等多条），标记为**已知噪音**即可。后续若再出现相关玩家投诉再考虑重写等价插件（重写时必须在 OnPluginStart 加 `LoadTranslations("common.phrases.txt")`）。