---
name: l4d2-bf-killfeedback
description: 战地击杀反馈插件 — 音效链路已闭环：客户端必须有 sound.cache 条目才能播放（2026-07-31 玩家实测听到）；v4.2.1 待部署分发迷你 cache
metadata: 
  node_type: memory
  type: project
  originSessionId: c491550d-af6d-47f3-9199-7c36c747789b
  modified: 2026-07-31T16:40:29.209Z
---

# L4D2 战地击杀反馈插件（最终结论：客户端不需要 sound.cache！）

> **✅ 实测通过（2026-08-01 00:37）**：用户进服实测两个音效均正常播放；
> nginx 日志实锤客户端全量下载两文件（171.213.246.40, 200, 11328/19270
> bytes）。闭环：precache 8/8 → FastDL 200 → 客户端下载 → 播放有声。
>
> **v4.4.0 已部署（2026-08-01 00:34 重启）**：小僵尸击杀音效定稿为 **CS:GO 原版音效**
> （sourcesounds/csgo 仓库提取）：普通击杀 = `player/headshot2.wav` →
> `battlefield/csgo_kill_common.mp3`（0.68s）；爆头击杀 = `player/headshot1.wav` →
> `battlefield/csgo_kill_headshot.mp3`（1.18s）。双通道 cvar：
> `bf_kill_sound_common` + `bf_kill_sound_common_hs`（默认开启，不再是空=关）。
> 特感（SI/Tank/Witch/近战）仍用 BF 音效。precache 8/8 全绿。
>
> 音效来源踩坑链（2026-08-01）：CS2 原版 kill_doof（用户否）→ CS2 工坊
> Hit/Kill feedback 3694967915（steamcmd 匿名 No match 拿不到；用户订阅后
> 找不到 VPK 未再跟进）→ cskillconfirm 预设 bf1/bf1s/cf（cf 用户否，
> "csgo_low/high" 那对其实是瓦罗兰特风格，用户否）→ **sourcesounds/csgo
> （GitHub 1.7GB CS:GO 原版音效全量提取）逐层浏览 + 单文件 raw 下载** 命中。
> CS:GO 原版没有独立"普通击杀确认音效"，用 headshot2.wav 顶替。
>
> 部署注意：v4.4.0 需换图/重启才进下载表（地图快照）；cfg 已手动同步
> （AutoExecConfig 不覆盖已有值）。
>
> **状态（2026-07-31 深夜定论）**：**客户端播放 mp3 不需要 sound.cache 条目**——
> 用户实测：删除本地 sound.cache 后 BF 击杀音效依然正常。**mp3 文件存在 +
> 服务端 PrecacheSound string table 下发 = 客户端可播**。之前"必须有 cache 条目"
> 的定论（[[l4d2-sound-cache-pitfall]]）已被推翻（当时用户"构建 cache 能听"的
> 实验有混淆变量：构建 cache 的同时 mp3 文件也在本地）。
>
> **fufu 无声的真正原因：本地没有 mp3 文件**（nginx 日志里 6 个 mp3 的全部下载
> 记录都来自用户 IP 171.213.246.40；fufu 从未下载成功——可能从未连接成功过
> FastDL 或本地有破损残留文件，见 [[l4d2-sv-allowdownload-pitfall]]）。
> **修复：让 fufu 删除本地 `left4dead2\sound\battlefield\` 文件夹 → 完全重启
> 客户端 → 进服自动下载 6 mp3 → 有声**。
>
> **VPK 分发路线终局（三连失败，2026-07-31）**：
> 1. loose `sound/sound.cache` 分发 → 被地图 VPK 遮蔽（客户端本地"已有"），0 请求
> 2. `addons/bf_sounds.vpk` → 客户端忽略 addons/ 下载条目，0 请求；且**该 VPK 是
>    vpk 工具打的，服务器引擎启动扫描 addons/ 时解析失败 → 崩溃循环**
>    （[[l4d2-bad-vpk-crash-loop]]，2 小时宕机事故）
> 3. `maps/bf_sounds.vpk` → 引擎扫描 maps/ vpk 的风险（未实测，放弃）
> **结论：服务器侧无法分发 cache/VPK；客户端只要 mp3 文件 + 服务端 precache。**

## 部署纪要（2026-07-31 22:29）
>
> **部署纪要（2026-07-31 22:29）**：
> - 用户提供 395B 迷你 cache base64 → 解码验证 6 条 battlefield 条目
> - **发现并修复错拼**：cache 里 melee 条目路径是 `sound\battlelield\melee_kill.mp3`（客户端构建时扫到错拼目录）→ 原位等长替换为 `battlefield`（11=11 字符，未动 CRC/结构，python bytes.replace）→ 必须修，否则插件 EmitSound `battlefield/melee_kill.mp3` 查字典 miss，近战音效不响
> - 编译部署 v4.2.1 → RCON reload → `sm plugins info` 确认 running、22:29:25 precache 6/6、日志零错误
> - 已删 `battlefield_src.zip`
> - 遗留：用户本地 `C:\bfsounds\sound\` 下可能有错拼的 `battlelield\` 目录，已提醒删除（否则下次重建 cache 再带出）
>
> **rcon_cmd.sh 的坑**：长响应（如 `sm plugins list`、reload 回显）被 SRCDS 拆多包，脚本只收第一包 → 显示空。短命令（`sm version`）正常。验证插件状态用完整收包脚本（循环 recv 到 timeout 合并 body）或看 SM 日志。

## 最终根因（"两年不响"完整链条）

1. **客户端播放自定义音效必须有 sound.cache 条目**（Valve 官方机制；引擎不自动构建，须 `snd_buildsoundcachefordirectory` 手动构建 + 重启客户端合并）
2. 服务端 `PrecacheSound("path.mp3", true)` 不需要 cache —— 之前"不需要 cache"的结论只对服务端成立
3. 叠加因素：cfg 陈旧值（AutoExecConfig 不覆盖已有 cfg）、FastDL 分发链、PrecacheScriptSound 在本 Linux 构建恒坏（[[l4d2-precachescriptsound-broken]]）

## 版本史

| 版本 | 方案 | 结果 |
|------|------|------|
| v3.5.1 | WAV + PrecacheSound + HUD | 无声 |
| v4.0.0 | MP3 + PrecacheSound | cfg 陈旧值失配 |
| v4.1.x | MP3 + 音效脚本 | PrecacheScriptSound 恒坏 |
| v4.2.0 | MP3 + 路径 PrecacheSound | 服务端全通，客户端缺 cache 条目无声 |
| **v4.2.1** | + 分发 `sound/sound.cache`（OnPluginStart + OnMapStart），删 sm_bf_check 调试命令 | **2026-07-31 22:29 已部署** ✅ |

## 部署（热更新，不重启服务器）

```bash
# ① 迷你 cache → data/sound/sound.cache（FastDL 自动可下载）
# ② 编译
cd /opt/gameservers/l4d2/data/addons/sourcemod/scripting
bash compile.sh l4d2_bf_killfeedback.sp
cp compiled/l4d2_bf_killfeedback.smx ../plugins/
# ③ RCON: sm plugins reload l4d2_bf_killfeedback
# ④ 清 data/sound/battlefield_src.zip（传输用，已无用）
```

## ConVar（v4.2.0 不变）

```
bf_kill_enabled 1 / bf_kill_volume 0.8 / bf_kill_cooldown 0.1
bf_kill_sound_si battlefield/si_kill.mp3
bf_kill_sound_headshot battlefield/si_headshot_kill.mp3
bf_kill_sound_tank battlefield/tank_kill.mp3
bf_kill_sound_witch battlefield/witch_kill.mp3
bf_kill_sound_melee battlefield/melee_kill.mp3
bf_kill_sound_common_hs (空=关)
```

## 关联

- [[l4d2-sound-cache-pitfall]] — cache 定论（客户端播放必须有条目）
- [[l4d2-precachescriptsound-broken]] / [[l4d2-custom-sound-format]] — 同步修正
- [[l4d2-sv-allowdownload-pitfall]] — FastDL
- 后续方向：击杀 HUD（战地1 风格）；PLUGINS.md 2026-07-29 曾规划"音效归击杀 HUD 统一管理"
