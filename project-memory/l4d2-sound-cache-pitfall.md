---
name: l4d2-sound-cache-pitfall
description: sound.cache 定论：服务端路径 precache 不需要它；客户端播放自定义音效必须有条目（2026-07-31 实测闭环），引擎不自动构建、别手搓
metadata: 
  node_type: memory
  type: pitfall
  originSessionId: c491550d-af6d-47f3-9199-7c36c747789b
  modified: 2026-07-31T15:30:40.098Z
---

# L4D2 sound.cache 定论（2026-07-31 三次修正，最终版）

> 修正链：~~"cache 过期导致失败，必须删除重启"~~ → ~~"路径 precache 完全不需要 cache"~~ →
> ~~"客户端播放必须有条目"~~ → **最终定论：客户端播放 mp3 自定义音效不需要
> sound.cache 条目**（2026-07-31 深夜：用户删掉本地 sound.cache 后 BF 击杀音效
> 依然正常；mp3 文件存在 + 服务端 PrecacheSound string table 下发即可播）。
> 之前"构建 cache 能听"的实测有混淆变量（构建动作同时让 mp3 文件到位）。

## 最终事实

1. **客户端播放 mp3 自定义音效：不需要 sound.cache**；前提是 mp3 文件在本地
   （FastDL 分发）+ 服务端 `PrecacheSound("路径.mp3", true)`（string table 下发）
2. sound.cache 的作用：wav 预载数据（125ms）与音效字典合并——对 mp3 无实际价值
3. 引擎不会自动构建 cache；`snd_buildsoundcachefordirectory` 是客户端命令
4. **服务器侧无法把 cache 分发给客户端**（三连失败见 [[l4d2-bf-killfeedback]]：
   loose 被地图 VPK 遮蔽 / addons/ 被客户端拒绝 / maps/ 会崩服务器）
5. 二进制格式：20 字节头 + `[path\0][7×uint32][\0]` 记录；**别手搓**
6. 客户端无 mp3 时：进服自动下载（下载表 + FastDL 200）；有破损残留文件时会跳过
   （见 [[l4d2-sv-allowdownload-pitfall]]，删掉重下）

## 自定义音效标准管线（含 cache 分发）

1. 文件 → `sound/xxx/`
2. OnMapStart：`AddFileToDownloadsTable("sound/xxx/file.mp3")` + `PrecacheSound("xxx/file.mp3", true)`
3. 事件：`EmitSoundToClient(client, "xxx/file.mp3", SOUND_FROM_PLAYER, SNDCHAN_STATIC, ...)`
4. FastDL 分发文件
5. **分发迷你 sound.cache**（客户端从只含自定义文件的目录构建，几十 KB）→ 放 `data/sound/sound.cache` → `AddFileToDownloadsTable("sound/sound.cache")`（OnPluginStart 热载覆盖 + OnMapStart）→ 客户端下次启动合并生效
6. ⚠️ 别分发对游戏根目录构建的全量 cache（几 MB，且与其他客户端本地 VPK 条目冲突）

## 关联

- [[l4d2-bf-killfeedback]] — 应用实例（v4.2.1）
- [[l4d2-precachescriptsound-broken]] — 字典机制详解
- [[l4d2-custom-sound-format]] — 格式结论
