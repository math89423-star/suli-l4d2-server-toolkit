# L4D2 Admin Panel — 地图管理 Web 面板

一个 Flask 单页应用，为 L4D2 服务器提供：

- **服务器状态** — 当前地图、玩家数、tickrate
- **切图** — 网页端一键切图（带加载锁 + 冷却保护）
- **地图池管理** — 官方图 / 三方图 双池切换，拖拽排序
- **ZIP 上传** — 上传地图 VPK 到 addons + 备份 + 自动扫描
- **Steam 工坊下载** — steamcmd 下载 + 解析 + 注册到 maps.json
- **服务器重启** — Docker Compose restart（玩家检测）
- **地图下载站** — nginx 暴露 maps/zip/ 给玩家下载

---

## 目录

- [前提条件](#前提条件)
- [快速部署](#快速部署)
- [必须修改的路径（全部清单）](#必须修改的路径全部清单)
- [配置项说明](#配置项说明)
- [目录结构](#目录结构)
- [API 接口](#api-接口)
- [维护操作](#维护操作)
- [常见问题](#常见问题)

---

## 前提条件

| 项目 | 说明 |
|------|------|
| Python | >= 3.10 |
| pip 包 | `flask>=3.0`, `rcon>=2.0` (`pip install -r requirements.txt`) |
| steamcmd | 工坊下载功能需要（仅 workshop API 调用时） |
| unzip | 上传解压需要 |
| strings | VPK 扫描需要（binutils 包） |
| Docker Compose | 重启功能需要（`docker compose -f xxx.yml restart`） |
| nginx | 可选，用于地图下载站 + 反向代理 |
| L4D2 服务器 | 已部署，RCON 已开启，SourceMod + `sm_map` 可用 |

---

## 快速部署

### 1. 解压并放置

```bash
# 假设 L4D2 服务器根目录为 /opt/gameservers/l4d2/
tar xzf l4d2-admin-panel.tar.gz
mv l4d2-admin-panel /opt/gameservers/l4d2/admin-panel
```

### 2. 修改配置（★ 关键步骤）

```bash
cd /opt/gameservers/l4d2/admin-panel
cp config.json.example config.json
vim config.json   # ★ 修改所有 ★ 标记的路径和密码
```

**最低限度必须修改：**

| 配置项 | 说明 |
|--------|------|
| `rcon_password` | 你的 L4D2 RCON 密码 |
| `mapcycle_path` | mapcycle.txt 路径 |
| `addons_dir` | addons 目录路径 |
| `maps_zip_dir` | ZIP 存放目录 |
| `maps_vpk_dir` | VPK 备份目录 |
| `compose_file` | docker-compose.yml 路径 |

首次启动时会自动生成 `admin_password_hash` 和 `secret_key`。

### 3. 安装 Python 依赖

```bash
pip install -r requirements.txt
```

### 4. 创建必要目录

```bash
mkdir -p maps/zip maps/vpk
```

### 5. 启动 Admin Panel

```bash
# 前台运行（调试用）
python3 app.py

# 或使用 systemd（推荐）
sudo cp deploy/l4d2-admin.service /etc/systemd/system/
sudo vim /etc/systemd/system/l4d2-admin.service   # ★ 修改路径
sudo systemctl daemon-reload
sudo systemctl enable --now l4d2-admin
```

### 6. 配置 nginx（可选，用于地图下载站）

```bash
sudo cp deploy/nginx-l4d2-maps.conf /etc/nginx/sites-available/l4d2-maps
sudo vim /etc/nginx/sites-available/l4d2-maps  # ★ 修改路径和域名
sudo ln -s /etc/nginx/sites-available/l4d2-maps /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx
```

### 7. 首次扫描地图

```bash
python3 scan_maps.py
# 生成 maps.json，包含所有 addons 目录下的 VPK 地图信息
```

### 8. 登录

浏览器打开 `http://你的IP/admin/`，用 `admin_password_hash` 对应的密码登录（首次默认 `admin123` 或环境变量 `L4D2_ADMIN_PASSWORD`）。

---

## 必须修改的路径（全部清单）

### config.json — 9 个路径

```json
{
    "mapcycle_path":            "★ 生效中的 mapcycle.txt",
    "mapcycle_official_path":   "★ 官方图 mapcycle_official.txt",
    "mapcycle_custom_path":     "★ 三方图 mapcycle_custom.txt",
    "addons_dir":               "★ left4dead2/addons/ 目录",
    "steamcmd_path":            "★ steamcmd 可执行文件路径",
    "maps_zip_dir":             "★ ZIP 源文件存放目录（也是 nginx 下载站根目录）",
    "maps_vpk_dir":             "★ VPK 备份目录",
    "scan_script":              "★ scan_maps.py 的绝对路径",
    "compose_file":             "★ docker-compose.yml 的绝对路径"
}
```

### scan_maps.py — 3 个硬编码位置

| 行号 | 变量/位置 | 说明 |
|------|-----------|------|
| 第 33 行 | `default` 变量（`load_addons_dir()` 内） | addons_dir 的后备默认值 |
| `VPK_CATALOG` 字典 | 整个字典 | VPK 文件名 → 战役元数据的映射，**根据你安装的地图更新** |
| `MANUAL_CAMPAIGNS` 列表 | 整个列表 | 工坊图的手动维护列表，**根据你的工坊图更新** |

### switch_map.py — 1 个硬编码位置

| 行号 | 变量 | 说明 |
|------|------|------|
| 第 37 行 | `load_addons_dir()` 返回的默认值 | addons_dir 的后备默认值 |

### app.py — 0 个硬编码

`app.py` 所有路径从 `config.json` 读取，fallback 使用 `BASE_DIR` 相对路径。**不需要修改 app.py**。

### systemd service — 1 个路径

```
WorkingDirectory=★ /opt/gameservers/l4d2/admin-panel
```

### nginx config — 2 个路径

```
server_name ★ 你的域名或IP;
root ★ /opt/gameservers/l4d2/admin-panel/maps/zip;
```

---

## 配置项说明

### config.json 完整参考

| 键 | 类型 | 默认值 | 说明 |
|----|------|--------|------|
| `rcon_host` | string | `127.0.0.1` | L4D2 RCON 地址 |
| `rcon_port` | int | `27015` | L4D2 RCON 端口 |
| `rcon_password` | string | — | RCON 密码 |
| `admin_password_hash` | string | `replace_me_...` | 管理员密码哈希（首次自动生成） |
| `secret_key` | string | `replace_me_...` | Flask session 密钥（首次自动生成） |
| `host` | string | `0.0.0.0` | Flask 监听地址 |
| `port` | int | `5000` | Flask 监听端口 |
| `mapcycle_path` | string | — | 当前生效的 mapcycle.txt 路径 |
| `mapcycle_official_path` | string | — | 官方图 mapcycle 路径 |
| `mapcycle_custom_path` | string | — | 三方图 mapcycle 路径 |
| `addons_dir` | string | — | addons 目录（VPK 存放位置） |
| `steamcmd_path` | string | `/usr/games/steamcmd` | steamcmd 可执行文件 |
| `maps_zip_dir` | string | — | 上传 ZIP 存放目录 |
| `maps_vpk_dir` | string | — | VPK 备份目录 |
| `scan_script` | string | — | scan_maps.py 绝对路径 |
| `compose_file` | string | — | docker-compose.yml 绝对路径 |
| `post_switch_buffer` | int | `15` | 切图后缓冲秒数（让玩家进入） |
| `tumtara_maps` | list | `["tumtara", ...]` | 需要卸载特定插件的图 |
| `tumtara_unload_plugins` | list | `["AI_HardSI", ...]` | 进入这些图时临时卸载的插件 |

---

## 目录结构

```
admin-panel/
├── README.md                 # 本文件
├── app.py                    # Flask 主应用 (546 行)
├── scan_maps.py              # VPK 扫描 + maps.json 生成
├── switch_map.py             # 命令行切图工具
├── config.json.example       # 配置模板 → 复制为 config.json
├── requirements.txt          # Python 依赖
├── static/
│   └── style.css             # 前端样式（暗色主题）
├── templates/
│   └── index.html            # 单页应用（内联 JS）
├── maps/
│   ├── zip/                  # ZIP 存档 + nginx 下载站根目录
│   │   └── .gitkeep
│   └── vpk/                  # VPK 备份
│       └── .gitkeep
├── maps.json                 # 地图元数据（scan_maps.py 生成）
└── deploy/
    ├── l4d2-admin.service    # systemd unit 模板
    └── nginx-l4d2-maps.conf  # nginx site 模板
```

---

## API 接口

| 方法 | 路径 | 认证 | 说明 |
|------|------|------|------|
| POST | `/api/login` | 否 | 登录，body: `{password}` |
| POST | `/api/logout` | 否 | 登出 |
| GET | `/api/check` | 否 | 检查 session 是否有效 |
| GET | `/api/status` | 是 | 服务器状态（hostname/map/players/tickrate） |
| GET | `/api/maps` | 是 | 完整 maps.json |
| GET | `/api/mapcycle` | 是 | 读取 mapcycle（支持 `?type=official|custom`） |
| PUT | `/api/mapcycle` | 是 | 写入 mapcycle，body: `{maps: [...]}` |
| POST | `/api/mapcycle/activate` | 是 | 切换轮换池，body: `{type: "official"|"custom"}` |
| POST | `/api/switch` | 是 | 切图，body: `{map: "c1m1_hotel"}` |
| GET | `/api/cooldown` | 是 | 切图锁状态（loading/buffer/ready） |
| POST | `/api/maps/upload` | 是 | 上传 ZIP（multipart form，field: `file`） |
| POST | `/api/maps/workshop` | 是 | 工坊下载，body: `{url: "工坊链接或ID"}` |
| POST | `/api/server/restart` | 是 | 重启，body: `{force: true}` |
| GET | `/health` | 否 | 健康检查 |

---

## 维护操作

### 安装新地图后

```bash
# 重新扫描 VPK（更新 maps.json）
cd /opt/gameservers/l4d2/admin-panel
python3 scan_maps.py

# 如果地图带 VPK（非工坊），需要重启容器
docker compose -f /opt/gameservers/l4d2/docker-compose.yml restart
```

### 添加新的 VPK_CATALOG 条目

在 `scan_maps.py` 的 `VPK_CATALOG` 字典中添加：

```python
VPK_CATALOG = {
    # ...existing...
    "new_map_v1_0": ("nm", "New Map", "nm", "150M", "custom"),
}
```

字段含义: `(campaign_id, 中文名, 别名, 大小, 分类)`
- 分类: `"custom"` = 三方战役, `"fun"` = 娱乐/特感

### 命令行切图

```bash
cd /opt/gameservers/l4d2/admin-panel
python3 switch_map.py dw          # 用别名切
python3 switch_map.py c1m1_hotel  # 用地图名切
python3 switch_map.py --list      # 列出已安装地图
```

### 查看/修改密码

```bash
# 密码哈希存在 config.json 中
# 如需重置，删除 admin_password_hash 那行（或改成 "replace_me_..."），重启 app.py
# 或设置环境变量:
L4D2_ADMIN_PASSWORD=新密码 python3 app.py
```

---

## 常见问题

### Q: 首次启动后不知道密码？
首次启动会自动生成密码，查看 stderr 输出:
```
[init] Admin password: admin123
```
如果没看到，设置环境变量 `L4D2_ADMIN_PASSWORD` 后重启。

### Q: 切图后一直显示"加载中"？
- 源服务器可能没有 SourceMod 的 `sm_map` 命令
- RCON 连接可能失败 — 检查 `rcon_host`、`rcon_port`、`rcon_password`
- 地图名可能不存在于 maps.json 中

### Q: 上传 ZIP 后地图不生效？
- VPK 需要复制到 `addons_dir`（容器可能还没加载）
- 需要重启 L4D2 容器（点击网页红色横幅"重启服务器"）
- 检查 `addons_dir` 路径是否正确

### Q: steamcmd 工坊下载失败？
- 确保 `steamcmd` 已安装且在配置的路径
- 确保 `steamcmd` 以 `+login anonymous` 方式可运行
- 首次运行可能需要更新 steamcmd 自身

### Q: nginx 目录浏览看不到 ZIP 文件？
- 检查 `maps/zip/` 目录权限: `chmod o+x` 穿透每一层父目录
- 检查 nginx root 路径是否为绝对路径

### Q: 502 Bad Gateway (nginx → Flask)？
- 检查 Flask 是否在运行: `systemctl status l4d2-admin`
- 检查 Flask 是否监听在 `0.0.0.0:5000`
- 检查防火墙是否允许本地回环

---

## 部署检查清单

部署到新服务器后，逐项确认：

- [ ] `config.json` 从 `.example` 复制并修改所有 ★ 项
- [ ] `password_hash` 和 `secret_key` 已自动生成
- [ ] `maps/zip/` 和 `maps/vpk/` 目录已创建
- [ ] `pip install -r requirements.txt` 成功
- [ ] `python3 scan_maps.py` 可运行（生成 maps.json）
- [ ] `python3 switch_map.py --list` 可列出地图
- [ ] systemd service 路径正确，已 enable + start
- [ ] `curl http://127.0.0.1:5000/health` 返回 `{"ok":true}`
- [ ] nginx 反向代理 `/admin/` → `127.0.0.1:5000/` 正常
- [ ] 网页登录正常，可看到服务器状态
- [ ] 切图功能可用（确保没有玩家在线时测试）
