---
name: l4d2-gslt-pitfall
description: sv_setsteamaccount 命令行导致 srcds 卡死，必须放 server.cfg
metadata: 
  node_type: memory
  type: project
  tags: 
    - l4d2
    - server
    - gslt
    - steam
    - pitfall
  originSessionId: d974aa0e-5cab-4307-a298-321da3d6f3ef
  modified: 2026-08-01T08:33:19.268Z
---

# L4D2 GSLT 配置坑

## 症状

`+sv_setsteamaccount TOKEN` 放在 Docker 启动命令行 → srcds 在 Localizer 阶段卡死（停在 chat_english.txt 不动）。

## 原因

不清楚确切原因，可能是 srcds 在早期启动阶段调用 `sv_setsteamaccount` 时尝试 Steam 网络连接，阻塞了启动流程。

## 解决方案

**`sv_setsteamaccount` 放在 `server.cfg`**，不在命令行传：

```
sv_setsteamaccount "F18404622EF86F67F587566BBC9350F5"
```

`server.cfg` 在 srcds 启动后期由 `+exec server.cfg` 执行，此时游戏引擎已就绪，不会卡死。

## GSLT Token 获取

https://steamcommunity.com/dev/managegameservers → App ID 550（L4D2）

## 验证方法

启动后检查日志无 `Connecting anonymously`，且出现 `Connection to Steam servers successful`（GSLT 认证后不再走匿名登录）。

## left4devops 镜像实测（2026-08-01，引擎 2.2.4.3 build 2026-06-30）

server.cfg 里 `sv_setsteamaccount` 在启动早期 exec 报 **`Unknown command`**：引擎在网络栈就绪前执行 cfg，游戏模块 ConVar 尚未注册。同批 Unknown 噪音：sv_hibernate_when_empty / sm_cvar / sv_allowdownload / net_maxfilesize（最终值由 SourceMod 加载后补设，见 cfg/sourcemod/sourcemod.cfg）。

**实测匿名模式完全可用**：`Connection to Steam servers successful` + VAC secure + GetServersAtAddress 公网列表可见 + 玩家可搜到。**主服不需要 GSLT**，保持注释状态即可（注释必须纯 ASCII，中文注释会被引擎拆词报错）。

## 关联记忆

- [[l4d2-deployment-rules]] — 十条铁律
- [[l4d2-docker-migration]] — left4devops 镜像迁移
