# L4D2 特感刷新三大矛盾问题 —— 调研计划

> 面向云端 agent：请先完整阅读本节"问题定义与技术上下文"，再按"调研清单"逐项调研
> 成熟社区插件，最后按"产出物要求"交付。调研的是**机制与算法思路**，不调研本仓库
> 内部代码（本地 agent 已掌握）。本文件为唯一任务书。

## 一、问题定义

L4D2 自研特感刷新系统（SourcePawn 插件，以下简称 SS）在实机中反复暴露
**三个互相矛盾的目标**，任何单一策略都会顾此失彼：

1. **不贴脸**：特感不能刷新在幸存者脸上（会被秒、没威胁、体验崩）
   - 当前：硬下限 `ss_spawnrange_guard_min=250u`，首选 `ss_spawnrange_guard=350u`
2. **不迷失目标**：特感刷新出来必须能立刻看到/找到幸存者，否则变成
   **"幽灵特感"**——看不见人、无所事事，25 秒后被系统处决（等于白刷浪费波次压力）
3. **不卡位置**：特感不能刷在墙里/不可达位置/死巷（即使看得见也追不上玩家，
   或被地形卡死）

### 矛盾本质

- **保证"看见幸存者"** → 需要低距离 + LOS 无遮挡 → **容易贴脸**
- **保证"不贴脸"** → 需要距离远 + 有掩体 → **容易看不见人（变幽灵）**
- **保证"不卡位"** → 需要 NavMesh 可达性 + 实体碰撞检测 → 地图几何复杂时
  **可能一个合法点都找不到 → 饿死（波次空刷）**

**核心痛点**：用距离/LOS/几何三者做严格过滤 → 点不够 → 要么饿死、要么放行
幽灵点（保底兜底被滥用）→ 幽灵点 25s 被处决 → 玩家感知"波次压力不足、
刷新有水分"。

### 想从成熟插件调研到的答案

成熟社区插件（及其对原版 Director 的改造）**如何在一个统一的刷点算法里
同时满足这三条**，而不是靠层层兜底打补丁。重点找：有没有用
**NavMesh / flow distance / LOS 三者联立**做"可达且可见且不贴脸"的
单次判定方案。

---

## 二、技术上下文（当前 SS 实现，供理解问题链路）

### 2.1 处决机制（"迷失"的直接惩罚）

```
tmrForceSuicide：每 2.5s 轮询所有 bot 特感（class 1-6）
    if m_hasVisibleThreats:             # 看见幸存者 → 续命
        刷新行动时间戳; continue
    victim = 正在控的幸存者
    if victim > 0:
        victim 已倒地 → 处决           # 控倒地者无效
        victim 存活   → 刷新时间戳      # 正在控人 → 续命
    else:
        距上次行动 > ss_suicide_time(25s) → 处决(ForcePlayerSuicide)
```
- **不检测位置/碰撞**；"看得见"（LOS）是唯一免死判据
- 任意"行动"可续命：出生、看见幸存者、控人、被打（player_hurt）
- 实机日志：`处决 Spitter 距生还者最近 1271`（远处幽灵）、
  `处决 Boomer 距生还者最近 202`（墙后死角、看得近但看不见人）均被处决

### 2.2 当前贴脸守卫分层（防贴脸 + 防饿死）

```
SpawnSliced 逐只刷，L4D_GetRandomPZSpawnPosition 采样 SPAWN_GUARD_MAX_TRIES 次：
  优先级从上到下：
  ① 可见 + 距离≥guard(350)            → 最佳
  ② 可见 + 距离≥guard_min(250)         → 保底1(vis-fb)
  ③ 不可见 + [invis_min(350), invis_max(550)] 最近 → 保底2(A档)
  ④ 不可见 + [guard_min(250), invis_min(350))    → 保底3(B档)
  ⑤ 任意最近点（完全不检查）           → 保底4(防饿死兜底)
  ⑥ 全部失败 → 跳过
```
**保底 4 是"不迷失"的头号敌人**：放行了看不见玩家的点 → 幽灵特感 → 处决。

### 2.3 波次预算（70/30，与本次调研无直接关系但要知道）

- 首发刷 `ceil(spawnSize×0.7)`，击杀补位 30%，玩家累计击杀达首发数 波次完成
- Tank 另有自身验证（hull 碰撞 + nav 可达），与普通特感分开

### 2.4 关键 cvar（当前值）

| cvar | 值 | 含义 |
|------|----|------|
| ss_spawnrange_guard | 350 | 首选最小距离 |
| ss_spawnrange_guard_min | 250 | 全跳保底最小距离(硬下限) |
| ss_spawnrange_guard_invis_min | 350 | 不可见A档下限 |
| ss_spawnrange_guard_invis_max | 550 | 不可见上限 |
| ss_suicide_time | 25 | 处决超时(秒) |

---

## 三、调研清单

### 3.1 必查插件/项目（按优先级）

1. **Left 4 Downtown 2**（left4dhooks 全家桶）——`L4D_GetRandomPZSpawnPosition`
   内部到底怎么取点？它是否存在"能给出生特感指定初始目标/victim"的原语？
2. **PlagueFox / l4d_special_spawner**（多个社区"增强刷新"插件）——同名问题，
   看它们如何同时保距离与可见性
3. **Silvers 的 L4D2 插件合集**（如 zombie controller / SI 管理类）——成熟度高，
   通常有 spawn 距离、出生提示（survivor 高亮 / 出生瞬间给 AI 指向）
4. **Versus 平衡类 / AI-patch 类插件**（如 AI Hard SI、Charger AI fix）——
   它们如何"喂目标"给新生的特感
5. **原版 Director 的 AI 逻辑 / 官方 Nav**——恐怖僵尸如何利用 navmesh 选不可达+
   可见的出生位；`z_spawn_safety_range`、`z_ghost_delay_time` 等官方 cvar 意图
6. **其他知名刷怪框架**：`[L4D2] Death Run`、`Zone Spawn`、`Horde Mode`、
   `Dynamic Spawning`、`Infected Spawner (by ugh)` 等，凡公开源码均可参考

### 3.2 逐题要答透的技术问题

**A. 不迷失目标（幽灵）**
- A1 成熟插件如何保证"出生即可见"？是否在刷点阶段就把 LOS 纳入硬条件？
- A2 是否有"出生瞬间给特感指定目标 client / 注入 AI 意图"的手段
  （如初始化 pop 的 target、force give target、set last known area）？
- A3 是否用 `m_hasVisibleThreats` 或类似的 prop 直接作为刷点校验？
- A4 是否缩小刷点半径换取更高可见率（暂短距离但保证 LOS）？
- A5 对"不可避免的幽灵"如何处理——延长处决时间？给缓冲期原地待机再随机移动？

**B. 不卡位置（可达性）**
- B1 是否用 **NavMesh area** 校验（`L4D_GetNearestNavArea` /
  `L4D2_NavAreaTravelDistance` / `CheckNavStatus`）保证"到最近玩家可达"？
- B2 是否用 **hull trace**（`TR_TraceHullFilter` 而非射线）保证出生点有站立空间？
- B3 是否做**出生点-玩家 path trace**（直线或 nav path）排除墙/门/实体？
- B4 如何处理"nav 点合法但玩家在楼上/隔层"的跨层误判？

**C. 不贴脸（距离）**
- C1 成熟方案用什么距离指标——欧氏距离？flow distance（沿地图纵深）？
- C2 是否允许"近距离但有威胁"的刷新（如 Smoker 蹲墙根）？怎么区分"贴脸无威胁"
  与"贴脸有威胁"？
- C3 flow distance 如何获得（left4dhooks `L4D2Direct_GetTerrorNavAreaFlow`？）

**D. 三者联立（核心）**
- D1 是否存在一个**统一判定**："候选点 nav 可达 && LOS 可见 && flow距离∈[a,b]"，
  三条件 AND，而不打补丁式分层兜底？若有，采样次数/退避策略如何设计？
- D2 极端几何（tank/小图/窄走廊）三条件 AND 全失败时，成熟插件退回到什么？
  ——"宁可近不可见"还是"宁可远可见"还是"放弃本只"？
- D3 它们有没有把"出生失败"从波次预算里正确排除（失败不浪费）的成熟做法？

### 3.3 需搜集的佐证
- 各方案的关键实现伪代码/片段（注明插件名+版本+链接）
- 各方案的失效边界（地图种类、人数规模）
- 若 GitHub 源码：给出文件路径与行号

---

## 四、产出物要求

1. **对比表**：插件 | 距离策略 | 可见性策略 | 可达性策略 | 幽灵处理 | 失败退避 | 结论可借鉴点
2. **最优方案建议**：明确推荐一种"统一判定 + 退避"算法，附伪代码，说明：
   - 距离指标选哪种（欧氏 vs flow）
   - 可见性如何校验（LOS from 刷点到最近玩家 eye）
   - 可达性如何校验（nav area + hull + path）
   - 三者 AND 的采样与退避（保底优先级怎么排才不产生幽灵、不饿死）
3. **可落地 cvar 建议**：如果能映射回本插件 cvar（guard/invis_min/max/suicide_time）
   如何调。若调研到更好机制，也可建议新增 native/逻辑。
4. **风险与边界**：哪些方案在哪些地图会失效；对 24 人高人数/自研 Tank 波的影响。

## 五、本服务器可做的验证（供参考，云端不必跑）

- 用 SS 日志 `[SS] 处决 X 距生还者最近 N` 统计处决率（幽灵比例）
- `[SS] spawn guard: X/Y skipped ...` 统计饿死率
- `[SS] SI#x-y spawned` 与 `[击杀]` 的比值 = 有效压力率
