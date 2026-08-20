---
name: l4d2-specialspawner-config
description: specialspawner 特感刷新控制器的全部 cvar 和调参指南（v1.7.0 三段定向+分批释放；v1.6.0 方向随机化；v1.5.0 倒地补偿；v1.4.0 分散刷+LOS过滤）
metadata: 
  node_type: memory
  type: reference
  modified: 2026-08-04T17:10:39.591Z
  originSessionId: 8be29424-bfe9-42be-82e0-ad49b8009603
---

# L4D2 Special Spawner 配置

specialspawner.smx 是服务端的特感刷新控制器，替代 L4D2 原版 Director 的刷新逻辑。
它控制特感数量上限、刷新间隔、刷新距离（安全区）、各类特感权重等。

**配置文件：** `cfg/sourcemod/specialspawner.cfg`

## 核心 cvar

### 刷新距离（安全区）— 防止贴脸刷新

| cvar | 当前值 | 说明 |
|---|---|---|
| `ss_spawnrange_min` | 200.0 | SI 复活位置距离最近生还者的**最小距离**（单位），防贴脸刷新 |
| `ss_spawnrange_max` | **900.0**（2026-08-03 由 1500 下调，缩小出生距离） | SI 复活位置距离最近生还者的**最大距离**（单位） |
| `ss_rush_distance` | 1500.0 | SI "冲刺模式"触发距离 |

**安全区历史：**
- 旧值：`ss_spawnrange_min 100` — 近战范围，贴脸刷新，生还者零反应时间
- 中值（2026-07-27 初）：`ss_spawnrange_min 500` — 过大，引擎找不到合法出生点，静默丢弃 spawn
- 新值（2026-07-27 修订）：`ss_spawnrange_min 200` — 平衡距离和可用出生点

### 特感数量

| cvar | 当前值 | 说明 |
|---|---|---|
| `ss_base_limit` | **8**（2026-08-04 1人2特拍板，原 6） | 基础 SI 同时存活上限（≤4 生还者时） |
| `ss_base_size` | 4 | 基础生还者人数 |
| `ss_extra_limit` | **2.0**（2026-08-04 1人2特拍板，原 1.5） | 每增加 N 个生还者，额外增加的 SI 数 |
| `ss_extra_size` | 1 | 生还者增量单位 |
| `ss_si_limit` | **32**（cvar 声明 max=32，设 48 被钳回；类别上限合计 22 先绑，32 永不触发） | 全局 SI 同时存活上限（SetSpawnCount 按 8+2×(人数−4)=2N 动态覆写） |
| `ss_spawn_size` | **8**（2026-08-04 1人2特拍板，原 6） | 每波刷新 SI 数量（si_comp AdjustSpawnSize 按 8+2×(N−4)=2N 覆写，下限 4） |

**v5.1 1人2特（2026-08-04 热应用，用户拍板）**：公式 = 2×人数（上限+波次同源）。
类别上限均衡放宽：boomer 3 / spitter 3 / smoker 4 / hunter 4 / jockey 4 / charger 4
（合计 **22**）→ **11 人以下严格 1人2特，大房封 22**。Tank 存活时仍走
ss_tankstatus_limits（2;2;2;2;3;3=14，刻意压小）。生效链路：exec cfg → cvar
AddChangeHook 热刷新 specialspawner 缓存；si_comp 需 reload 重捕获 ss_spawn_size
基线（g_fCfgBaseSpawnSize）。全局 ss_si_limit 声明 max=32 是死钳，别设 48。
| `ss_incap_compensation` | **1.0**（v1.5.0 新增，0=关闭/1=全比例/0-1=插值） | 倒地补偿：刷怪瞬间按 站立/总人数 比例收缩波次与有效上限，见 v1.5.0 节 |

### 刷新时机

| cvar | 当前值 | 说明 |
|---|---|---|
| `ss_first_time` | 15.0（2026-08-04 实测生效值，反超 sm_cvar 20.0） | 离开安全屋后首次刷特感的延迟（秒） |
| `ss_time_min` | **40.0**（2026-08-05 由 35 上调，用户拍板 40-55s/波） | 波次间最小间隔（秒）——被 si_comp 每图捕获（OnConfigsExecuted）每波钉死 min=max=随机区间值 |
| `ss_time_max` | **55.0**（2026-08-05 由 50 上调，同上） | 波次间最大间隔（秒）——同上；实测曾钉到 54.4 |
| `ss_time_mode` | 0 | 计时模式：**0=随机间隔 random(min,max)**，1=递增(杀越快刷越快)，2=递减(杀越慢刷越快)。composition manager 要求 mode 0。 |
| `ss_suicide_time` | **25.0**（2026-08-03 由 20 上调，用户拍板；cfgs 双改） | SI 不攻击后自动自杀时间（秒） |

### 各类特感独立上限 & 权重

| 特感 | limit cvar | weight cvar | 当前上限 | 当前权重 |
|---|---|---|---|---|
| Boomer | `ss_boomer_limit` | `ss_boomer_weight` | 3（2026-08-04 1人2特放宽） | 150 |
| Charger | `ss_charger_limit` | `ss_charger_weight` | 4（同上） | 100 |
| Hunter | `ss_hunter_limit` | `ss_hunter_weight` | 4（同上） | 100 |
| Jockey | `ss_jockey_limit` | `ss_jockey_weight` | 4（同上） | 100 |
| Smoker | `ss_smoker_limit` | `ss_smoker_weight` | 4（同上） | 100 |
| Spitter | `ss_spitter_limit` | `ss_spitter_weight` | 3（同上） | 150 |

权重越高，该类型特感越容易被选中刷新。Boomer 和 Spitter 权重 150 > 其他 100。

### Tank 状态相关

| cvar | 当前值 | 说明 |
|---|---|---|
| `ss_tankstatus_action` | 1 | Tank 存在时的行为：0=不变，1=按 tankstatus 调整 |
| `ss_tankstatus_limits` | 2;2;2;2;3;3 | Tank 在不同状态下的 SI 上限 |
| `ss_tankstatus_weights` | 100;400;100;200;100;100 | Tank 状态下各类 SI 权重 |

### 权重缩放

| cvar | 当前值 | 说明 |
|---|---|---|
| `ss_scale_weights` | 1 | 是否按生还者人数缩放权重 |

## 生效方式

specialspawner 在换图时重新读取配置，不需要重启服务器。

### ⚠️ 双 cfg 覆盖坑（2026-08-03 实测；⚠️ 2026-08-04 更正方向）

`sourcemod.cfg` 第 69-75 行有 `sm_cvar ss_base_limit 8 / ss_extra_limit 1.5 / ss_si_limit 32 /
ss_first_time 20.0 / ss_suicide_time 25.0`（ss_time_* 已注释移除，交 si_comp 钉值）。
**2026-08-04 实测更正**：插件 cfg 在换图时后执行 → **specialspawner.cfg 赢**（live:
base_limit 6 反超 8、first_time 15.0 反超 20.0、suicide_time 25 两边一致）。
改 cvar 后以 RCON 直查 `ss_xxx` 为准，别信 cfg 文件里的值（可能被任一边覆盖）。
ss_spawnrange_max / ss_incap_compensation 无 sm_cvar 覆盖，cfg 直接生效。

### 战役模式无 ghost 等待（2026-08-03 用户纠正）

`z_ghost_delay_min/max`（实测 20/30，引擎默认，不在任何 cfg）= **对抗模式**玩家幽灵重生
延迟，战役 bot 不走这条链路。别用它推战役行为结论。战役"远处刷新不动被处决"=
实体化卡住(NAV)或 BT 站桩（Boomer ambushSeq 已修 v4.1.1，见 [[l4d2-ai-hardsi-engine-tuning]]）。

## v1.3.8 贴脸修复（2026-08-03 晚，已热重载）

**根因**：刷点用 `L4D_GetRandomPZSpawnPosition(client, index, 10, vPos)`（left4dhooks → 引擎
CZombieManager::GetRandomPZSpawnPosition）——引擎只保证落点离**领跑者**（flow 最高的生还者）
≥ z_safe_spawn_range（200，= ss_spawnrange_min 写入），**其余生还者完全没查** → 4 人抱团时
贴脸刷实锤。顺带修复 find 累积 bug：某只取点失败时 find 还是上只的 true + vPos 残留上只坐标
→ 两只刷同一点。

**修复（v1.3.8）**：新增 `ss_spawnrange_guard`（**400.0**，0=关闭）——落点必须离**所有**存活
生还者（含倒地，3D 距离）≥ 守卫值，单只重掷 10 次（SPAWN_GUARD_MAX_TRIES），重掷耗尽仍无
安全点 → 本只跳过等下波（绝不贴脸，不会像 500 那样整体静默）。命中统计 LogMessage `[SS]
spawn guard: N/M skipped`。源码已入 scripting/specialspawner.sp（原 v1.3.7 来自
github.com/LaoYutang/l4d2-server-next，之前本机无源码）；备份 /tmp/specialspawner.smx.bak.v1.3.7。

**引擎 cvar 链路（TweakSettings 启动时写入）**：ss_spawnrange_min→z_safe_spawn_range(200)、
ss_spawnrange_max→z_spawn_range(900)、z_discard_range=900+500(1400)；z_spawn_safety_range(550)
是 Director 自己的安全距离，与 L4D_GetRandomPZSpawnPosition 无关（别混淆）。

## v1.4.0 守卫 v3：分散刷 + LOS 过滤防处决（2026-08-03 22:40 热重载，commit 0bdc10a）

**v1.3.9 的处决坑（玩家实测"刷新基本都被处决"）**：随机参照者已分散刷点，但保底 250
点常刷在**队伍侧后方** → 看不见生还者 → `m_hasVisibleThreats` 恒 false → tmrForceSuicide
25s（ss_suicide_time）无可见威胁无目标 → KillInactiveSI 处决。**处决 = 刷点 LOS 差**，
不是安全区问题。用户拍板方向：**不围绕领跑者刷，必须分散刷**（只围绕领跑者 = 自杀
无解 + 堆怪）。

**v1.4.0 修复**：
- 每只特感独立随机参照者（survivors[] 全队随机，GetRandomInt）→ 刷点散布全队周边
- **LOS 过滤**：候选点必须能看见至少一个生还者（`TR_TraceRayFilter` MASK_VISIBLE
  RayType_EndPoint + `TRFilter_SkipPlayers` 排除玩家实体）→ 看得见 = 有威胁 = 不处决
- 分层放行：≥guard(400)且可见 > ≥guard_min(250)且可见（bestVisible 追踪）> 250
  不可见兜底（窄室内 AI 自行转向，防饿死）> 跳过
- 热重载验证：22:40 后特感正常被击杀（streak 结算），errors 零新异常

**顺带发现（非本次修）**：Defib_Fix.sp（用户自己的未提交插件）22:21/22:38 有
DHookCreateFromConf 签名错误在报——用户插件的坑，别动。

## v1.3.9 守卫 v2：参照点随机化 + 250 保底（2026-08-03 23:00 前热重载，commit 2025161）

**v1.3.8 引入的饿死坑（实测）**：守卫重掷循环固定用**领跑者**做引擎参照点
（L4D_GetRandomPZSpawnPosition 生成点只围绕参照者 200-900 转）。多人队伍拉长/密集时，
领跑者周边环带全是队友 → 10 次重掷全灭 → **整波零刷新 + 1s retry 死循环**（22:15-22:23
连续 8 分钟 100% 全跳日志：7/7、8/8、6/6）。跟旧 ss_spawnrange_min 500 的静默丢弃是
同一个坑，只是从引擎丢变成守卫丢。**多人且分散 = 触发条件**（队伍越长领跑者 900 环带
覆盖队友越多）。

**v1.3.9 修复**：
- 每只特感每次重掷**随机换生还者做参照**（survivors 数组，GetRandomInt）→ 候选点散布
  全队周边，不再只围着领跑者转
- 优先 ≥`ss_spawnrange_guard`(400)；10 次耗尽改取 ≥`ss_spawnrange_guard_min`(**250.0**，
  新 cvar) 的最佳点保底放行（防饿死，仍远低于贴脸阈值）；仍无 → 本只跳过
- `DistanceToNearestSurvivor`（3D，含倒地）替代 IsSpawnPosClearOfSurvivors
- 日志区分：`[SS] spawn guard: X skipped, Y fallback(>=250), prefer >=400`
- **热重载兜底**：刷怪 timer 链只在 L4D_OnFirstSurvivorLeftSafeArea_Post 启动，reload
  后事件不重发 → 停刷到换图。OnMapStart 用 `L4D_HasAnySurvivorLeftSafeArea()` 检测后
  重建 spawn timer + suicide timer
- 热重载验证：22:33 reload 后 22:34 有特感被击杀（streak 结算），链工作正常
- cfg 同步：specialspawner.cfg 新增 ss_spawnrange_guard_min "250.0"；sourcemod.cfg
  无 sm_cvar 覆盖 guard（确认过）

## v1.5.0 倒地补偿（2026-08-04 部署，热重载验证通过）

**需求**：10 人 5 倒时若不修正，5 个站立玩家面对 15 只特感 ≈ 3 倍，极易团灭。
**方案**：刷怪瞬间（ExecuteSpawnQueue）按 `ratio = 站立/总人数` 收缩波次与有效上限，
强度 cvar `ss_incap_compensation`（默认 1.0 全比例，0=关闭，0.5=半补偿线性插值）。

- **有效上限收缩**：`effLimit = round(ss_si_limit × scale)`，存活特感 ≥ effLimit →
  本波跳过（不再往倒地队伍上堆）；**波次收缩**：`spawnSize × scale`，保底 1 只
- **实时计算不写 cvar** → 复活后下一波自动恢复，无陈旧值；无 cvar 写入也就没有
  和 si_comp 的 AdjustSpawnSize（写 ss_spawn_size）打架
- 坑：`IsPlayerAlive` 对倒地返回 true → 必须用 `m_isIncapacitated` 区分站立人数
  （源码注释已写明）
- 观测：LogMessage `[SS] incap comp: N/M 倒地, 波次 X→Y, 上限 L→K`（跳过/缩减两场景）
- **si_comp v2.3.8 播报镜像**：AnnounceWave 同一公式算实际数量，
  显示 `特感已刷新 5只(倒地补偿 10→5)!`——改公式必须两处同步（注释已标）
- 实测 2026-08-04：10 人 5 倒 → ratio 0.5 → 上限 15→8、波次 10→5，站立 5 人面对 ≤8

## v1.6.0 方向随机化（2026-08-04 部署）

**问题**：玩家实测"特感只会刷新在正前方，不会从各位置随机来"。
**方向链路（关键）**：引擎每次 `L4D_GetRandomPZSpawnPosition` 调用读脚本值
"PreferredSpecialDirection"，插件在 `L4D_OnGetScriptValueInt` 拦截返回 `g_iDirection`
（specialspawner.sp:1095）。旧逻辑普通波次固定 `SPAWN_LARGE_VOLUME`(9) → 候选点全在
队伍正前方锥形区 + 引擎 flow 校验偏前 → 实测全正前方。-1(随机) 只出现在整波全灭的
罕见 retry 路径，普通波永不触发。
**注意**：`L4D_GetRandomPZSpawnPosition` 第二参是 **zombieClass 不是方向类型**！
left4dhooks.inc 文档写明 "different values yield different results"（tank class 搜更大
区域）。传 index(1-6) 是正确用法，别被 SPAWN_* 常量误导。

**v1.6.0 修复**：`ss_random_direction "1"` → 普通波次方向改 `SPAWN_NO_PREFERENCE`(-1)，
引擎每次调用随机方向（前/后/上/任意）；跑图(flow 差>1500) 仍 `SPAWN_IN_FRONT`(7)、
终章仍 `SPAWN_NEAR_IT_VICTIM`(2)；开关 0 = 旧 LARGE_VOLUME。guard 日志追加 dir=%d
（已实测日志 dir=-1 生效）。

**迷宫图发现（labirinferno 实测）**：该图 400-900 候选点 LOS 全灭 → 无论方向怎么变
都是 100% invis-fb（0 vis-fb），部署后 16 波 36 次处决未降——方向随机对迷宫图帮助
有限（地形墙把可见性锁死），开阔图（c1m1 等）待玩家实测方向多样性。

## v1.7.0 三段定向刷新 + 波次分批释放（2026-08-04 部署，等玩家实测）

**需求**（用户）：「特感刷新点随机化」的终极目标是解决**多人下单面受敌**：①领队
压力爆炸（后面的人逛街）②窄地形正面压力过大无法突破。v1.6.0 的 -1 只解决"方向
单一"，没解决"参照中心单一"——所有落点围绕队伍+前方 900 锥形，队伍一长全砸领队。

**方案**：队伍拉长时把本波特感按权重分配到**前/中/后三段**，每只独立方向+独立
参照者（g_iDirection 拦截回调逐只设置，非波首一次）：

| 段 | 方向 | 参照子集 | 作用 |
|---|---|---|---|
| 前段 40% | `SPAWN_IN_FRONT_OF_SURVIVORS`(7) | flow 排序 [0,segA) | 正前方拦截，领队压力减半以上 |
| 中段 30% | `SPAWN_NO_PREFERENCE`(-1) | [segA,segB) | 侧翼包抄，中部玩家有目标 |
| 后段 30% | **`SPAWN_BEHIND_SURVIVORS`(1)** | [segB,aLen) | 身后断后，尾部玩家被迫参战 |

**段边界 = flow gap 自然切**（`ss_dir_split_gap` 400，相邻 flow 差超阈值断开）——
蛇形环绕/断裂队伍每段都能吃到特感（用户拍板：真实队伍蛇形+可能断裂成几段，
机械三等分不适用）；单段拉长退化均分三分。紧凑队伍（总差 < `ss_dir_split_spread`
400）不分段走 v1.6.0 原逻辑；终章 NEAR_IT_VICTIM 不分段。

**防贴脸不变式**：守卫查"落点离所有生还者地理 3D 距离 ≥400"（v1.3.8 全队扫描，
与参照者/方向无关）→ 段划分只改方位、不改距离下限；队伍内部候选点被守卫拦截
的后果是少刷/兜底，不是贴脸。

**分批释放**（`ss_wave_split` 2 批 / `ss_wave_split_interval` 2.5s）：总数量不变，
分 N 批间隔刷出，缓解窄地形一波全堆正面。si_comp 波次检测冷却 22.5s ≫ 2.5s 批
间隔，不会误判新波，播报无需改。

**实现结构**（ExecuteSpawnQueue 尾部重写）：段类型存 `g_iSegs[MAX_WAVE=48]`
（权重精确分配+Fisher-Yates 洗牌）；刷怪循环抽 `SpawnSliced(from,to)` 逐片执行；
跨批状态全局持有（g_hBatchQueue/g_iBatchSurvivors/g_fBatchFlows——跨 timer 存活）；
`tmrBatchContinue` 续刷 + `FinishWave` 收尾（guard 统计跨批累计+retry 判定+队列
释放）；OnMapEnd/OnPluginEnd 兜底清理；batch timer 带 TIMER_FLAG_NO_MAPCHANGE。

**新 cvar**：ss_dir_front 40 / ss_dir_mid 30 / ss_dir_back 30 / ss_dir_split_spread
400.0 / ss_dir_split_gap 400.0 / ss_wave_split 2 / ss_wave_split_interval 2.5。

**⚠️ v5.0 量层回滚（2026-08-04，AI_HardSI_bt v5.0 身份定位上线后）**：用户拍板
"行为树承担压力调节，替代波次数量操作"——分批拆散 si_comp 组合、补偿缩减组合，
与组合策略冲突。ss_wave_split 2→1、ss_incap_compensation 1.0→0.0（cvar 保留，
cfg 注释标明可随时调回）。三段定向（v1.7.0 核心）保留。见
[[l4d2-ai-identity-system]]。

**⚠️ 2026-08-05 恢复分批（用户拍板）**：玩家反馈"感觉一次全出"→ 恢复
`ss_wave_split 1→2`（批间隔 2.5s 不变，已 RCON 热应用 + cfg 持久化 + 验证）。
组合拆散延迟由组合管理器模式轮换吸收。ss_incap_compensation 仍 0.0。
**（次日被 v2.0.0 全面取代，见下）**

## v2.0.0 波间三态 + 战术小队批次引擎（2026-08-05 部署，用户拍板）

**三态生命周期**（解决"打完一波接一波没完没了"= 波间缺缓冲节点）：
- 压力期（批次投放）→ 收尾期（2s 轮询）→ 冷静期（12-18s 零特感缓冲，播报 `[特感] 波次清剿完毕，X 秒后下一波`）→ 下一波
- **收尾阈值 = 60% 清剿**：场上存活 ≤ max(2, floor(本波刷新量×0.4))（4人8特 → ≤3）；检测存活防留特——25s 无可见威胁处决自然清场，保持威胁的极端留特由 `ss_rest_force` 120s 兜底
- 冷静期后间隔 = 波间隔钉值 − 平均冷静(15)，钳 [10,45] → 总周期（播报倒计时）≈ 22-38s
- **finale 不豁免**（用户拍板：终章压力由引擎潮水/Tank 事件兜底）
- 相位状态机：PHASE_IDLE/PRESSURE/CLEARING/REST，不变量"非 IDLE 恰持一个生命周期 timer"；reload 从 CLEARING 自愈（OnMapStart 兜底）；处决补波仅 PRESSURE/CLEARING

**批次引擎**（替换 ss_wave_split/_interval，已退役无引用）：
- 批数 = clamp(ceil(波次/ss_batch_size=4), 1, ss_batch_max=5)；批间隔 = clamp(ss_batch_window=35/批数, 5, 10)
- **批内段重平衡**：每批独立 40/30/30 + 批内 Fisher-Yates（4 只批 = 头2/中1/尾1 多点位），替代整波分配+全波洗牌（前批单段扎堆）
- 新 cvar（全部 live 读取不缓存，防陈旧值）：ss_batch_size 4 / ss_batch_max 5 / ss_batch_window 35.0 / ss_rest_min 12.0 / ss_rest_max 18.0 / ss_rest_force 120.0

**倒地补偿恢复 1.0 全比例**（v5.0 曾回滚 0.0；代码一直在 1149-1186，仅 cfg 值）。

**关键数字**：4人8只→2批(4+4)10s间隔20s出完；8人16只→4批×8.75s=35s；12人22只→5批(5+5+4+4+4)×7s=35s。
**⚠️ si_comp reload 基线坑**：reload 后 g_fCfgBaseSpawnSize 回编译默认 6.0（实测 4 人波 6 只），换图后自动恢复 8。
**⚠️ 旧 cvar 残留**：ss_wave_split 卸载后残留内存（无代码读取，重启消失，sm_cvar 查询会看到）。

**验证**：编译 0 error（1 warning 为 v1.6.0 既有 g_bRandomDirection float 区
tag mismatch）；13:13 热重载 v1.7.0 + exec cfg 后 7 新 cvar 生效、旧值未污染
（base_limit=6）、errors 零新异常。**待玩家实测**：开阔图方向多样性（日志
dir=1/-1/7 混合）+ 分批节奏 + 处决率。

## v2.6.0 幽灵特感修复 + 刷新节奏精校（2026-08-17 用户拍板加固版，commit 642658e）

**背景（用户：生还者 M60/榴弹可补弹 + 火力支援后特感方单薄）**：日志实测
8-14~8-16 三天：**0% 完美点位（可见+≥400）、64-70% invis-fb、30-36% 跳过、
921 处决/天（66% 在 ≥900u 远处处决）**。有效压力 = 名义 × ~1/3。

**根因（代码级）**：SpawnSliced 的 invis 兜底取【最远】候选点（bestDist 取最大）
→ 全刷 900u 外墙后死巷 → 看不见玩家 → 25s 自杀处决。LOS 过滤形同虚设。

**修复（防贴脸三层防线，用户确认加固版）**：
- 硬下限 guard_min 250u 不变（v1.3.8 全队扫描不变式，与取远取近无关）
- 完美路径优先不变（可见+≥guard）
- 不可见候选分档取【最近】点：A 档 [invis_min=350, invis_max=550]（首选，
  350-550u 不远不近，走几步进入视线）；B 档 [guard_min=250, invis_min=350)
  （仅 A 档不存在时启用，极端窄图防饿死）
- 分层优先级：可见+≥guard(350) > vis-fb(≥250) > A 档 > B 档 > 跳过
- 新 cvar：`ss_spawnrange_guard_invis_min` 350 / `ss_spawnrange_guard_invis_max`
  550（0=禁用对应档/上限）
- guard 400→350（微降提升 LOS 通过率）
- 日志增强：invis-fb 行追加 `near=B档计数 avgDist=平均距离`（观测幽灵修复效果）

**时间精校（用户拍板）**：
- `ss_batch_window` 35→20（4人10只 3 批：0/6.7/13.3s 出完，原 0/10/20s 拖沓）
- `ss_rest_min/max` 25/35→20/30（总周期实测 31.6s→~25s；Tank 波 ×1.5 仍生效
  =30-45s）
- 数量 2.5N 不动（点位修复后有效压力已大增，观察后再定）

**部署状态**：编译 0 error（1 warning 为 v1.6.0 既有 tag mismatch）；
smx 已 cp plugins/；cfg 已同步（去重复块）——**✅ 2026-08-17 00:51 已热 reload
部署验证通过**：v2.6.0 running（hash f52281f0），全部新 cvar 生效
（guard=350 / invis_min=350 / invis_max=550 / batch_window=20 / rest=20-30），
reload 后 errors 日志零新增。⚠ exec 路径必须 `exec sourcemod/specialspawner.cfg`。

## 相关插件

- [[l4d2-plugin-inventory]] — 完整插件清单
- [[l4d2-si-health]] — 特感血量配置
- [[l4d2-si-composition-manager]] — SI 组合管理器，ceil(存活人数×1.5) + 存活数播报
- `spawn_infected_nolimit.smx` — 移除引擎层面的特感数量限制，使 specialspawner 的高上限生效
- `AI_HardSI_bt.smx` — 行为树 AI，接管刷新后 SI 的决策逻辑

## 2026-08-20: 特感数量 = 人数×3（用户拍板）

- 公式 **10+2.5×(N-4) → 12+3×(N-4)**（4人基准 12 = 3×4，钳 [12,32]）
- cfg 三处同步：`ss_spawn_size` 10→12 / `ss_base_limit` 10→12 / `ss_extra_limit` 2.5→3
- ⚠️ si_comp `g_fCfgBaseSpawnSize` 只在 OnConfigsExecuted 从 `ss_spawn_size` cfg 捕获 → 改 cfg 后必须
  `exec sourcemod/specialspawner.cfg` + `sm plugins reload si_composition_manager` 才生效（纯 sm_cvar 无效）
- specialspawner `SetSpawnCount` 只会把 ss_spawn_size 抬高到自身算式值，低于 si_comp 时沿用 si_comp 值，
  故实际波次 = max(3N, 12+(N-4)) = 3N ✓
- **实测**：6人 → `ss_spawn_size = 18`（=3×6）✓

## v5.37（2026-08-20）整波 0 特感根治 —— g_hReserveTimer 换图残留

**现象**：换图后特感完全不刷新（`Wave lifecycle total_spawned=0` 连续多波），errors 日志每 ~37s 一条
`Invalid timer handle (error 1) @ specialspawner.sp:2018 ExecuteSpawnQueue ← 1745 tmrSpawnSpecial`。

**根因链路**（实机 21:05:44 换图 li_c1m3 触发，21:06:27 起稳定复现）：
- `g_hReserveTimer = CreateTimer(60.0, tmrReserveTimeout, _, TIMER_FLAG_NO_MAPCHANGE)`(2062行)
- **换图时引擎自动杀 NO_MAPCHANGE timer，但 `g_hReserveTimer` 变量未置 null**
- 下一波 `ExecuteSpawnQueue:2018 KillTimer(g_hReserveTimer)` → 对失效句柄抛异常 → **函数中止，
  SpawnSliced 根本不执行** → 整波 0 特感 → 死循环每波一次
- 触发概率与特感×3 联动：×3 后 reserve>0 的波更多 → 换图时挂着 reserve timer 的概率更高

**修复**（specialspawner.sp `ResetLifecycle()`，OnMapEnd 兜底）：
```pawn
if (g_hReserveTimer != null) { KillTimer(g_hReserveTimer); g_hReserveTimer = null; }
```
（ResetLifecycle 原本清 BatchTimer/CatchupTimer，唯独漏了 ReserveTimer；OnMapEnd 时刻 timer 仍有效，安全。）
- `sm plugins reload specialspawner` 可临时救场（重置全局句柄）；根治必须上版代码。
- 部署：编译 0 error/4 warn(既有) → cp → reload；wave 立即回复正常。版本号未 bump（沿用 6.1.1）。
