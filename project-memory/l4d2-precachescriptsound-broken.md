---
name: l4d2-precachescriptsound-broken
description: L4D2 Linux 专用服务器 PrecacheScriptSound 全返回 false（连自带脚本），sound.cache 字典机制与地图 VPK 的关系
metadata: 
  node_type: memory
  type: pitfall
  originSessionId: c491550d-af6d-47f3-9199-7c36c747789b
  modified: 2026-07-31T13:30:13.362Z
---

# L4D2 Linux 服：PrecacheScriptSound 坏 + sound.cache 字典机制

## 核心发现（2026-07-31 sm_bf_test 实测）

**`PrecacheScriptSound()` 在本服 L4D2 Linux 构建（left4devops 镜像）上对一切名字返回 false**：
- 游戏自带脚本 `Player.Jump`、`Weapon_Pistol.Single` → **FAIL**
- 自定义脚本 `BfKill.SI_Kill` → **FAIL**
- 而 `PrecacheSound("battlefield/si_kill.mp3", true)`（文件路径）→ **OK**

→ 别用 PrecacheScriptSound 做诊断或验证，结果恒 false 无信息量。**文件路径 + PrecacheSound 才是正道**。

## sound.cache 字典机制（地图音效为什么能响）

- L4D2 引擎把**各搜索路径的 sound.cache 合并**成音效字典（启动日志：`String Table dictionary for soundprecache ... only found 9712 of 19098 strings`）
- **每个三方图 VPK 都内置 `sound/sound.cache`**（二进制格式，含每个 wav 前 125ms 预载数据）—— 这就是自定义地图音效工作的机制
- 引擎按文件路径 PrecacheSound 时**服务端不需要 cache**（实测）；但**客户端播放必须有 cache 条目**（2026-07-31 实测闭环，见 [[l4d2-sound-cache-pitfall]]）
- `snd_buildsoundcachefordirectory` 是**客户端**命令，专用服务器上不存在
- 游戏本体：`update/pak01_*.vpk`（真实 VPK，目录树在 `pak01_dir.vpk`）；`left4dead2/pak01_*.vpk` 是 VTF 假文件，别去解剖
- L4D2 无 game_sounds_manifest.txt（自动枚举 `scripts/game_sounds*.txt`），但松散文件是否加载存疑——不要依赖

## 正确做法

第三方音效（MP3/WAV 均可，实测 MP3 通）：
1. 文件放 `sound/xxx/`
2. 插件 OnMapStart：`AddFileToDownloadsTable("sound/xxx/file.mp3")` + `PrecacheSound("xxx/file.mp3", true)`
3. 事件里 `EmitSoundToClient(client, "xxx/file.mp3", SOUND_FROM_PLAYER, SNDCHAN_STATIC, ...)`
4. FastDL（sv_downloadurl + nginx）分发文件给客户端
5. **分发迷你 sound.cache**（客户端构建，只含自定义条目）→ 客户端下次启动合并后才有声（见 [[l4d2-sound-cache-pitfall]]）

## 关联

- [[l4d2-bf-killfeedback]] — 战地击杀反馈 v4.2.0（本发现的应用）
- [[l4d2-sound-cache-pitfall]] — 旧结论已修正
- [[l4d2-custom-sound-format]] — MP3/WAV 结论已修正
