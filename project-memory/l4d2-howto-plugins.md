---
name: l4d2-howto-plugins
description: L4D2 服务器插件管理（SourceMod/MetaMod）操作步骤
metadata: 
  node_type: memory
  type: reference
  tags: 
    - l4d2
    - sourcemod
    - metamod
    - plugins
    - howto
  originSessionId: 4b3417fe-a874-420c-b976-80f0ddfa0c75
---

# L4D2 插件管理指南

## 目录结构

```
/opt/gameservers/l4d2/data/addons/
├── l4dtoolz.vdf          ← Source 引擎插件（VDF 直接加载）
├── l4dtoolz/l4dtoolz.so  ← 插件 .so 文件（必须 32 位）
├── metamod.vdf           ← MetaMod VDF
├── metamod/              ← MetaMod 核心
│   ├── bin/server.so     ← MetaMod 32 位
│   └── sourcemod.vdf     ← 告诉 MetaMod 加载 SourceMod
├── sourcemod/
│   ├── bin/              ← SourceMod 核心 .so（必须 32 位）
│   ├── configs/          ← SM 全局配置（databases.cfg 等）
│   ├── data/             ← 插件运行时数据文件
│   ├── extensions/       ← SM 扩展 .so（dhooks, sdktools 等）
│   ├── gamedata/         ← 游戏签名/偏移数据
│   ├── logs/             ← SM 日志
│   ├── plugins/          ← .smx 插件
│   │   └── disabled/     ← 禁用的 .smx
│   └── translations/     ← 多语言翻译文件
└── 地图.vpk              ← 三方地图
```

## 安装新插件

```bash
# 1. 把 .smx 放到 plugins/
cp 插件名.smx /opt/gameservers/l4d2/data/addons/sourcemod/plugins/
chmod 644 /opt/gameservers/l4d2/data/addons/sourcemod/plugins/插件名.smx

# 2. 如果是扩展类插件（有 .so），放到 extensions/
cp 扩展名.ext.so /opt/gameservers/l4d2/data/addons/sourcemod/extensions/
chmod 644 /opt/gameservers/l4d2/data/addons/sourcemod/extensions/扩展名.ext.so

# 3. 如果是 gamedata 类，放到 gamedata/
cp 数据.games.txt /opt/gameservers/l4d2/data/addons/sourcemod/gamedata/

# 4. 配置文件（如果有）放到 cfg/sourcemod/
cp 插件名.cfg /opt/gameservers/l4d2/data/cfg/sourcemod/

# 5. 翻译文件（如果有）放到 translations/
cp 插件名.phrases.txt /opt/gameservers/l4d2/data/addons/sourcemod/translations/

# 6. 重启
docker compose -f /opt/gameservers/l4d2/docker-compose.yml restart
```

## 禁用/启用插件

```bash
# 禁用：移到 disabled 目录
mv /opt/gameservers/l4d2/data/addons/sourcemod/plugins/插件名.smx \
   /opt/gameservers/l4d2/data/addons/sourcemod/plugins/disabled/

# 启用：移回来
mv /opt/gameservers/l4d2/data/addons/sourcemod/plugins/disabled/插件名.smx \
   /opt/gameservers/l4d2/data/addons/sourcemod/plugins/

# 重启生效
docker compose -f /opt/gameservers/l4d2/docker-compose.yml restart
```

## 修改插件配置

```bash
# 插件 cfg 在 cfg/sourcemod/ 下（会以 sm_cvar 方式执行）
vim /opt/gameservers/l4d2/data/cfg/sourcemod/插件名.cfg
docker compose restart
```

## ⚠️ 关键规则

1. **所有 .so 必须是 32 位** — 删除所有 x64 .so 和 metamod_x64.vdf
2. **cfg 注释不能用中文/em dash** — 会导致 Unknown command 刷屏
3. **文件权限至少 644** — 容器以 `louis` 用户（UID 1000）运行（2026-07-25 已从 steam UID 1003 迁移，见 [[l4d2-docker-migration]]）
4. **新增 .smx 后看日志确认**: `docker logs l4d2-server | grep -E 'Unable|Error'`

## 验证插件加载

```bash
docker logs l4d2-server 2>&1 | grep -iE "插件名|error.*插件名|Unable.*插件名"
```

## 关联
- [[l4d2-deployment-rules]] — 踩坑清单
- [[l4d2-permissions-pitfall]] — 权限 700 坑
- [[l4d2-32bit-architecture-pitfall]] — 32 位架构坑
- [[l4d2-howto-thirdparty-maps]] — 三方地图管理
