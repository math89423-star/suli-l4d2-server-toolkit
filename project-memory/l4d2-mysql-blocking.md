---
name: l4d2-mysql-blocking
description: SourceMod databases.cfg 默认 MySQL 驱动导致服务器启动卡死
metadata: 
  node_type: memory
  type: feedback
  tags: 
    - l4d2
    - sourcemod
    - mysql
    - sqlite
    - hang
  originSessionId: 4b3417fe-a874-420c-b976-80f0ddfa0c75
---

# L4D2 SourceMod MySQL 驱动导致服务器启动卡死

## 现象
- 服务器启动后卡在 "Server is hibernating"，永远不唤醒
- 无 MetaMod/SourceMod 错误日志
- 无崩溃，进程存在但不响应
- 去掉 SourceMod configs 目录后恢复正常

## 根因
SourceMod `configs/databases.cfg` 中：
```
"driver_default"  "mysql"
```

容器内没有 MySQL 服务器，SourceMod 初始化时尝试连接 MySQL（localhost:3306），连接超时导致整个服务器初始化流程卡住。

同时 `"default"` 数据库配置用了 `"driver" "default"`，会 fallback 到全局的 `driver_default`（即 mysql）。

## 修复
将 `databases.cfg` 中所有 driver 改为 `sqlite`：
```
"driver_default"  "sqlite"
```
且每个数据库配置显式指定 `"driver" "sqlite"`。

**Why:** SourceMod 只需要 SQLite 来做本地存储（admin 权限、clientprefs 等），不需要 MySQL。MySQL 驱动需要额外的网络连接，容器内不可用。

**How to apply:**
1. 部署后检查 `addons/sourcemod/configs/databases.cfg`
2. `driver_default` 和所有 `driver` 字段改为 `sqlite`
3. 如果确实需要 MySQL（跨服共享数据），先确保 MySQL 容器先启动且可达

## 关联
- [[l4d2-permissions-pitfall]] — 文件权限问题（同一批排查出来的）
- [[l4d2-32bit-architecture-pitfall]] — 32位架构问题
- [[l4d2-deployment-rules]] — 综合踩坑清单
