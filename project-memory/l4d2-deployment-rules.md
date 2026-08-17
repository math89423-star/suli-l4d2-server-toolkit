---
name: l4d2-deployment-rules
description: L4D2 服务器部署的六条铁律和综合踩坑清单（来自上一台服务器的血泪教训）
metadata: 
  node_type: memory
  type: reference
  tags: 
    - l4d2
    - docker
    - pitfall
    - lessons-learned
  originSessionId: 4b3417fe-a874-420c-b976-80f0ddfa0c75
  modified: 2026-08-04T06:32:38.493Z
---

# L4D2 服务器部署踩坑全景

## 六条铁律

| # | 铁律 | 一句话 |
|---|------|--------|
| 1 | 客户端别折腾地图 | VPK 丢 addons 就行，别让玩家提取 BSP |
| 2 | 禁止拆包 | VPK 没问题，出问题一定是配置/方法有误 |
| 3 | 三个月教程 = 过时 | 当前 2026.7，4 月前的教程视为无效 |
| 4 | 插件警告 ≠ 无效 | l4dmultislots 报 maxplayers not 31 是 cosmetic |
| 5 | 别跟 L4DToolZ 较劲 | sv_setmax 硬编码最小 18，别反复试 |
| 6 | 先找根因再修症状 | 很多崩溃修了边角料，根因是宿主机 OOM |
| 7 | **metamod.vdf 是命根子** | 缺失 → MetaMod 不加载 → SourceMod 全废 → 所有 sm_cvar/插件无效 |
| 8 | **换图永不用重启容器** | `changelevel`/`sm_map` 通过 RCON 在线切，down+up 只在改 volumes 时用 |
| 9 | **禁止用 `map` 命令** | `map <地图>` 会踢掉所有玩家，必须用 `sm_map` 或 `changelevel` |
| 10 | **轮询** | 官图→下一官图（c1→c14→c1）；三方图终章→切回 c1m1 再走官图轮询 |
| 11 | **禁止重建容器** | `docker compose down` 必须有充分理由（改 volumes/端口），不得无故重建 |
| 12 | ~~测试图必须关多特感~~ | **已废除（2026-07-28）**。四个特感插件（AI_HardSI、specialspawner、spawn_infected_nolimit、si_composition_manager）现已兼容无 nav mesh 地图，直接切图即可 |
| 13 | **被指正时先查记忆** | 但凡用户指正/纠正/质疑，立即停下来查铁律→查记忆→查踩坑清单，确认没有已知方案后再动手 |
| 14 | **c14 在 update 目录** | The Last Stand 地图不在 left4dead2/maps/，在 `/server/update/maps/`（c14m1_junkyard + c14m2_lighthouse），引擎自动加载不受 bind mount 影响 |
| 15 | **cvar 含义先用 RCON 验证** | 第三方插件的 cvar 文档/注释可能写错。改值前 `sm_cvar <name>` 看实际描述，不同插件的同名 cvar 含义可能完全不同 |

**模式标记依赖（2026-08-04 起）**：`switch-to-official.sh` / `switch-to-custom.sh` 写入 `addons/sourcemod/configs/current_mode.txt`（official/custom），**si_hud v1.10.1 依赖它判定三方图轮换豁免清零**。切轮询模式必须跑对应脚本（不能只手动 sm_map），标记滞后会导致三方图轮换行为不一致（兜底② 仅按地图命名保护非官图命名图，官图命名的三方图如 c3m1_jungle 需要文件=custom 才豁免）。

## 第 7 条详解：metamod.vdf

`addons/metamod.vdf` 是 Source 引擎加载 MetaMod 的唯一入口。此文件不存在时：

- MetaMod 不加载 → SourceMod 不加载 → 65 个插件全部失效
- `sm_cvar` 不执行 → 所有 cheat cvar（后坐力、友伤等）恢复默认值
- 服务器进入"假死"状态：端口在监听，进程在运行，但连接无响应

**常见误删场景**：删除 `metamod_x64.vdf` 时误删了 `metamod.vdf`。恢复方法：
```
echo '"Plugin"{"file"  "addons/metamod/bin/server"}' > addons/metamod.vdf
```

## 第 8 条详解：换图 vs 重启

| 操作 | 正确方式 | 错误方式 |
|------|---------|---------|
| 换地图 | `changelevel <map>` 或 `sm_map <map>` | ~~docker restart / down+up~~ |
| 连续切换 ≥3 次三方图 | **`docker restart` 必须**（String Table 损坏） | sm_map 继续切（客户端连不上） |
| 新增 volumes 挂载 | `down + up`（唯一需要重建的场景） | - |
| 改 docker-compose 参数 | `restart` | `down+up` 也可以但多余 |
| 新增 .smx 插件 | `restart` | `down+up` 多余 |

## 第 9 条详解：禁止用 `map` 命令

**`map <地图>` 会踢掉所有玩家再加载地图**，和 `sm_map`/`changelevel` 完全不同：

- `changelevel` / `sm_map` — 保留玩家，平滑切换到新图
- `map` — 重置服务器状态，所有客户端断开

**RCON 换图标准方法**（python3-rcon，需要 `apt install python3-rcon`）：
```python
python3 -c "
from rcon.source import Client
with Client('127.0.0.1', 27015, passwd='Nxp4HJ1xE2Jtzjng') as client:
    print(client.run('sm_map tumtara'))
"
```

## 第 11 条详解：禁止重建容器

**任何 `docker compose down` 必须有充分理由**，无故重建是最大禁忌。唯一允许重建的场景：

| 允许 | 理由 |
|------|------|
| 新增/删除/修改 `volumes` 挂载 | bind mount 只有容器创建时生效 |
| 修改 `ports` 映射 | 端口绑定只有容器创建时生效 |
| 修改 `network_mode` | 网络模式只有容器创建时生效 |

以下场景**严禁**重建：
- 换地图 → `sm_map` / `changelevel`
- 换插件 → 卸旧装新后 `sm plugins refresh`
- 重启服务器 → 直接杀进程（容器自动重启）或 `sm plugins reload`
- 改配置 → `sm plugins reload` 或 `sm_cvar` 在线生效
- 容器挂了 → 先查原因，`start` 而非 `down+up`

## 第 12 条详解：~~测试图必须关多特感~~（已废除）

**2026-07-28 更新：四个特感插件（AI_HardSI、specialspawner、spawn_infected_nolimit、si_composition_manager）现已兼容 tumtara 等无 nav mesh 地图。** 此前切 tumtara 需要卸载插件是其他 bug 导致，已在后续修复中解决。直接 `sm_map tumtara` 即可，无需卸载任何插件。

## 第 13 条详解：被指正时先查记忆

用户每次纠正/质疑时，**先停下来查记忆文件**，不要着急动手。标准流程：
1. 看铁律（`l4d2-deployment-rules`）— 是否已有禁止或必须的规则
2. 看相关记忆 — 是否已有现成做法
3. 看踩坑清单 — 是否已知坑
4. 确认没有已知方案后，再问用户或动手

**绝对禁止**在被指正时：
- 说"你说得对"后继续按错误方式操作
- 不查记忆就重新发明/猜测方案
- 绕过记忆文件里的已知方法

## 第 14 条详解：c14 的位置

这个 Docker 镜像（`left4devops/l4d2`，2026-07-25 已从 `jackzmc/srcds-l4d2` 迁移，见 [[l4d2-docker-migration]]）把 The Last Stand 单独放在 `update/` 目录：

```
/home/louis/l4d2/left4dead2/maps/         ← c1-c5（被 bind mount 覆盖，需要保留官图 BSP）
/home/louis/l4d2/left4dead2_dlc1/maps/    ← c6（不受 bind mount 影响）
/home/louis/l4d2/left4dead2_dlc2/maps/    ← c7-c8
/home/louis/l4d2/left4dead2_dlc3/maps/    ← c9-c13
```

## 第 15 条详解：cvar 含义先用 RCON 验证

**不要相信任何文档/注释/记忆文件里第三方插件的 cvar 含义**，包括自己写的。记忆文件和代码注释是人类写的，可能基于错误假设。只有插件的实际行为是真相。

触发条件：
- 修改任何 cvar 前
- 自己写/改插件代码时假设了某个 cvar 的含义
- 任何"奇怪的行为"（如特感不停刷新）— 先查 cvar 实际含义

验证方法：
```
RCON: sm_cvar <cvarname> → 查看插件的 cvar 注册描述
RCON: find <cvarname> → 查看实际运行值
```

**已知踩坑案例（2026-07-27）：**
`ss_time_mode` 被设为 `1`，记忆文件写"1=随机间隔"。但 specialspawner 的实际定义：
| 值 | 实际行为 |
|---|---|
| 0 | 随机间隔 random(min, max) |
| 1 | 递增模式 — 杀越快刷越快 |
| 2 | 递减模式 — 杀越慢刷越快 |

mode 1 下生还者清怪快 → 间隔缩短 → 更快 → 间隔趋近于 0 → "不停刷特感"。

14 张官图完整清单：
| 战役 | 地图 | 存储位置 |
|------|------|---------|
| c1 Dead Center | c1m1_hotel | left4dead2/maps/ |
| c2 Dark Carnival | c2m1_highway | left4dead2/maps/ |
| c3 Swamp Fever | c3m1_plankcountry | left4dead2/maps/ |
| c4 Hard Rain | c4m1_milltown_a | left4dead2/maps/ |
| c5 The Parish | c5m1_waterfront | left4dead2/maps/ |
| c6 The Passing | c6m1_riverbank | dlc1/maps/ |
| c7 The Sacrifice | c7m1_docks | dlc2/maps/ |
| c8 No Mercy | c8m1_apartment | dlc2/maps/ |
| c9 Crash Course | c9m1_alleys | dlc3/maps/ |
| c10 Death Toll | c10m1_caves | dlc3/maps/ |
| c11 Dead Air | c11m1_greenhouse | dlc3/maps/ |
| c12 Blood Harvest | c12m1_hilltop | dlc3/maps/ |
| c13 Cold Stream | c13m1_alpinecreek | dlc3/maps/ |
| c14 The Last Stand | c14m1_junkyard | update/maps/ |

### 架构：三个插件分工

| 插件 | 职责 | 触发条件 |
|------|------|---------|
| `l4d2_campaign_progression.smx` | 战役中途切关（m1→m2→...→m5） | `round_end`（通关安全门） |
| `campaign_transition.smx` | 终章→下一战役 | `finale_win` |
| `mapchooser.smx` + `nominations.smx` | 投票换图 | 玩家发起投票 |

### 轮询逻辑（campaign_transition.sp v1.3 实现，2026-08-02 更新）

1. 终章胜利 → 检查 `sm_nextmap`（投票结果）
2. 如果有投票结果 → 不干预
3. 判断当前战役第一关是否在官方 14 战役列表中：
   - **官图** → 按顺序切到下一个官方战役第一关（c1→c2→...→c14→c1）
   - **三方图** → 一律切回 `c1m1_hotel`，再走官图轮询（不再用 mapcycle.txt 三方图连转）
4. 8 秒延迟后 `ServerCommand("changelevel %s")` 切图（**不用** ForceChangeLevel，会踢人）

### ⚠️ 插件冲突（实测 2026-08-01 夜）

- `sm_l4d_mapchanger.smx`（L4D2 Force Mission Changer v2.3，**未禁用**，仍在加载）
  和 campaign_transition 冲突：终章时它 10s 后强制 changelevel 到 `sm_l4d_fmc_def`
  （c2m1_highway），与轮询结果不同 → 4s 内二次切图踢人
- **消冲突配置**：`sm_l4d_fmc_ChDelayCOOP_final "0"`（关终章强制切图）+
  `sm_l4d_fmc_announce "0"`（关 [TS] 播报，避免与 [战役结束] 播报矛盾）
- mapchanger 保留团灭处理 `sm_l4d_fmc_crec_coop_map/final "4"`
  （容器未部署 l4d2_wipe_mapchange.smx，mapchanger 是唯一团灭兜底）

### mapcycle.txt 现状
- `mapcycle.txt` 只有 nanningcity_bridge_m6 / zc1_m1，已不参与三方图轮询
  （v1.3 起三方图终章直接回 c1m1），仅剩引擎 nextmap 显示用

## 核心踩坑清单

### 网络/容器
1. **`--net=host` 兼容问题** → 用 bridge + 端口映射（不是 host 网络！）
2. `create pipe failed` 是误导，不用管
3. `+hostip` L4D2 不识别

### 插件加载
4. **fdxx L4DToolZ v0.5.2 VDF 放错目录**（放了 metamod/ 而不是 addons/）→ 完全未加载
5. server.cfg vs sourcemod.cfg 分离：cheat cvar 必须用 `sm_cvar`
6. sv_allow_lobby_connect_only 0 下引擎不读 mission，需要 campaign_progression.smx 接管换图

### 崩溃类
7. c3m1 崩溃根因 → 先查 `dmesg | grep oom`（宿主机 OOM，不是地图问题）
8. **Cbuf_AddText buffer overflow** → cvars 丢弃、客户端连不上、崩溃死循环
   - L4B 刷 200 行 settings → 删
   - sm_weapon 60 行 + sm_cvar 回声 66 行 → Buffer Overflow Fixer 插件解决
   - em dash — 破坏 // 注释：Unicode 后面的 ASCII 被当命令执行
9. campaign_state.txt：l4d2_map_remember 写死上次地图 → 重启后强制切回 → 目标图崩溃循环
10. ~~specialspawner 在无 nav mesh 地图 (tumtara) 上 → 空指针 → segfault~~ **已修复（2026-07-28），四个特感插件现已兼容**

### 配置类
11. server.cfg 执行时机在 DLL 加载前，大量 cvar 被丢弃 → 必须用 sm_cvar 放 sourcemod.cfg
12. hostname 的真正来源是 `addons/sourcemod/data/hostname.txt`（`l4d2_sethostname.smx` 每次换图覆盖）
13. **VPK 直接放 addons** → 非工坊图引擎自己从 VPK 加载一切，不提取不拆分
14. **工坊图不放 VPK** → 避免与客户端工坊自动更新版本冲突
15. 换图不删旧 VPK → 资源推送毒害所有连接
15. 插件 cfg 中文注释 → "Unknown command" 刷屏 836 条/天
16. sm_map 只能切战役第一关，同战役内跳关会丢失战役上下文

### 性能
17. datacache 默认 256MB，MOD 多打到 97%+ → -heapsize 翻倍
18. `z_friendly_fire_forgiveness 1` → 特感多时所有友伤被判断为"误伤" → 伤害清零

### OOM 诊断
19. **`dmesg | grep oom` 永远先看**，再排查插件
20. c3m1 崩溃循环：OOM→崩溃→重启→c3m1(大图)→OOM→崩溃→...

## 新服务器部署 checklist

- [ ] 用 bridge 网络 + 端口映射（不用 host 网络）
- [ ] L4DToolZ VDF 放 addons/ 不是 metamod/
- [ ] **删除 metamod_x64.vdf**（32 位 srcds 不兼容 64 位）
- [ ] **提取镜像默认 cfg 文件**（valve.rc 等 46 个文件，挂载会覆盖）
- [ ] **RCON 密码用纯字母数字**，不含 `+` `-` `=` 空格
- [ ] **启动参数加 `-condebug`**，确保 docker logs 可看到输出
- [ ] server.cfg 只保留基础设置，其余放 sourcemod.cfg（sm_cvar）
- [ ] 检查所有 .cfg 文件是否有中文/em dash 注释
- [x] ~~specialspawner 在无 nav mesh 地图预先禁用~~ 已修复，无需禁用
- [ ] -heapsize 根据可用内存调整
- [ ] `dmesg | grep oom` 确认无 OOM
- [ ] **编译 l4d2_tickrate_enabler.smx**（源码在 scripting/ 不等于生效）
- [ ] 确认 l4dtoolz 不创建 sv_tickrate，插件源码要 null-check
- [ ] server.cfg 不写 sv_minupdaterate / sv_maxupdaterate（L4D2 不存在）
- [ ] RCON 延迟注入 nb_update_frequency 确认生效
- [ ] **chmod -R 755 addons/**（louis 用户 UID 1000 需要读权限，写权限见 [[l4d2-docker-migration]]）
- [ ] 换 RCON 密码后同步更新全部引用位置（docker-compose.yml, server.cfg, 记忆文件）

## 新坑（2026-07-18 踩坑记录）

### 霰弹枪射速/换弹
- `sm_weapon cycletime` + `sm_weapon reloadduration` **对喷子无效** — 引擎不走武器属性接口
- 正确方案：**WeaponHandling 插件** (`WH_OnReloadModifier` / `WH_OnGetRateOfFire`)
- 插件 `l4d2_shotgun_speed.smx` + `l4d2_shotgun_speed.cfg` 控制，cvar 改值即刻生效
- WeaponHandling gamedata 必须从 GitHub 拉取（本地的 `WeaponHandling.txt` 是 404 下载失败的空壳）

### 友伤 cheat cvar 被引擎忽略
- `survivor_friendly_fire_factor_hard` 等 4 个 cvar 是 `game cheat`，`sm_cvar` 能改值但引擎可能不应用
- 正确方案：**SDKHooks_TraceAttack** 直接拦截伤害，`l4d2_ff_fix.smx`
- `z_friendly_fire_forgiveness` 逻辑反直觉，删掉走默认最安全

### 火焰友伤被 z_friendly_fire_forgiveness 清零（2026-07-20）
- `z_friendly_fire_forgiveness = 1` 使引擎判定火焰为"非故意"→ 伤害清零
- 枪支走 `TraceAttack`（在 forgiveness 之前），火焰走 `OnTakeDamage`（在 forgiveness 之后）
- **`sm_cvar` 改此 cvar 无效**（game cheat），启动参数 `+z_friendly_fire_forgiveness 0` 也无效
- **正确修复**：`l4d2_ff_fix.smx` v1.3 对火焰用和枪支相同的"清零+重放"模式
  - `OnTakeDamage` 收到火焰伤害 → 清零原值 → `SDKHooks_TakeDamage` 重放 → 绕开 forgiveness
  - 用 `g_bInFireHook[]` 标记防止递归
- 火焰友伤倍率：`inferno_damage(55) × survivor_burn_factor_hard(0.5) = 27.5 DPS`

### 霰弹枪散布
- `sm_weapon scatterpitch/scatteryaw` **对喷子无效** — 和 cycletime 同样原因
- 暂无服务器端修改方案

### Tank HP 显示不同步
- `Tank HP Scaler` 改 `m_iMaxHealth`（实际血量），但 UI 读 `l4d2_tank_health` cvar
- 修复：HP Scaler 设置血量后同步 `l4d2_tank_health` cvar

### 推搡疲劳整数除法
- 原版 `/3` → `2/3=0`（整数除法）→ 疲劳完全清零，无限制
- 改为 `/2` → `2/2=1` → 轻微疲劳，有节制

### 60-Tick + 30Hz 僵尸不生效（2026-07-21）
- `l4d2_tickrate_enabler.smx` 源码在 `scripting/` 但**从未编译** → 60-tick 网络 cvar 全是默认值，启动参数 `-tickrate 60` 形同虚设
- fdxx 的 l4dtoolz **不创建 `sv_tickrate` cvar**，插件 `SetConVarInt(FindConVar("sv_tickrate"), ...)` 导致 null 崩溃
- `sv_minupdaterate` / `sv_maxupdaterate` 在 L4D2 **不存在**（CS:GO 专属），server.cfg 写了会报 Unknown command
- **正确架构**：l4dtoolz（引擎解锁）+ l4d2_tickrate_enabler.smx（网络 cvar）+ l4d2-start.sh / rcon-init.sh（RCON 延迟注入 nb_update_frequency），三组件缺一不可
- 详见 [[l4d2-tickrate-setup]]

### 轮询（v1.3 起）
- `Campaign Finale Auto Transition` v1.3：官图→下一官图；**三方图终章→切回 c1m1**，然后官图轮询
- 播报源唯一：`[战役结束]`（campaign_transition）；mapchanger [TS] 播报已关（announce=0）
- 播报全清单（2026-08-02 排查）：campaign_transition（轮询）/ mapchanger [TS]（已关）/
  basetriggers !nextmap（引擎 nextmap，与轮询无关）/ vote_manager3（投票通过提示）

### mapcycle.txt
- 不再参与三方图轮询（v1.3 起），仅剩引擎 nextmap 显示用

## 关联
- [[l4d2-permissions-pitfall]] — 文件权限 700 导致 steam 用户无法读取
- [[l4d2-32bit-architecture-pitfall]] — 32 位 srcds + 64 位 metamod_x64.vdf 冲突
- [[game-server-deployment-plan]] — 整体部署计划
