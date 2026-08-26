---
name: l4d2-scoreboard-ui-project
description: UI 常驻得分榜项目——架构定稿(Marttt scripted_hud 渲染 + scoreboard_ui 喂食)、全量踩坑记录、当前暂停状态与复活步骤
metadata:
  node_type: memory
  type: project
  modified: 2026-08-26
---

# UI 常驻得分榜（scoreboard_ui 项目）

## 状态：**暂停（已禁用）** — 渲染链路未在真机达成预期，插件归档待续

- `l4d2_scoreboard_ui.smx` / `l4d2_scripted_hud.smx` 均移入
  `left4dead2/addons/sourcemod/plugins/disabled/`，换图不会自动加载
- 复活：`cp disabled/l4d2_scoreboard_ui.smx disabled/l4d2_scripted_hud.smx plugins/`
  → RCON `sm plugins load l4d2_scripted_hud` → `sm plugins load l4d2_scoreboard_ui`
- **保留生效**的副产品：score_core v1.13.7 榜单 API、shop v1.16.5 加载修复

## 架构定稿（用户拍板"先用人家的插件再慢慢改"）

```
l4d2_scripted_hud (Marttt 原版 v1.0.2 + 2处补丁)  ← 渲染层, 0.1s 全量重写4槽
l4d2_scoreboard_ui (自研 v1.1.0)                  ← 数据层, 每秒把榜单写入渲染层的 text cvar
l4d2_score_core (v1.13.7)                         ← 账本单源, SH_ 只读 native 输出
```

槽位映射：HUD1=标题 `[得分榜 TOP3] 共N人`，HUD2..4=`#N 名 分/特x/杀x`。
⚠ 4 个 text cvar 必须全部占住（空值会触发渲染层预定义内容串台：
HUD2=幸存者血量/HUD3=Tank 血量）。禁用/无数据时写 `"-"` 占位。

## 已交付成果（本次会话）

| 文件 | 说明 |
|---|---|
| `scripting/l4d2_score_core.sp` v1.13.7 | 新增 SH_GetRoundScore/SIKills/CommonKills/FFDamage/Blacked 只读 native |
| `include/l4d2_score_core.inc` | API 契约同步 |
| `scripting/l4d2_scoreboard_ui.sp` v1.1.0 | 喂食器（排序口径同 !rank：积分>特感>击杀） |
| `scripting/l4d2_scripted_hud.sp` | Marttt 原版 vendored + 2 补丁（见下） |
| `include/witch_and_tankifier.inc` | 空 stub（原版 include 引用但不用，编译需要） |
| `cfg/sourcemod/l4d2_scripted_hud.cfg` | 四槽布局固化（**纯 ASCII 注释**，原因见坑⑤） |
| `l4d2_shop.sp` v1.16.5 | 加载顺序修复（见坑⑦） |

scripted_hud 两处补丁（源码内 [suli] 注释标记）：
1. `CVAR_FLAGS FCVAR_NOTIFY` → `0`——text cvar 被每秒喂值，NOTIFY 会全服刷屏
   "服务器 xxx 参数改为 yyy"
2. 启用 `AutoExecConfig(true, CONFIG_FILENAME)`——不启用则换图/重载布局打回
   编译默认值（本镜像构建 hud3_team 默认=2 仅感染者可见 → #2 行消失）
3. AskPluginLoad2 增加 MarkNativeAsOptional(IsStaticTankMap/WitchMap)
   （witch_and_tankifier 未装时允许加载；运行时已有 LibraryExists 守卫）

## 技术结论（实测证据，重启项目前必读）

① L4D2 **不支持 SM 的 ShowHudText/HudSync**，常驻屏幕文字唯一正路 = EMS HUD
② EMS 写法两条路：VoiceViewer 的按 element 写（`SetPropString(...,true,slot)`）
   在本服实测只出底框不出字；**Marttt 的整串协议可行**——每槽文本尾补 127 空格、
   四槽 ImplodeStrings 合一、单次不带 element 写入
③ 字符串写入必须 `changeState=true`，否则客户端永远停在旧内容（v1.0.3 实测）
④ **flag 类变更需客户端重连才刷新**（布局快照连接时下发）；反复热调试时
   用户客户端会积累脏状态，表现为"参数对了但不显示/缺行"
⑤ SourceMod 的 cfg exec 解析器遇 **UTF-8 中文注释会中断执行**（后半段 cvar
   不生效）——autoexec cfg 必须纯 ASCII
⑥ 本镜像构建怪癖：hud3_visible 默认 0、hud3_team 默认 2，与官方帖文档不符；
   布局值必须落 cfg 固化
⑦ **跨插件 native 必须逐个 MarkNativeAsOptional**（消费方 AskPluginLoad2），
   否则换图加载顺序一变就硬失败。本次连续踩两次：
   - shop 缺 SH_GetWallet/SH_AddWallet 标记（score_core 改名改变 readdir 顺序暴露）
   - v1.16.3 新增 ShopFlare_Clear/AerialFlare_Cancel 漏标（"Depends on plugin:
     l4d2_shop_flare.smx" 加载失败）
   运行时守卫模式：GetFeatureStatus(FeatureType_Native,"X")==Available 再调用

## 暂停时的遗留问题（复活时优先查）

- 真机四行显示未达成：喂食器数据确认到位（hud2_text="#1 粟藜 2492分/..."），
  但用户端仍只见部分行。怀疑方向：客户端布局快照脏（需彻底重连验证）、
  TOP 区域槽位(LEFT_TOP/MID_TOP)被游戏自身 UI 遮挡（可试全放 BOTTOM 两槽 +
  \n 双行）、或 EMS 与客户端 neko mod 冲突
- sui_text_override cvar 是诊断利器：非空时绕过榜单直接上屏（测字体/槽位）

相关：[[l4d2-git-repo]] [[l4d2-si-spawn-hardgate-softscore-v6]]
