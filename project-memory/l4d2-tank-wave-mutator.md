---
name: l4d2-tank-wave-mutator
description: Tank 波次突变系统 v2.4.0 —— 用户新设计（2026-08）替代废弃的压力值体系：10% 随机突变 + 连5波无倒地强制双Tank + 连11波无Tank保底单Tank + Tank波后3波冷静期
metadata:
  node_type: memory
  type: project
  originSessionId: tank-wave-mutator
  modified: 2026-08-16T02:30:00.000Z
---

# L4D2 Tank 波次突变系统（tank_wave_mutator）

**背景**：2026-08 用户提出"特感波次有条件突变为 Tank 波次"替代旧压力值体系
（[[l4d2-si-pressure-plan]] 已废弃）。**这是当前服务器唯一的难度调节机制**。

## v2.7.0 参数后移（2026-08-17 用户拍板，commit 6c0ddbc）

**起因**：波次密度提高（specialspawner v2.6.0 总周期 31.6s→~25s）后惩罚后移：

| 常量 | 旧 | 新 | 说明 |
|---|---|---|---|
| `MUTATION_CHANCE` | 0.10 | **0.07** | 每波突变概率 10%→7% |
| `FORCE_TANK_WAVES` | 5 | **8** | 连续 8 波完美清缴（无倒地/死亡）强制双 Tank |
| `FORCE_TANK_NO_SPAWN` | 11 | **14** | 连续 14 波无 Tank，第 15 波必刷单 Tank |
| `TANK_COOLDOWN_WAVES` | 3 | **4** | Tank 波后 4 波冷静期 |

**🔥 顺带修复隐藏坑（重要）**：`SS_OnWaveRest` 硬编码
`baseMin=25.0/baseMax=35.0` 每波 REST 覆盖 ss_rest_min/max——specialspawner
v2.6.0 冷静期 cfg 已改 20-30，**此处不同步则 cfg 改动永不生效**（非 Tank 波
冷静期被强制 25-35）。v2.7.0 同步 20/30 + 注释标明"须与 specialspawner.cfg
一致"；Tank 波倍率 1.5 后 = 30-45s。改 cfg 冷静期必须两处同步（此文件 +
specialspawner.cfg）。

**部署**：✅ 2026-08-17 00:55 热 reload，v2.7.0 running（hash 7d059fba），
加载日志确认 Mutation: 7%, Force: 8 waves, Cooldown: 4 waves；errors 零新增。

## 机制（v2.6.0，源码 scripting/tank_wave_mutator.sp）

- **10% 随机突变**：普通波清剿完判定下一波是否变 Tank 波
- **强制双 Tank**：连续 5 波无生还者倒地（player_incapacitated/death 重置计数）
- **保底单 Tank**：连续 11 波无 Tank（第 12 波必刷，冷静期波不计数）
- **冷静期**：Tank 波后 3 波普通波（计数冻结不累加，不触发强制条件）
- **首波保护**：第 1 波必定不是 Tank

> ⚠️ 以上为 v2.6.0 数值，v2.7.0 已改（见上节参数表）。

## v2.6.0 双Tank生成约束 + 卡住看护（2026-08-16 用户定稿，commit d8e97ef）

**起因**：用户反馈"双 Tank 经常卡住被自动处决"。日志实证 + 全插件排查：

- **双 Tank 生成点重叠实锤**（生成循环每只独立采样"取 ≥750u 最近点"→ 收敛同一
  区域）：08-16 实测三例相距 **118u / 292u / 462u**（Tank 实体巨大，生成即重叠
  物理推挤互卡）
- **处决排查结论：无任何插件处决 Tank**——specialspawner 自杀计时器
  `SI_MAX_SIZE=6` 直接跳过 class=8（三天日志 0 条 Tank 处决，但每天 500-1000 条
  普通特感处决）；清缴不杀；AI_HardSI 波次同步 `class==8 continue`。"自动处决"
  = **引擎导演**的 stuck/掉队处理（传送或 Kill）+ 团灭/换图清场
- 放大器：AI_HardSI 每帧清 IN_JUMP/IN_DUCK（非决策帧 75% 帧引擎 AI 不能跳）→
  Tank 无法翻越台阶/矮墙顶墙站桩（v5.23.2 帧策略回退教训，未动 AI_HardSI）

**v2.6.0 修复**（只改 tank_wave_mutator.sp）：
1. **生成互斥**：第二只 Tank 采样点与第一只水平距离 ≥`TANK_SPAWN_SEPARATION`
   (800u)——防重叠互卡
2. **防前后包夹**（用户："两个tank不能一前一后包夹，否则太难了"）：两只相对
   幸存者**方位夹角 ≤`TANK_SPAWN_MAX_ANGLE`(90°)**——同侧推进不摆夹击阵型
3. **卡住看护**：2s 监控发现 Tank 位置 <40u/2s 连续 4 次（8s）→ `RelocateStuckTank`
   重定位到 450-1500u 且有 LOS（TraceFilter_World 只算世界几何）的新点——抢在
   引擎 stuck 处决前；找不到放弃下 tick 再试

## v2.6.1 约束失效实机修复（2026-08-16 19:05 热加载，commit b572f00）

**实机案例（19:01 c8m2）**：双 Tank 生成点相距 **50u 且 Z 差 128u（跨楼层）**，
Tank #2 生成在楼下平台玩家看不到（"只刷了一只"观感），moved=0 卡死，重定位
每 8s 失败一次刷日志 2 分钟（"no LOS candidate"）。

**根因**：
1. v2.6.0 约束只在 `dist ≥750u` 分支评估，**贴脸兜底分支完全绕过约束**——c8m2
   PZ 点池 <750u（dist=698/659），约束形同虚设
2. 兜底取**第一个随机候选**而非最远——v2.4.0 注释承诺"取最远"但实现是取第一个
   （注释与实现不符老坑）

**修复**：
1. 约束评估移到**所有候选**（四级逐级兜底：full→noAng→noSep→far，每级打日志）
2. far 兜底取**最远**候选（分离倾向）
3. 全候选 **LOS 检查**（防跨层/隔墙生成在玩家看不到的位置）
4. 重定位兜底：LOS 无解 → 传送到**最近幸存者前方 500u 地面点**（必定成功，
   玩家必然看到）

## 与 specialspawner 联动

- `SS_OnWaveRest(float totalCountdown)` forward：波次清剿结束时判定下一波
- `SS_OnWaveStart(bool started)` forward：预判为 Tank 波则延迟 1.5s 生成
- `SS_HoldClearing(bool hold)` native：Tank 波挂起清缴（收尾期不进 REST，
  直到 Tank 死亡才释放）—— specialspawner v2.2.0 暴露，v2.4.4 仍保留
- 就地生成用 `L4D2_SpawnTank` + `L4D_GetRandomPZSpawnPosition`，12 次采样取
  ≥450u 最近点（v2.4.0 修复待命站桩/掉队被清）

## 配置常量（代码写死，改需重编译）

```sourcepawn
MUTATION_CHANCE 0.10      // 10% 突变概率
FORCE_TANK_WAVES 5        // 连续5波无倒地 → 双Tank
FORCE_TANK_NO_SPAWN 11    // 连续11波无Tank → 保底
TANK_COOLDOWN_WAVES 3     // Tank波后冷静期
TANK_SPAWN_MIN_DIST 750.0 // 最近生成距离（v5.35 450→750，用户：刷远点）
TANK_SPAWN_SAMPLES 12     // 采样次数
TANK_SPAWN_SEPARATION 800.0 // v2.6.0 双Tank互斥距离（防重叠互卡）
TANK_SPAWN_MAX_ANGLE 90.0   // v2.6.0 双Tank方位夹角上限°（防前后包夹）
TANK_STUCK_MOVE 40.0        // v2.6.0 卡住判定：2s 移动 <40u 视为没动
TANK_STUCK_CHECKS 4         // v2.6.0 连续4次没动（8s）→ 重定位
```

## v2.6.3 三角形刷新 + 至少 800u（2026-08-16 19:25 热加载，commit da26fcd）

**用户拍板**（最终方案，取代"放一起"/"一前一后"）："至少保持800u距离，或者是
呈现三角形刷新，更好"

**设计定稿（三角形）**：
1. **两只 Tank 与玩家构成三角形**：每只距玩家 **≥800u**（"至少保持800u距离"）
   + LOS（玩家可见）
2. **夹角 60°-120°**（两只相对玩家水平面）：60° 下限保证两只间距 ≥800u
   物理不接触不互卡；120° 上限防侧翼包夹（仍同侧推进不夹击）
3. **严格执行距离**：无 ≥800u+LOS 候选就**不刷**——删除全部贴脸 fallback
   （历史 dist=298/502/561 案例）；第二只失败只刷第一只（单 Tank 波）
4. 采样 12→20 降低失败率；LOS 防跨层/隔墙保留

**演进脉络**（同一天四轮拍板）：v2.6.0 互斥+夹角（防包夹）→ v2.6.1 修约束被
兜底绕过 → v2.6.2 "放一起"（简化）→ v2.6.3 **三角形+800u 严格执行**（最终）

## v2.6.4 前后刷新 fallback（2026-08-16 20:50 热加载）

**起因（20:45 tew2_1stem 实锤）**：强制双 Tank 预告后 0/2 全灭——
两条日志均无 "+ triangle angle"（第一只本无夹角要求）→ 是 ≥800u+LOS 阶段
就全灭；同刻 specialspawner 10/10 invis-fb（室内段 PZ 点全不可见）→
"又远又可见"的点不存在；error 日志空（native 正常）。

**用户拍板**："做一个fallback，就是前后刷新"——三角形优先不变，无合格点
→ 第一只刷队伍**前方**、第二只刷**后方**（`SpawnTankFallback`）：
- 方向 = 全队存活幸存者平均朝向（水平面；对向抵消时退化用参考幸存者朝向）
- 基准 = 队伍中心（全队平均位置），距离档位 **800 → 600 → 450**（v2.6.5 用户
  拍板，原 600→500→400）
- 向下 trace 找地面（+80u 起 -3000u，世界几何过滤），无 LOS 要求
- 仍无地面点才放弃该只（日志 "fallback failed: no ground point front/back"）
- 日志标识 `Tank #N FALLBACK spawned (front|back)`

**教训**：v2.6.3 "严格执行不刷" 的代价 = 室内窄段 Tank 波变空波；fallback
方向由用户拍板（前后包夹——用户明知但接受，作为兜底）。

## 部署

- plugins/tank_wave_mutator.smx **v2.6.3**（2026-08-16 19:25 热加载，
  Timestamp 08/16 19:25:03）
- 运行时 sm plugins info 确认 running
- ⚠ 版本史混乱：代码内注释混用 AI_HardSI 的 v5.35（450→750 是那次一起改的）；
  PLUGIN_VERSION 才是权威（当前 2.6.3）

## 相关

- [[l4d2-pressure-system-removed]] — 压力体系全套清理（2026-08-16）
- [[l4d2-si-pressure-plan]] — 旧压力计划（已废弃）
- [[l4d2-specialspawner-config]] — specialspawner cvar（冷静期 25-35s 设计值）
- [[l4d2-rest-tier-override-bug]] — 旧 bug（已根除）