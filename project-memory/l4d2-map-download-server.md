---
name: l4d2-map-download-server
description: nginx 地图下载站，暴露 admin-panel/maps/zip/ 供玩家同步地图
metadata: 
  node_type: memory
  type: reference
  tags: 
    - l4d2
    - nginx
    - maps
    - download
  originSessionId: dcfeb91a-412e-4be8-9b16-feb24a69933c
---

# L4D2 地图下载站

## 访问地址

**http://81.71.101.135** (端口 80)

## 路由

| 路由 | 用途 |
|------|------|
| `/` | L4D2 管理面板前端（proxy → Flask :5000） |
| `/maps/` | 地图 ZIP 下载（目录浏览） |

## 配置

| 项目 | 值 |
|------|-----|
| Web 服务器 | nginx 1.24.0 |
| 监听端口 | 80 |
| 地图文件目录 | `/opt/gameservers/l4d2/admin-panel/maps/zip` |
| 目录浏览 | autoindex on |
| ZIP/VPK 缓存 | 7 天 (immutable) |
| 配置路径 | `/etc/nginx/sites-available/l4d2-maps` |

## 目录权限

- `/opt/gameservers/l4d2/admin-panel/maps/zip/` — `o+x` 穿透，`o+r` 读取
- Admin Panel 上传 ZIP 时自动设 644

## 重要

- 新增地图 ZIP 直接放到 `admin-panel/maps/zip/` 即可在 `/maps/` 列表出现
- 也可通过管理面板网页上传（首页 → 地图管理 tab）
- 文件名含中文或特殊字符需要 URL encode

## 关联

- [[l4d2-howto-thirdparty-maps]] — 地图安装方式
- [[l4d2-server-quick-reference]] — 服务器管理
