---
name: l4d2-docker-logs-pitfall
description: SRCDS 默认只写 console.log 文件不走 stdout，docker logs 为空；需加 -condebug 参数
metadata:
  node_type: memory
  type: feedback
  tags:
    - l4d2
    - docker
    - logs
    - debugging
    - pitfall
  originSessionId: 5e46cc7c-ebb8-43ef-a4bf-3009e5be0841
---

# L4D2 Docker 日志看不到输出

## 现象
- `docker logs l4d2-server` 输出极少或无输出
- 服务器明明在运行，但看不到插件加载、地图加载、玩家连接等日志
- 排查问题时只能进容器看 `console.log` 文件

## 根因
SRCDS 默认把控制台输出重定向到 **文件**（`left4dead2/console.log`），而不是 stdout。Docker 只能捕获 stdout/stderr，看不到文件内容。

`jackzmc/srcds-l4d2:master` 镜像的默认入口脚本没有开启 console-to-stdout 模式。

> **2026-07-25 已迁移到 `left4devops/l4d2`，新镜像日志行为可能不同，详见 [[l4d2-docker-migration]]。**

**Why:** Source 引擎的传统行为是把日志写文件，这在裸金属部署时没问题，但在 Docker 环境下破坏了 `docker logs` 的可用性。

**How to apply:**
1. 在启动参数中加 `-condebug`：`+exec server.cfg -condebug`
2. 或者修改 docker-compose.yml 的 command，确保包含此参数
3. 验证：`docker logs -f l4d2-server` 应能看到完整启动日志
4. 排查问题时，如果已有日志问题，直接读容器内文件：
   ```bash
   docker exec l4d2-server cat /server/left4dead2/console.log | tail -100
   ```

## 关联
- [[l4d2-server-quick-reference]] — 管理速查
- [[l4d2-deployment-rules]] — 部署 checklist
