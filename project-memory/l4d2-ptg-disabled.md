---
name: l4d2-ptg-disabled
description: PTG 导航插件已永久禁用（2026-08-03 用户拍板：效果差+占资源）；smx 改名 .disabled + RCON 热卸载；无任何插件依赖（全量 grep 验证）
metadata: 
  node_type: memory
  type: project
  originSessionId: f3dda53e-a801-4112-9add-65c88345feb2
  modified: 2026-08-03T08:07:36.999Z
---

# PTG 导航插件已禁用（l4d_path_to_goal，2026-08-03）

**用户拍板**："ptg 导航插件效果还是很差,而且留在占资源,不如关闭了吧"。

## 禁用方式（永久,重启不加载）

1. `plugins/l4d_path_to_goal.smx` → 重命名 `l4d_path_to_goal.smx.disabled`（引擎重启扫描 addons 时不再加载）
2. RCON `sm plugins unload l4d_path_to_goal`（即时生效,无需重启服务器,不踢在线玩家）

## 验证

- `sm plugins list` 76 个插件,已无 PTG
- 日志 2 分钟内零 error / missing native / exception（AI Hard SI 4.1.0 等全部正常）
- **无任何插件依赖 PTG**：全量 grep `PTG_` / `__pl_l4d_path` / `l4d_path` 只有自身 + include 文件命中（SharedPlugin 标记 SetNTVOptional,可选依赖）

## 背景

- 效果差 + 资源空转的实锤：日志持续刷 `A* node index failed: too few nav areas` → `Fallback failed` → `retry 1/2...` → `60s backoff` 循环（见 [[l4d2-ptg-v48-optimization]] [[l4d2-ptg-fallback-loop-fix]] 等历史修复,修了多轮仍不满意,用户最终拍板弃用）
- cfg/sourcemod/l4d_path_to_goal.cfg 残留无害（不再加载）
- PTG 相关历史记忆（v4.0-v4.8 各版本修复）保留作档案,不再适用

相关：[[l4d2-plugin-inventory]]（插件清单,70+ active 状态已变化）[[l4d2-dont-touch-server]]（静默规则）
