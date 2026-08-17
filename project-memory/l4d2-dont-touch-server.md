---
name: l4d2-dont-touch-server
description: "用户说\"在玩\"/\"别执行\"时，服务端任何操作（含只读）都不许做，只写本地文件"
metadata: 
  node_type: memory
  type: feedback
  tags: 
    - l4d2
    - server
    - rules
    - safety
  originSessionId: b9b6dac1-f58d-4856-8419-3bbadd708f38
---

# 服务器静默规则

用户说以下任意关键词时，**禁止对游戏服务器做任何操作**（包括只读命令如 `ls`、`cat`、`find`、`docker logs`、RCON）：

- "在玩" / "正在玩" / "有人在玩"
- "别执行" / "不要执行" / "不许执行" / "别动" / "别碰"
- "只写文件" / "只更新记忆"
- 任何明确表达"不要操作服务器"的话

**为什么连只读都不行**：
- docker exec 进容器读文件可能卡住主线程
- find 遍历挂载目录产生 IO 争抢
- 任何意外都可能影响玩家体验

**正确做法**：
- 只写本地文件（记忆、脚本、配置）
- 如果确实需要读服务器文件来完成任务，先告诉用户需要读什么，等用户说可以再读

## 关联

- [[l4d2-deployment-rules]] — 总体铁律
- [[l4d2-map-switch-pitfalls]] — 切图踩坑
