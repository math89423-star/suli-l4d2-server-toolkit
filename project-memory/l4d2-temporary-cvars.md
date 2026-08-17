---
name: l4d2-temporary-cvars
description: L4D2 服务器当前固化 cvar 配置（已持久化）
metadata:
  node_type: memory
  type: project
  originSessionId: a0b69a37-fcbe-470f-8751-b20663a0a8a9
  modified: 2026-07-27T02:16:28.878Z
---

## 当前固化配置（2026-07-24，最终版，已写配置文件 + 重启验证）

### 友伤（按难度，sm_ff_multiplier=1.0 直出）

| 难度 | `survivor_friendly_fire_factor_*` | 插件乘数 | 有效友伤 |
|------|------|----------|----------|
| Easy | 0.02 | 1.0 | 2% |
| Normal | 0.04 | 1.0 | 4% |
| Hard | 0.08 | 1.0 | 8% |
| Expert | 0.15 | 1.0 | 15% |

### 特感

| cvar | 值 | 配置文件 |
|------|-----|----------|
| `ss_time_min` | `45.0` (RCON 临时) `35.0` (文件) | `sourcemod.cfg` |
| `ss_time_max` | `60.0` (RCON 临时) `50.0` (文件) | `sourcemod.cfg` |
| `ss_time_mode` | `0`（随机） | `sourcemod.cfg` |
| `ss_extra_limit` | `1.5` | `sourcemod.cfg` |
| `ss_si_limit` | `28` | `sourcemod.cfg` |

### 其他

| cvar | 值 | 配置文件 |
|------|-----|----------|
| `z_common_limit` | `60` (RCON 临时) `60` (文件) | `sourcemod.cfg` |
| `sm_respawn_delay` | `35` | `l4d2_auto_respawn.cfg` |

### 回滚命令（恢复文件值）

```bash
python3 -c "
from rcon.source import Client
with Client('127.0.0.1', 27015, passwd='Nxp4HJ1xE2Jtzjng') as client:
    client.run('sm_cvar ss_time_min 35')
    client.run('sm_cvar ss_time_max 50')
    client.run('sm_cvar z_common_limit 60')
    print('已恢复')
"
```

### 公告文本同步

- `advertisements.txt` — 聊天栏轮播广告（Y键打开聊天可看到）
- `motd.txt` — H键/!motd 公告面板
- `auto_motd.sp` — 玩家加入欢迎消息
