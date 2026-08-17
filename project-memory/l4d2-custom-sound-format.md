---
name: l4d2-custom-sound-format
description: 修正：L4D2 自定义音效格式并非 WAV 被拒——真凶是客户端 sound.cache 条目缺失 + 客户端分发断裂 + cfg 陈旧（2026-07-31 实测闭环）
metadata: 
  node_type: memory
  type: pitfall
  originSessionId: c491550d-af6d-47f3-9199-7c36c747789b
  modified: 2026-07-31T13:30:16.791Z
---

# L4D2 自定义音效格式结论修正（2026-07-31）

> ⚠️ **旧结论作废**：~~"WAV 被拒必须 MP3"~~ 是社区传闻误判。本服实测 MP3 文件路径 PrecacheSound 成功，但没有证据证明 WAV 会被拒——地图 VPK 里全是 WAV（deadcity2 等），地图音效正常工作。

## 修正后的结论

**音效不响的真凶从来不是格式**，完整链条（2026-07-31 实测闭环）：
1. **客户端 sound.cache 里没有条目**（最终真凶——客户端播放必须有条目，服务端 precache 不需要；引擎不自动构建，见 [[l4d2-sound-cache-pitfall]]）
2. **客户端拿不到文件**：sv_allowdownload 废弃（Valve 2021+）→ 必须 FastDL + AddFileToDownloadsTable
3. **插件 cfg 陈旧值**（AutoExecConfig 不覆盖已有 cfg，版本升级后 cvar 值失配）

## 仍有效的部分

- MP3 44100Hz CBR 128kbps 在本服验证可用（v4.2.0 服务端 precache OK，待客户端实测）
- **工作管线**（v4.2.0 实证）：
  1. 音效 → `sound/xxx/`
  2. OnMapStart: `AddFileToDownloadsTable("sound/xxx/file.mp3")` + `PrecacheSound("xxx/file.mp3", true)`
  3. 事件: `EmitSoundToClient(client, "xxx/file.mp3", SOUND_FROM_PLAYER, SNDCHAN_STATIC, ...)`
  4. FastDL (sv_downloadurl + nginx) → 客户端自动下载
  5. **分发迷你 sound.cache**（客户端构建）—— 客户端播放的最后一块拼图（[[l4d2-sound-cache-pitfall]]）

## 关联

- [[l4d2-bf-killfeedback]] — v4.2.0 应用此管线
- [[l4d2-precachescriptsound-broken]] — 实测依据
- [[l4d2-sound-cache-pitfall]] — 同步修正
- [[l4d2-sv-allowdownload-pitfall]] — FastDL
