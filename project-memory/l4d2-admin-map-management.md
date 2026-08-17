---
name: l4d2-admin-map-management
description: Admin Panel 地图管理功能 — 部署方式(Docker Compose) + ZIP 上传 + Steam 工坊下载 + 重启
metadata:
  node_type: memory
  type: reference
  tags:
    - l4d2
    - admin-panel
    - maps
    - upload
    - workshop
    - docker
  originSessionId: aca5913a-51e1-43f2-83c6-d53c592f86fc
  modified: 2026-08-01T12:20:13.229Z
---

# L4D2 Admin Panel 地图管理

## 部署方式

Admin Panel 已迁移到 **Docker Compose**，随 `l4d2-server` 统一启停（不再使用 systemd）。

```bash
# 启停（与游戏服务器一起）
docker compose -f /opt/gameservers/l4d2/docker-compose.yml up -d
docker compose -f /opt/gameservers/l4d2/docker-compose.yml down

# 单独管理 admin panel
docker compose -f /opt/gameservers/l4d2/docker-compose.yml up -d l4d2-admin
docker compose -f /opt/gameservers/l4d2/docker-compose.yml stop l4d2-admin

# 查看日志
docker logs l4d2-admin
```

**关键信息**：
- 容器名：`l4d2-admin`
- 镜像：`l4d2-l4d2-admin`（由 `admin-panel/Dockerfile` 构建）
- 网络：`host`（需要 RCON 连接 127.0.0.1:27015）
- 端口：5000
- Dockerfile 路径：`/opt/gameservers/l4d2/admin-panel/Dockerfile`
- systemd 服务 `l4d2-admin.service` 已废弃、已停止、已禁用

**重建镜像**：
```bash
cd /opt/gameservers/l4d2 && docker compose build l4d2-admin
```

**⚠️ 代码是 bind mount**：`./admin-panel:/opt/gameservers/l4d2/admin-panel`（Dockerfile 只 COPY requirements.txt）。改 app.py 等宿主机文件后**只需 `docker restart l4d2-admin`**，无需 rebuild。admin-panel 目录本身不是 git 仓库。

## 访问

http://81.71.101.135/admin/ → 「地图管理」tab

## 功能

### ZIP 上传
- 拖拽/点击选择 .zip 文件 → 点击上传
- 进度条显示：百分比 + 速度 (MB/s) + 剩余时间
- 后端流程：
  1. ZIP 保存到 `maps/zip/`（nginx 下载站根目录）
  2. unzip 提取 VPK 到临时目录
  3. VPK 复制到 `data/addons/`（引擎加载）+ `maps/vpk/`（备份）
  4. 执行 `scan_maps.py` 重新生成 maps.json
- 上传完成后需要重启容器生效

### Steam 工坊下载
- 输入工坊链接或纯数字 ID
- 后端 `steamcmd +login anonymous +workshop_download_item 550 <id>`
- 解析 VPK 获取地图名 → 更新 maps.json + mapcycle_custom.txt
- **工坊图 VPK 不放 addons**（避免版本冲突），玩家自行订阅

### 重启服务器
- 有 VPK 地图时显示红色重启横幅
- 点击 → `docker restart l4d2-server`（**仅重启游戏容器**，不影响 admin panel）

## 目录结构

```
/opt/gameservers/l4d2/admin-panel/
├── Dockerfile              ← 容器镜像定义
├── app.py                  ← Flask 主程序
├── config.json             ← RCON 密码、路径配置
├── requirements.txt        ← flask>=3.0, rcon>=2.0
├── scan_maps.py            ← VPK 扫描生成 maps.json
├── switch_map.py           ← 命令行换图工具
├── templates/              ← 前端 HTML
├── static/                 ← CSS
├── maps/
│   ├── zip/                ← ZIP 源文件（nginx 下载站根目录）
│   └── vpk/                ← VPK 备份
└── maps.json               ← 地图元数据

/opt/gameservers/l4d2/data/addons/  ← 引擎加载 VPK（非工坊）
```

## API 接口

| 方法 | 路径 | 说明 |
|------|------|------|
| POST | `/api/login` | 登录 |
| POST | `/api/maps/upload` | 上传 ZIP（multipart），返回 {ok, vpks[], need_restart} |
| POST | `/api/maps/workshop` | 工坊下载，接收 {url}，steamcmd 同步等待 |
| POST | `/api/server/restart` | 重启游戏容器（`docker restart l4d2-server`），force=true 跳过玩家检查 |
| GET | `/api/status` | 服务器状态 |
| GET | `/health` | 健康检查 |

## 关联

- [[l4d2-howto-thirdparty-maps]] — 地图规则（工坊 vs 非工坊）
- [[l4d2-map-download-server]] — nginx 下载站
- [[l4d2-deployment-rules]] — 铁律（重启 ≠ down+up）
- [[l4d2-server-quick-reference]] — 管理速查
- [[l4d2-deployment-guide]] — 部署步骤
