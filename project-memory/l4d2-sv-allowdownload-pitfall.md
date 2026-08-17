---
name: l4d2-sv-allowdownload-pitfall
description: 插件引入自定义文件（音效/模型/材质）后客户端下载失败静默中止，必须用 HTTP Fast Download
metadata: 
  node_type: memory
  type: feedback
  tags: 
    - l4d2
    - server
    - sourcemod
    - download
    - pitfall
  originSessionId: 1f4d28d6-2464-49e9-8bfc-39dd01d45abe
  modified: 2026-07-27T04:54:59.877Z
---

# L4D2 自定义文件下载静默中止

## 症状

客户端能连上服务器、能进地图，但控制台出现：
```
Downloading sound/battlefield/tank_kill.mp3.
CBaseClientState::FileReceived: sound/battlefield/tank_kill.mp3.
Aborting download of sound/battlefield/tank_kill.mp3
```
自定义音效/模型/材质下载被静默中止，客户端永远收不到这些文件，插件功能（如击杀音效）对客户端失效。

## 根因（两层）

1. L4D2（Source 引擎）默认 `sv_allowdownload 0` — 默认**禁止**游戏协议直传文件
2. **Valve 2021+ 安全更新后，`sv_allowdownload 1` 也废了** — `FileReceived` 后客户端卡死进不去，游戏内直传通道已事实上不可用

任意 SourceMod 插件引用了 `sound/`、`models/`、`materials/` 等目录下的自定义文件，客户端连接时都会触发下载请求，但无论 `sv_allowdownload` 开或关，结果都是客户端卡住。

## 正确修复

**必须用 HTTP Fast Download**（`sv_downloadurl`）— 所有 L4D2 服务器标准做法。

### 1. nginx fastdl location

```
location /l4d2_fastdl/ {
    alias /opt/gameservers/l4d2/data/;
    autoindex off;
    location ~* \.(mp3|wav|mdl|vtx|vvd|phy|vtf|vmt|pcf|bz2)$ {
        expires 7d;
        add_header Cache-Control "public, immutable";
    }
}
```

### 2. server.cfg

```
sv_allowdownload 1                         # 保留但不依赖
sv_downloadurl "http://81.71.101.135/l4d2_fastdl/"
net_maxfilesize 64                         # 64MB，音效/模型/材质都够
```

### 3. 路径映射规则

Source 引擎 HTTP Fast Download 约定：
- `sv_downloadurl` 末尾必须有 `/`
- 客户端需要 `sound/battlefield/tank_kill.mp3` → 客户端请求 `{sv_downloadurl}sound/battlefield/tank_kill.mp3`
- nginx `alias` 路径 + 请求路径剩余部分必须指向服务器上的实际文件

本服映射：
| 游戏路径 | HTTP 请求 | 服务器文件 |
|---------|----------|-----------|
| `sound/battlefield/tank_kill.mp3` | `http://host/l4d2_fastdl/sound/battlefield/tank_kill.mp3` | `data/sound/battlefield/tank_kill.mp3` |

## 为什么容易踩

- Docker 日志不报错 — 下载协商发生在客户端连接后，不在服务端日志里
- `docker logs` 只能看到服务器启动日志（插件配置加载），看不到客户端的下载失败
- 服务器正常运行、端口监听、A2S 查询正常 — 一切看起来都没问题
- `FileReceived` 日志让人以为下载成功了，实际上客户端卡在加载画面
- 只有引入自定义文件（如 bf-killfeedback 的音效）之后才会触发，新建服不踩

## 客户端残留破损文件的处理

HTTP fastdl 配置好后，之前通过游戏协议 **部分下载/中止** 的文件会残留在客户端本地。Source 引擎只检查文件**存在**，不验证完整性，导致客户端跳过这些文件的 HTTP 下载，破损文件无法播放。

**服务端修复**：修改文件内容（如追加 1 字节）改变 CRC → 换图触发 `OnMapStart` 重新调用 `AddFileToDownloadsTable` → 客户端比对 CRC 发现不匹配 → 自动走 HTTP fastdl 重下所有文件。

## 关联

- [[l4d2-bf-killfeedback]] — 战地击杀反馈插件，触发此坑的音效文件来源
- [[l4d2-howto-plugins]] — 插件管理
- [[l4d2-server-quick-reference]] — 服务器管理速查
- [[l4d2-map-download-server]] — nginx 地图下载站（同一 nginx server block）
