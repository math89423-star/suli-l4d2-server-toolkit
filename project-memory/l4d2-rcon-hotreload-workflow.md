---
name: l4d2-rcon-hotreload-workflow
description: L4D2 SourceMod 插件 RCON 热加载完整方案——编译→部署→reload，不停服生效
metadata:
  node_type: memory
  type: reference
  tags:
    - l4d2
    - sourcemod
    - rcon
    - hot-reload
    - workflow
---

# L4D2 RCON 热加载方案（2026-08-19 固化）

## 架构总览

```
.sp 源码 → spcomp 编译 → .smx → cp 到 plugins/ → RCON sm plugins reload
                    ↑                              ↑
          suli-l4d2-server-toolkit/     l4d2-server/left4dead2/addons/sourcemod/plugins/
```

**核心原则**: 修改 .smx → 部署 → `sm plugins reload`，不需要重启 srcds。

## RCON 客户端

### 工具路径
```
/home/administrator/suli-l4d2-server-toolkit/bin/rcons.py
```

### 连接参数
```python
HOST = "127.0.0.1"
PORT = 27015
PASS = "Nxp4HJ1xE2Jtzjng"  # 纯字母数字，无 + - = 等特殊字符
```

### 使用方式
```bash
# 基础命令
python3 /home/administrator/suli-l4d2-server-toolkit/bin/rcons.py 'status'
python3 /home/administrator/suli-l4d2-server-toolkit/bin/rcons.py 'sm plugins list'
python3 /home/administrator/suli-l4d2-server-toolkit/bin/rcons.py 'sm plugins reload 插件名'
python3 /home/administrator/suli-l4d2-server-toolkit/bin/rcons.py 'sm plugins unload 插件名'
python3 /home/administrator/suli-l4d2-server-toolkit/bin/rcons.py 'sm plugins load 插件名'
```

### ⚠️ 已知坑（详见关联文件）
1. **脚本文件名不能是 `rcon.py`** — 会与 `rcon.source` pip 包冲突 → `[[l4d2-rcon-filename-pitfall]]`
2. **密码不能含 `+` 等特殊字符** — SRCDS 命令行解析器截断 → `[[l4d2-rcon-password-pitfall]]`

## 完整热加载流程

### 步骤 1: 编译
```bash
cd /home/administrator/suli-l4d2-server-toolkit/scripting

# 简单插件
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

### 步骤 2: 部署
```bash
cp /home/administrator/suli-l4d2-server-toolkit/scripting/compiled/插件名.smx \
   /home/administrator/l4d2-server/left4dead2/addons/sourcemod/plugins/
```

### 步骤 3: 热加载
```bash
python3 /home/administrator/suli-l4d2-server-toolkit/bin/rcons.py 'sm plugins reload 插件名'
```

### 一步到位（合并命令）
```bash
cd /home/administrator/suli-l4d2-server-toolkit/scripting && \
/home/administrator/l4d2-server/left4dead2/addons/sourcemod/scripting/spcomp \
    插件名.sp -o=compiled/插件名.smx -i=include \
    -i=/home/administrator/l4d2-server/left4dead2/addons/sourcemod/scripting/include && \
cp compiled/插件名.smx /home/administrator/l4d2-server/left4dead2/addons/sourcemod/plugins/ && \
python3 /home/administrator/suli-l4d2-server-toolkit/bin/rcons.py 'sm plugins reload 插件名'
```

## cfg 热加载

cfg 文件在 **下次 map start 或 `sm plugins reload`** 时才生效（`AutoExecConfig`）。
纯 cvar 改动可直接 `sm_cvar` 临时生效。

```bash
# 直接改 cvar（立即生效）
python3 rcons.py 'sm_cvar sv_maxcmdrate 60'

# 部署 cfg + reload 触发 AutoExecConfig
cp 插件名.cfg /home/administrator/l4d2-server/left4dead2/cfg/sourcemod/
python3 rcons.py 'sm plugins reload 插件名'
```

## 禁用/启用插件

```bash
# 禁用
mv /home/administrator/l4d2-server/left4dead2/addons/sourcemod/plugins/插件名.smx \
   /home/administrator/l4d2-server/left4dead2/addons/sourcemod/plugins/disabled/

# 启用
mv /home/administrator/l4d2-server/left4dead2/addons/sourcemod/plugins/disabled/插件名.smx \
   /home/administrator/l4d2-server/left4dead2/addons/sourcemod/plugins/
```

## 验证

```bash
# 列出插件状态
python3 rcons.py 'sm plugins list'

# 查看特定插件
python3 rcons.py 'sm plugins info 插件名'

# 查看错误日志
tail -50 /home/administrator/l4d2-server/left4dead2/addons/sourcemod/logs/errors_$(date +%Y%m%d).log
```

## 已知问题（截至 2026-08-19）

### 1. l4d2_rescue_heal.smx 加载失败
- **错误**: `[SM] Unable to load plugin "l4d2_rescue_heal.smx": Native "SH_AddWallet" was not found`
- **原因**: `SH_AddWallet` native 由 l4d2_si_hud 插件提供，但加载顺序依赖
- **状态**: 每次启动都报，reload 后可恢复（依赖 l4d2_si_hud 先加载）

### 2. specialspawner.smx 持续报错 — ✅ v5.37 已根治（2026-08-20）
- **错误**: `[SM] Exception reported: Invalid timer handle 42f00ac1 (error 1)`
- **位置**: specialspawner.sp Line 2018 `ExecuteSpawnQueue` → Line 1745 `tmrSpawnSpecial`
- **频率**: 约每 35-40 秒一次，刷满错误日志
- **影响**: 日志膨胀，且换图后会升级成「整波 0 特感」（char）——
  根因 `g_hReserveTimer`(TIMER_FLAG_NO_MAPCHANGE) 换图被引擎杀后变量残留 → 2018 行 KillTimer 抛异常
  中止 ExecuteSpawnQueue → SpawnSliced 不执行。已在 `ResetLifecycle()` 补 KillTimer+null（见
  [[l4d2-specialspawner-config]] v5.37 一节）。临时救场 = `sm plugins reload specialspawner`。

### 3. rcon-init.sh 启动注入失败
- **错误**: `rcon-init.log` 显示 `FAILED after retries`
- **原因**: 服务器启动后 60s 内 RCON 可能还没完全就绪，或 rcon.password 未生效
- **当前状态**: 手动 `rcons.py` 可连，说明 RCON 本身正常，只是启动时序问题

## 关键规则

1. **spcomp 是 32 位**（路径固定在 `scripting/spcomp`），但 .smx 产物兼容 64 位 SM
2. **cfg 注释不能用中文/em dash** — 会导致 Unknown command 刷屏
3. **热加载不等于换图** — 部署新 `.smx` 后用 `sm plugins reload` 而不是重启 srcds
4. **三方地图 VPK 需重启 srcds** — 引擎启动时扫描 addons/ 下的 VPK，运行时不扫描
5. **RCON 密码用纯字母数字** — 避免 SRCDS 命令行解析截断

## 关联
- [[l4d2-howto-plugins]] — 插件管理详细指南
- [[l4d2-rcon-filename-pitfall]] — rcon.py 文件名冲突坑
- [[l4d2-rcon-password-pitfall]] — RCON 密码特殊字符坑
- [[l4d2-deployment-rules]] — 部署 checklist
- [[l4d2-permissions-pitfall]] — 权限 700 坑
- [[l4d2-32bit-architecture-pitfall]] — 32 位架构坑
