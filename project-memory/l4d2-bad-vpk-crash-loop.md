---
name: l4d2-bad-vpk-crash-loop
description: addons/ 下格式不被引擎识别的 VPK 导致服务器无限崩溃循环（CPackedStore 失败），含 core dump 排查全流程
metadata: 
  node_type: memory
  type: pitfall
  originSessionId: 866c8f85-5fab-4830-987f-ed0da0dcea7c
  modified: 2026-07-31T15:30:24.380Z
---

# L4D2：addons/ 坏 VPK → 无限崩溃循环（2026-07-31 实锤）

## 症状

- 服务器**每次启动都崩**：`Game_srv.so loaded` → `Server is hibernating` → 几秒内
  `Segmentation fault (core dumped)` → `Server restart in 10 seconds` 无限循环
- dmesg：`segfault at 0 ... error 6 in engine_srv.so`，反汇编是 `mov [0x0], 0xDEADBEEF`
  （Valve 引擎**断言失败的死亡写法**，不是随机损坏）
- 与任何插件/配置无关：禁 PTG、删 maps vpk、改 fd 限制、换 steamclient.so 全无效

## 根因

**`addons/` 目录下存在一个引擎解析不了的 VPK**。引擎启动时
`FileSystem_UpdateAddonSearchPaths()` 扫描 addons/ 所有 vpk → `AddVPKFile` →
`CPackedStore` 构造失败 → `Error()` → 引擎自杀。

本次元凶：**用 Valve `vpk -c` 工具打出来的 bf_sounds.vpk（510B）引擎不认**。
22:46 放进 data/addons/，22:56 首次重启才触发扫描 → 崩溃循环。⚠️ **不要在
addons/ 放非原版三方图的 vpk**（三方图 vpk 都是官方工具/原版打包，引擎兼容）。

## 排查流程（core dump 全链路，可用复用）

1. **dmesg** 确认崩溃模式（engine_srv.so + DEADBEEF = 引擎自杀）
2. **core_pattern 坑**：宿主 `/proc/sys/kernel/core_pattern` 是
   `|/usr/share/apport/apport ...`（pipe）→ **容器（Rocky Linux）里没有 apport**
   → core 直接丢失，`(core dumped)` 是 srcds_run 的假象
3. 临时改 `sysctl -w kernel.core_pattern='/tmp/core.%e.%p'`（容器 /tmp，louis 可写）
   → 等一次崩溃 → `docker cp l4d2-server:/tmp/core.srcds_linux.XXX /tmp/`
   → **改完必须恢复原 pattern**（apport 那串）
4. 拷库补符号：`docker cp l4d2-server:/home/louis/l4d2/bin/engine_srv.so` 等
   （engine_srv.so 在 `bin/`，不是 left4dead2/bin/；容器无 find/gdb/which）
5. `gdb -c core -ex 'set solib-search-path /tmp/libs' -ex 'bt 30'`
   → 栈底 `CPackedStore → AddVPKFile → FileSystem_UpdateAddonSearchPaths →
   Host_Init` → **直指 addons/ 坏 vpk**

## 关联

- [[l4d2-bf-killfeedback]] — 元凶 bf_sounds.vpk 来源（VPK 分发路线最终失败）
- [[l4d2-deployment-rules]] / [[l4d2-map-switch-pitfalls]] — 部署纪律
- 服务器恢复后：entrypoint 已改为跳过 steamcmd（L4D2 停更，用户同意关闭更新）；
  compose 加 ulimits 65535（无害保留）；maps 挂载纠正为 data/maps 直挂。

## 同夜第二个坑：steamclient.so 回滚导致 Steam 登录卡死（Localizer 后无输出）

vpk 删除后服务器不再崩，但卡在 Localizer [203/210]（SM 不加载、RCON 空）。
误以为是 steamclient 版本问题（崩溃循环时的怀疑）→ 把 .steam/sdk32 链接从
linux32/steamclient.so（steamcmd 更新的新版）改指向镜像 May 19 旧版 →
**更卡**（Steam 登录永远挂起）。恢复新版链接 → "Connection to Steam servers
successful." 立即通过。

**教训**：steamcmd 更新 steamclient.so 是为了适配 Valve 当前 Steam 后端，
**别回滚**；崩溃循环时它无罪（真凶是 vpk）。判据：崩溃=进程死（看 dmesg/bt），
卡死=进程活无输出（看 Steam 登录/网络），两者排查方向不同。

## 同夜第三个坑：RCON 假死现象

auth 无响应但 RCON 实际正常（错误密码有拒绝响应）。正确密码重连即通。
RCON 排查先发错误密码测连通性，别被一次空响应误导。
