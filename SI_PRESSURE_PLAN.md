# SI 压力体系升级计划

> 2026-08-13 记录。状态：**全套已批准未实施**；追加机制 A-D 待定；环境压力值为用户新构想，下次详谈后统一实施。

## 0. 定版约束（不可动）

- **1人2特**：基准 8（4人），每 +1 人 +2，类别上限合计 22 封顶
- **周期结构**：压力期（批次释放）→ 清缴期（收尾）→ 冷静期 → 下一波
- **安全网**：`ss_incap_compensation 1.0` —— 有倒地时波次/上限按站立比例收缩（激进的前提）

## 1. 当前生效值（部署 cfg，2026-08-13）

- 波间隔钉值：si_comp 自身 cvar `si_comp_mode_interval_min/max = 20/35`（specialspawner.cfg 的 40/55 只是换图初始值，每波被 si_comp 覆盖）
- 清缴后空窗 = 冷静期 12-18s + 待命 max(10, 钉值−15) = **22-38s**（用户所述 20-30s 冷静期）
- 收尾硬上限 120s / 清剿阈值 40%（写死）/ 批次 4只×窗口35s / 自杀 25s
- 守卫 400（保底 250）/ 三段权重 40/30/30 / 首波 15s

## 2. 已批准：全套升级（2026-08-13 用户拍板"全套+动态化"）

### 2.1 基础收紧包（cvar，零风险）

| 项 | 现值 | 目标 |
|---|---|---|
| `ss_rest_force` 收尾硬上限 | 120 | 75 |
| 清剿阈值（写死） | 40% | 30%，提为 cvar `ss_clear_threshold` |
| `ss_batch_window` | 35 | 28 |
| `ss_suicide_time` | 25 | 20 |
| `ss_spawnrange_guard` / `_min` | 400/250 | 350/220 |
| `ss_dir_front/mid/back` | 40/30/30 | 35/25/40（长队伍队尾加码） |
| `ss_first_time` | 15 | 10 |

### 2.2 动态节奏（代码，specialspawner v2.0.2→v2.1.0）

- **动态冷静期**：进冷静时算站立比例——无倒地 random(8,10)，有倒地 random(14,18)
  - 新 cvar：`ss_rest_healthy_min/max`（8/10）；现有 `ss_rest_min/max` 改为受伤值（14/18）
- **post-rest 钳位 10→6**（`GetPostRestInterval`）；记录实际 rest 值 `g_fLastRest`，post-rest = 钉值 − 实际 rest（替代 avg 估算）
- 站立比例 helper 提取复用（ExecuteSpawnQueue 内联代码 → 公共函数）

### 2.3 动态波间隔（si_comp v2.4.0→v2.5.0）

- `PinSpawnTiming` 读站立比例：全站立 → 钉 16-22（现有 `si_comp_mode_interval_min/max` 作健康区间）；有倒地 → 钉 28-35（新 cvar `si_comp_interval_hurt_min/max`）
- 效果：健康队清缴后空窗 ~16-20s，受伤队 ~27-38s 维持现状

### 2.4 类-段匹配（协作升级，长队伍核心）

问题：类型选择与段位分配独立——Charger 刷队尾追不上、Hunter 刷队头送头，2N 兵力浪费。

方案：
- specialspawner 新增 cvar `ss_spawn_dir`（9=未刷怪），`SpawnSliced` 里每只 `L4D2_SpawnSpecial` 前写入 `g_iDirection`；刷完/FinishWave 复位 9
- si_comp `L4D_OnSpawnSpecial` 里 **惰性 FindConVar**（si_comp 字母序先于 specialspawner 加载，OnPluginStart 查不到），读 dir 乘亲和系数：

| 段 | 方向值 | 亲和（Sm/Bm/H/Sp/J/C） |
|---|---|---|
| 前段拦截 | 7 | 2.0 / 1.0 / 1.5 / 0.6 / 0.6 / 2.5 |
| 中段封锁 | -1 | 1.5 / 2.0 / 0.8 / 2.5 / 0.8 / 0.8 |
| 后段追杀 | 1 | 0.6 / 0.6 / 2.5 / 0.8 / 2.5 / 1.5 |
| 其他（终章 2 等） | — | 全部 ×1.0 中性 |

- 生效点：`PickClass`（deficit 与 closest-to-zero 两条路径）+ `PickWeightedRandom`（波首只）——effRatio = modeRatio × affinity；**零比例类保持零**（模式身份不受影响）；紧凑队伍不分段时 dir=-1 → 天然"抱团吃范围封锁"反制
- 终章 NEAR_IT_VICTIM(2) 中性，防守场景不变

## 3. 追加机制 A-D（待定，倾向并入环境压力值体系统一驱动）

- **A 倒地围猎波** ⭐推荐：player_incapacitated → 倒地者 300-600u 刷 2-3 只 Hunter/Jockey/Charger；每波 ≤2 队 + 20s 冷却。主波减负但倒地者成围猎焦点
- **B 完美清剿惩罚** ⭐推荐：整波无倒地 → 下一波规模 +25%（受 22 钳制）。强队永远吃满压力
- **C 反蹲点波**：领队 flow 停滞 ≥45s（仅冷静/待命期）→ 4-6 只三向围剿 → 重进冷静倒计时。打断状态机（REST/IDLE → PRESSURE → CLEARING），改动稍重
- **D 动态清剿阈值**：健康 50%/受伤 30%（波次重叠高压）。代价：强队无喘息窗口，如采用建议 45/30 起步

## 4. 用户新构想：环境压力值（下次详谈）

用户提出做一个 **环境压力值**——统一压力指数驱动上述机制。自然形态（待与用户确认细节）：

- **输入**：站立比例 / 倒地事件 / 清剿耗时 / 蹲点时长 / 完美清剿
- **输出**：冷静期长短 / 波间隔 / 清剿阈值 / 围猎强度 / 规模加成
- 与 2.2/2.3 的"健康加压/受伤减负"同方向，A-D 机制天然是该指数的执行器

下次讨论要点：指数定义（一维 or 多维）、计算周期、衰减/恢复曲线、输出映射表。

## 5. 实施顺序（待环境压力值定稿后统一动手）

1. 环境压力值设计定稿（下次详谈）
2. 全套落地（2.1-2.4 代码 + cfg）
3. A-D 按压力值体系整合
4. 编译（compile.sh / spcomp64）→ 部署 smx → 空服 reload（静默规则）→ Git 提交推送（不留 smx 备份）

涉及文件：`scripting/specialspawner.sp`、`scripting/si_composition_manager.sp`、`cfg/sourcemod/specialspawner.cfg`、`cfg/sourcemod/si_composition_manager.cfg`
