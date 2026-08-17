---
name: l4d2-long-session-steam-crash-loop
description: 三方图终章切 c1m1 卡死 = 长会话 Steam 管道劣化 + 崩溃循环不自愈；9 次崩溃规律 + 修复三件套
metadata: 
  node_type: memory
  type: project
  originSessionId: 5be35f9c-4bd1-4964-844a-12957f123a97
  modified: 2026-08-04T15:51:23.118Z
---

# L4D2 长会话 Steam 劣化崩溃循环（2026-08-04 定位）

> 用户报障："三方图终章打完切回 c1m1 会卡死"。

## 现象 ≠ 切图 bug

campaign_transition 切图本身正确（单发 changelevel、c1m1 正常加载）。真因是**容器内 Steam 客户端运行时管道劣化**：

- 服务器匿名登录（**GSLT 在 server.cfg 被注释**："not registered at early exec (Unknown command); anonymous+VAC works"）
- 长会话（健康寿命 ~10-11h）+ 30+ 次切图后 steamclient 管道断裂
- 前期症状：STEAMAUTH failure（code 1/6/8）→ "No Steam logon" 踢人（25h 内 13 次）
- 终章切图是压垮点：全员断线重连 + downloadables 重建 + precache 高峰撞上劣化态
- 崩溃后 srcds_run 无限容器内重启，但 Steam 运行时已坏（每次 `SteamAPI_Init() failed; create pipe failed` + `Assertion Failed: Async I/O on closed handle 81`）→ **只有整容器重启能恢复**（重启后出现 `Connection to Steam servers successful`）

## 崩溃时间线（同容器 9 次，2026-08-03~04）

- 08-03 22:51：天梯 hls_20 → c1m1 后 6 分钟崩（与 08-04 同签名）
- 08-03 22:51→00:29：5 连崩循环（2.5h 无人管，手动重启才恢复）
- 08-04 10:01 + 10:02（19s 间隔双崩）
- 08-04 21:12-21:13：南宁 m6 终章 → c1m1 → 21:12:49 青杉丶 STEAM 拒连 → 21:13:42 崩 → 21:13:49 手动重启恢复

## 排除项

- invalid counterterrorist spawnpoint / "String Table should be rebuilt" / Unknown command 公告 spam：**每个会话每张图都出现，正常**（含重启后健康会话）
- "Unknown command 24/[6/]" = 主机名「粟藜24人…[6特]」UTF-8 拆分执行，正常
- 双 changelevel：sm_l4d_fmc_ChDelayCOOP_final 0.0 生效，无双切
- fd 用量：当前会话 87/65535 正常（07-31 ulimit 修复只治 fd 数，没治 Steam 管道）

## 修复三件套（2026-08-04 拟定）

1. **✅ 已部署（08-04 23:48）每日定时重启**：`/usr/local/bin/l4d2-daily-restart.sh` + `/etc/cron.d/l4d2-daily-restart`（每日 04:00 root）。保护逻辑：`Players:` 最后一行 >0 或近 60 行有 `shop-buy` 则跳过。已实测：脚本执行 → docker restart → 新会话健康（MaxCommon + SCM 轮换活跃）。重启后回 +map c1m1_hotel。日志 `/var/log/l4d2-restart.log`。
2. **崩溃自愈**：entrypoint-wrapper 加崩溃计数，≥2 次/5min 退出 → docker restart 策略接管（全新 Steam 运行时）
3. **GSLT 启用**：server.cfg early exec 不注册 → 改 SourceMod autoexec `sm_cvar sv_setsteamaccount "F18404622EF86F67F587566BBC9350F5"`（引擎注册后执行）；GSLT 会话比匿名稳

## 备注

- `[S_API FAIL] SteamAPI_Init() failed; create pipe failed` **每次启动都出现**（镜像 steamclient fallback 噪音，21:13:49 健康重启同样有），健康信号是 `Connection to Steam servers successful` + SM 日志 MaxCommon
- docker logs 有 stdout 缓冲显示延迟（tail 可能被 Unknown command 噪音占满），判健康以 SM 日志文件为准

## 关联

- [[l4d2-docker-migration]] — No Steam logon 的镜像迁移修复（未根治）
- [[l4d2-map-switch-pitfalls]] — String Table 损坏修复 = docker restart（同源）
- [[l4d2-gslt-pitfall]] — GSLT 放 server.cfg 的旧结论（现被 early-exec 注释推翻，需走 SM autoexec）
- [[l4d2-dont-touch-server]] — 玩家在玩时不动服务器
