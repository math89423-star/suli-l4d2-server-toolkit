---
name: l4d2-howto-plugins
description: L4D2 服务器插件管理（SourceMod/MetaMod）操作步骤——直装模式（非 Docker）
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

# L4D2 插件管理指南（直装模式）

> **⚠️ 当前服务器是直装 `srcds_linux`**，不走 Docker。
> 旧 Docker 路径 `/opt/gameservers/l4d2/data/` 已废弃。

## 目录结构

```
/home/administrator/l4d2-server/left4dead2/
├── addons/
│   ├── metamod/
│   │   └── bin/server.so
│   └── sourcemod/
│       ├── bin/
│       ├── configs/
│       ├── data/
│       ├── extensions/
│       ├── gamedata/
│       ├── logs/
│       ├── plugins/          ← .smx 插件
│       │   └── disabled/     ← 禁用的 .smx
│       └── translations/
├── cfg/
│   ├── server.cfg            ← 服务器全局配置
│   └── sourcemod/            ← 插件 cfg（sm_cvar 方式执行）
└── *.vpk                     ← 三方地图
```

## 源码仓库

```
/home/administrator/suli-l4d2-server-toolkit/
├── scripting/                ← .sp 源码
│   ├── compiled/             ← 编译产物 .smx
│   └── include/              ← 自定义 .inc 头文件
├── server-cfg/sourcemod/     ← 插件 cfg（部署时拷到 cfg/sourcemod/）
├── gamedata/                 ← gamedata 文件
└── project-memory/           ← 记忆文件
```

## 编译插件

```bash
# 源码编译（spcomp 路径固定）
/home/administrator/l4d2-server/left4dead2/addons/sourcemod/scripting/spcomp \
    插件名.sp \
    -o=compiled/插件名.smx \
    -i=include \
    -i=/home/administrator/l4d2-server/left4dead2/addons/sourcemod/scripting/include

# 含子目录 include 的插件（如 AI_HardSI）
/home/administrator/l4d2-server/left4dead2/addons/sourcemod/scripting/spcomp \
    AI_HardSI_optimized/AI_HardSI.sp \
    -o=compiled/AI_HardSI_bt.smx \
    -i=include \
    -i=AI_HardSI_optimized \
    -i=/home/administrator/l4d2-server/left4dead2/addons/sourcemod/scripting/include
```

## 热加载插件（不停服）

```bash
# 1. 编译
cd /home/administrator/suli-l4d2-server-toolkit/scripting
/home/administrator/l4d2-server/left4dead2/addons/sourcemod/scripting/spcomp \
    插件名.sp -o=compiled/插件名.smx -i=include \
    -i=/home/administrator/l4d2-server/left4dead2/addons/sourcemod/scripting/include

# 2. 部署到 plugins 目录
cp compiled/插件名.smx /home/administrator/l4d2-server/left4dead2/addons/sourcemod/plugins/

# 3. RCON 热加载（无需重启 srcds）
python3 /home/administrator/suli-l4d2-server-toolkit/bin/rcons.py 'sm plugins reload 插件名'
```

> **RCON 客户端**: `/home/administrator/suli-l4d2-server-toolkit/bin/rcons.py`，端口 27015，密码在 `server.cfg`。

## 部署 cfg

```bash
# 从仓库拷到服务器
cp suli-l4d2-server-toolkit/server-cfg/sourcemod/插件名.cfg \
   l4d2-server/left4dead2/cfg/sourcemod/
```

> cfg 在 **下次 map start 或 `sm plugins reload` 时** 才生效（`AutoExecConfig`）。

## 禁用/启用插件

```bash
# 禁用
mv /home/administrator/l4d2-server/left4dead2/addons/sourcemod/plugins/插件名.smx \
   /home/administrator/l4d2-server/left4dead2/addons/sourcemod/plugins/disabled/

# 启用
mv /home/administrator/l4d2-server/left4dead2/addons/sourcemod/plugins/disabled/插件名.smx \
   /home/administrator/l4d2-server/left4dead2/addons/sourcemod/plugins/

# 热加载生效
python3 /home/administrator/suli-l4d2-server-toolkit/bin/rcons.py 'sm plugins reload 插件名'
```

## 查看插件状态

```bash
# 列出所有插件
python3 /home/administrator/suli-l4d2-server-toolkit/bin/rcons.py 'sm plugins list'

# 查看特定插件
python3 /home/administrator/suli-l4d2-server-toolkit/bin/rcons.py 'sm plugins info 插件名'

# 查看错误日志
tail -50 /home/administrator/l4d2-server/left4dead2/addons/sourcemod/logs/errors_$(date +%Y%m%d).log
```

## ⚠️ 关键规则

1. **cfg 注释不能用中文/em dash** — 会导致 Unknown command 刷屏
2. **spcomp 是 32 位**（路径固定在 `scripting/spcomp`），但 .smx 产物兼容 64 位 SM
3. **热加载不等于换图** — 部署新 `.smx` 后用 `sm plugins reload` 而不是重启 srcds
4. **cfg 变更需 `AutoExecConfig` 触发** — 纯 cvar 改动可直接 `sm_cvar` 临时生效
5. **三方地图 VPK 需重启 srcds 才能被引擎识别** — 引擎启动时扫描 addons/ 下的 VPK

## 验证

```bash
# 确认插件加载无错误
python3 /home/administrator/suli-l4d2-server-toolkit/bin/rcons.py 'sm plugins list' 2>&1 | grep "插件名"

# 确认 cvar 生效
python3 /home/administrator/suli-l4d2-server-toolkit/bin/rcons.py 'sm_cvar cvar名' 2>&1 | grep "Value"
```

## 关联
- [[l4d2-rcon-hotreload-workflow]] — 完整热加载方案（含已知问题清单）
- [[l4d2-deployment-rules]] — 踩坑清单
- [[l4d2-permissions-pitfall]] — 权限 700 坑
- [[l4d2-32bit-architecture-pitfall]] — 32 位架构坑
- [[l4d2-howto-thirdparty-maps]] — 三方地图管理
- [[l4d2-admin-map-management]] — 前端面板管理
