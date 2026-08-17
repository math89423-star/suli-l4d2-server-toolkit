---
name: l4d2-no-vanilla-sounds
description: "L4D2 镜像服务端无任何原版音效数据 — VPK 解包时删除音效文件/脚本，pak01 vpk 是 VTF 垃圾文件；影响所有\"播放原版音效\"类需求"
metadata: 
  node_type: memory
  type: reference
  originSessionId: 66686e24-5284-42a1-b757-66a65ab1574a
  modified: 2026-08-02T10:07:56.172Z
---

# L4D2 服务端无原版音效数据（2026-08-02 调查实锤）

任何"播原版音效"的需求在**服务器侧都无法查证音效路径**——本镜像（left4devops）解包 VPK 时删除了所有原版音效。

## 证据

| 位置 | 状态 |
|------|------|
| `left4dead2/sound/` | 只有自定义音效（battlefield/cz/erasounds/music/music_new/unused/weapons），无原版目录（weapon_pain_pills 等） |
| `left4dead2/scripts/` | 无 game_sounds*.txt、无 soundscripts/（只有第三方图 soundscapes + melee/vscripts） |
| `pak01_*.vpk`（42 个） | **垃圾文件**：pak01_000.vpk 头部是 "VTF"（Valve 纹理头），pak01_dir.vpk 魔数 55AA1234 非标准 VPK，strings 无文件名 |
| `left4dead2_dlc1/2/3`、`left4dead2_lv` | 无音效目录；lv 里只有 media + 垃圾 vpk |

镜像实际布局：**VPK 内容已解包成明文树**（官图在 maps/c1m1_hotel.bsp 明文、models/materials 明文），服务端用不到的音效文件/脚本被整体删除。`left4dead2.dat`/`left4dead2.exe` 为 Windows 残留。

## 推论（对插件开发的意义）

- **服务端无法验证任何原版音效路径**（EmitSoundToClient 的原版路径由客户端用自己的游戏文件解析，服务端无该文件也会发送；实测无声 = 路径名不对或客户端无此文件）
- 音效脚本名（"PainPills.Use" 等）在服务器上也解析不了（无 game_sounds）
- 唯一权威来源：**客户端安装**（Steam 正常安装的原版 VPK 里有完整 sound 树）或网上 VPK 文件清单（github/steamdb 在本环境被 WebFetch 拦截，WebSearch 也难挖到）
- 可靠替代：自定义 mp3/wav 走已验证管线（服务器 sound/ 目录 + precache + EmitSoundToClient，见 [[l4d2-bf-killfeedback]] [[l4d2-sound-cache-pitfall]]）

## 关联

- [[l4d2-give-items]] — 触发此调查的递物音效需求，v1.2 已默认关闭
- [[l4d2-precachescriptsound-broken]] — 地图 VPK 带二进制 sound.cache（唯一含原版音效条目的服务器侧数据源，未验证是否含 wave 路径）
