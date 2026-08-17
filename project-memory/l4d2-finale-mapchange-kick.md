---
name: l4d2-finale-mapchange-kick
description: 终章打完全玩家被踢根因 — ForceChangeLevel 等同 map 命令踢人；终章引擎不自动过渡，campaign_transition 是唯一切图者；改用 changelevel 保留连接
metadata: 
  node_type: memory
  type: project
  originSessionId: 2766b83a-e4d2-4350-9a9c-16b53714cdbf
  modified: 2026-08-01T16:06:28.214Z
---

# L4D2 终章切图踢人坑（2026-08-01 修复）

> 用户实测："打完 c1m4 全被踢出去"、"根本没有轮询这走"（老问题，之前遇到过）。

## 根因

- **`ForceChangeLevel()` 是 `map` 命令等价物 → 踢掉所有客户端**（SM 文档明示）。
- **普通关过关不踢人**：L4D2 coop 关间过渡是引擎自动无缝（map_transition），插件不参与。
- **终章引擎不自动过渡**（战役结束）→ 轮询插件 `campaign_transition.sp` 是唯一切图者
  → 它的 `Timer_ChangeLevel` 用 `ForceChangeLevel` → 打完终章全员被踢回主菜单，
  观感 = "掉了/轮询没走"。
- 触发链：`finale_win` → 检查投票 → 官图按序取下一战役（c1→c2→…→c14→c1）/
  三方图 mapcycle.txt → 公告 → 8s → ForceChangeLevel(踢人)。

## 修复（2026-08-01，两处）

```c
// 旧（踢人）
ForceChangeLevel(nextMap, "...");
// 新（保留连接，客户端自动重连）
ServerCommand("changelevel %s", nextMap);
```

- `campaign_transition.sp`（终章轮询）——主修复
- `l4d2_campaign_progression.sp`（round_end reason=2 过关抢切，平时被引擎过渡
  覆盖但不该冒险）——预防性同修
- `l4d2_wipe_mapchange.sp`（团灭 4 次切图）本来就用 `changelevel` ✅ 未动

## 复发（2026-08-01 夜，23:46 实测）——真凶是 mapchanger 双刀

**2026-08-01 白天修复本身有效**（campaign_transition 已用 changelevel），但打完终章仍踢人。
实测证据（容器日志 23:46）：

```
23:46:05  Host_Changelevel → Mapchange to c3m1_plankcountry   ← campaign_transition 轮询 ✓ 正确
23:46:09  Host_Changelevel → Mapchange to c2m1_highway        ← sm_l4d_mapchanger ✗ 抢切
23:46:11  Dropped 时海 / Dropped 粟藜                         ← 重连被第二次切图打断 → 全部被踢
```

- **根因**：`sm_l4d_mapchanger.smx`（无源码）在终章完成 10s 后强制 changelevel 到
  `sm_l4d_fmc_def "c2m1_highway"`（cfg 第 39 行），与 campaign_transition 的轮询切图
  在 4-5s 内双重切图。白天"双 changelevel 同目标无害"只是 c1→c2 的巧合
  （c1m4 终章 → 下一战役恰好就是 c2m1_highway）。
- **当天已发生两次**：21:42:07 yama_5 终章 → nanningcity_bridge_m6 → 21:42:12 又切 c2m1_highway。
- **修复（已应用 3 处 cfg + RCON 热生效）**：`sm_l4d_fmc_ChDelayCOOP_final "0.0"`
  （config 注释明确 0=off，仅关终章强制切图）。
- **保留 mapchanger 团灭处理**：`sm_l4d_fmc_crec_coop_map/final "4"`（4 次团灭切图）
  —— 注意容器里 **l4d2_wipe_mapchange.smx 未部署**（只有 scripting/.sp），
  mapchanger 的 crec 是目前唯一的团灭处理，不能整插件禁用。
- 终章后的正确切图者是 campaign_transition（c2 终章 → c3m1_plankcountry，实测正确）。

## 播报矛盾排查 + 轮询策略变更（2026-08-02，v1.3）

**谁在播报"下一张图"（全服 4 处）**：
- `campaign_transition` — `[战役结束] 下一官方战役/三方图: X`（终章，唯一轮询源）
- `sm_l4d_mapchanger` — `[TS] 下一张图 Next Map: c2m1_highway` + `[TS] 还剩余 X 次机会挑战`
  （announce=1 已关 → 0）；团灭播报 "团灭次数已达 X 次，正在更换下一张地图" 实际跳回 c2m1 是文案误导
- `basetriggers` `!nextmap` — 引擎 nextmap（mapcycle.txt 首个 = nanningcity_bridge_m6），与轮询无关
- `l4d2_vote_manager3` — `Called vote has passed!`（投票通过，不带图名）
- 矛盾实例：23:46 终章 [战役结束] 说 c3m1，[TS] 说 c2m1，实际切 c2m1 → 播报打架 + 踢人

**轮询策略（用户定案 v1.3）**：任何三方图终章打完 → 自动切回 `c1m1_hotel` → 官图轮询
（c1→c2→…→c14→c1）。废弃 mapcycle.txt 三方图连转。播报文本：
"三方图战役结束，切回官方战役: c1m1_hotel"。
SM convar 值缓存会让重载后的版本号 cvar 显示旧值，以 `sm plugins list` 为准（v1.3 已确认加载）。

## 教训

- **任何插件切图一律 `ServerCommand("changelevel %s")`**，`ForceChangeLevel`/`map`
  = 踢人（[[l4d2-deployment-rules]] 铁律 9 的插件版）。
- 终章后的地图切换必须由插件做（引擎不管），所以这个坑只在终章暴露。
- 三插件分工：campaign_transition（终章轮询）/ campaign_progression（关间防呆，
  实际冗余）/ wipe_mapchange（团灭）。Force Mission Changer（sm_l4d_mapchanger，
  无源码）也监听终章/团灭，目标同为 sm_l4d_fmc_def c2m1_highway，双 changelevel
  同目标无害。

## 关联

- [[l4d2-deployment-rules]] — 铁律 9：禁止 map 命令
- [[l4d2-map-switch-pitfalls]] — 切图系统性缺陷
