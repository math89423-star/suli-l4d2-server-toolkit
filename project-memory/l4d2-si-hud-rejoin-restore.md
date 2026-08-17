---
name: l4d2-si-hud-rejoin-restore
description: si_hud v1.10.0：废除断线时间窗，同战役重连一律恢复钱包/复活币；团灭回滚当刻同步存档
metadata: 
  node_type: memory
  type: project
  originSessionId: e9b69645-b8e7-4ae4-a758-a0fe73204a59
  modified: 2026-08-12T14:31:57.390Z
---

# si_hud v1.10.0 重连恢复（2026-08-04 部署）

**症状（user 实测恶劣 bug）**：本章战役中买了复活币、打了大量积分，游戏错误退出后重进 → 复活币回 start、积分清 0。

**根因**：`OnClientPostAdminCheck` 的 v1.7.43/v1.8.2 断线记录时间窗——同图重连仅 20s（防带旧钱）、换图 180s。游戏错误退出后重连必然超窗（重开客户端 >20s）→ 被判"新加入"→ 0 + start 币。

**修复（v1.10.0）**：
1. **废除时间窗**：进服一律 `ScoreLoad_Player(client)`——同战役存档恢复，跨战役/无存档 = 新玩家默认（v1.7.31 规则不变）。存档战役校验在 ScoreLoad_Player 内（KeyValues 的 "campaign" 字段 vs 当前 GetMapPrefix）。连带修复：服务器重启（断线记录随内存丢失）后同战役重进也丢钱的问题。
2. **团灭带旧钱漏洞封堵**：原 20s 窗口防的是"团灭前离场 → 重开后来回恢复回滚前的钱"。`Event_RoundStart` 回滚（RestoreScoreState）后立即 `ScoreSave_All()` 同步存档（60s 周期保存的空窗归零）。
3. 删除 g_sDiscAuth/g_fDiscTime/g_sDiscMap 三变量及记录逻辑。

**存档文件**：`addons/sourcemod/data/si_hud_scores.txt`（KeyValues，按 SteamID；wallet/coins/campaign）。保存时机：断线 / OnPluginEnd / 60s 周期（仅写 IsClientInGame 玩家，空服 mtime 不变属正常）/ 新战役清零后 / 团灭回滚后。

**遗留**：pre-v1.7.40 存档无 "campaign" 字段 → 空串走恢复分支（旧行为，未改）。si_hud_version convar 热重载后保留旧 def 值（SM convar 孤儿），整机重启后重建。

## v1.11.0 战役键体系（2026-08-04，推翻 v1.10.1 三方轮换豁免，待热重载）

### v1.11.1 GetMapPrefix 规则 3：中置数字关号自动识别（user 提议）

atr02_outskirts → "atr" / de01_sewers → "de" / l4d_sh01_oldsh → "l4d_sh"：数字前紧邻字母 + 数字段后是 "_<单词>" 或结尾 = 关号。atr 类"前缀+数字+下划线"多关战役无需进清单自动归组（atr01~atr04 全归 "atr"）。m<数字> 已先截断（dc2m1_riverside 不受影响）；"l4d" 的 4 后接字母不满足条件；deathttoiletmaze10_5 被规则 2 截断。清单仅兜底段名各异的例外（nanningcity）。已用全量已知图 Python 模拟验证无误判。



**user 改判**：三方图也要跨图清零——但三方图分大图小图：大地图（多图战役）战役内保留、换战役清零；小图（单图/无地图号标记）每次换图清零。官图规则不变（cXmY 战役内保留，m1/换战役清零）。

**⚠ 整体废弃（v1.13.0，2026-08-12，user 拍板）**：v1.11.0 战役键清零体系 + ScoreLoad_Player 战役校验全部移除——可用积分跨图永久保留，恢复一律放行（只钳上限 si_hud_wallet_max 30000），见 [[l4d2-si-hud-wallet-persistent]]。

**实现**：废弃 IsThirdPartyRotation()（含 current_mode.txt 判定与兜底①②），统一为**战役键 GetCampaignKey()**：
- 官图命名 → GetMapPrefix（"c1"）
- 三方图大地图 → 新配置 `configs/si_hud_big_maps.txt` 清单键（dc2/dw/de/hls/nanningcity = 轮换链战役 + 南宁（南宁各关段名不同必须归并）；匹配 = 图名以 前缀+_ / m<数字> / 结尾 开头，防 "de" 误配 deathttoiletmaze10_5）
- 三方图有地图号标记（m<数字>/尾 _<数字>）→ 前缀即战役键（zc1_m1→"zc1"、nanningcity_bridge_m6→"nanningcity_bridge"）
- 无标记 → 整图名即战役键（换图必清）

**OnMapStart 清零** = 战役键变化 或（有战役键的图名含 m1 = 战役起点/同键循环重开 dc2m6→dc2m1、c2m5→c2m1）。**ScoreLoad_Player 校验**同步走战役键（移除豁免——豁免会放行离线玩家跨图旧钱，正是清零语义的漏洞）；兼容旧存档：旧 GetMapPrefix 值仅当等于当前图前缀时放行（同图重连不丢钱）。清单文件每图读一次，改清单无需重载插件。

**部署验证（2026-08-04 16:28 热重载）**：sm plugins reload 后 `sm plugins info l4d2_si_hud` Version=1.11.1 ✓（si_hud_version cvar 仍显示旧值 = 已知 cvar 残留坑，看 plugins info 才准）。玩家随后切到 c1m1（官图）触发清零写档 wallet=0 campaign=c1 = 跨战役语义正确 ✓。

**事件复盘（user 报"换图后可用积分没了"）**：真相是 14:29:47 换 zc1_m1 时被清——服务器 10:02 启动跑的还是 v1.10.0（无三方豁免 + zc1_m1 含 m1 必清），v1.10.1 是 14:30 才 reload 生效（14:30:06 rotation-debug 日志实证）。之后 atr01→atr05 全程豁免不清（存档 wallet 2622 为证）。教训：**服务器跑的是启动时加载的 smx，smx 文件 mtime ≠ 生效时间**——部署要查 sm plugins info / reload 日志，不能看文件时间。

## v1.10.1 三方图轮换跨图保留（2026-08-04 部署，⚠ 已被 v1.11.0 废弃）

**症状**：三方图轮换表每张图命名前缀各异（nanningcity_bridge_m6 / zc1_m1 / l4d_yama_1 / desastre_1a / hls_15...），换图必变前缀 → 误判"新战役"清零，轮换时攒的分和币全丢。

**修复**：`IsThirdPartyRotation()`（定义在 GetMapPrefix 后，forward 声明需 public）：
- 权威标记 `configs/current_mode.txt`（switch-to-official.sh 写 official / switch-to-custom.sh 写 custom）
- 兜底②：标记 official 但当前图非官图命名（c<数字>m<数字>，IsOfficialStyleMap）→ 手动 sm_map 切三方图未跑脚本的滞后状态也按三方图轮换
- 兜底①：文件缺失/异常 → 地图命名判定
- custom 模式跳过 OnMapStart 新战役清零 + 豁免 ScoreLoad_Player 存档战役校验（重连恢复不被前缀拒绝）
- ⚠ custom 轮换表里的 c3m1_jungle 是官图命名 → 只有文件=custom 时才豁免；文件缺失时按官图清（保守）

**实测矩阵**（2026-08-04 临时 debug 日志验证后移除）：6 场景全对——三方图×2（official/custom 标记）thirdParty=1、官图 m1×2 thirdParty=0 清零、lab_map_03（标记滞后）thirdParty=1。

相关：[[l4d2-si-hud-mapchange-wallet-clear]]、[[l4d2-si-hud-scoring]]、[[l4d2-source-code-location-pitfall]]
