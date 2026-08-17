---
name: l4d2-si-composition-timing-pitfall
description: si_composition_manager 反馈循环 + OnPluginStart 时机导致特感刷新异常
metadata:
  type: feedback
  related: [[l4d2-si-composition-manager]], [[l4d2-specialspawner-config]]
---

# L4D2 SI Composition Manager 刷新间隔异常根因分析

## 已修复的问题

### 1. ReadSourceRange 反馈循环（v2.3.4 修复）

**症状：** 第一波间隔正确（22-35s 随机），往后所有波次间隔完全固定（同一个值不变）。

**根因：** `PinSpawnTiming()` 调用 `ReadSourceRange()` 从 live cvar 读取 `ss_time_min`/`ss_time_max`。但 `PinSpawnTiming()` 自己刚把这两个 cvar 都设成了同一个值 X。下次调用时 `ReadSourceRange()` 读到 (X, X) → `random(X, X) = X`，永远不变。

**修复：** `CaptureSourceRange()` 只在 `OnMapStart` 读一次配置值存入 `g_fCfgTimeMin`/`g_fCfgTimeMax`，之后 `PinSpawnTiming()` 直接用这两个常量，不再重读 cvar。

### 2. 启动顺序导致读到编译默认值（v2.2.0 修复）

`si_composition_manager.sp` 在 `OnPluginStart` 时期读 `ss_time_min`/`ss_time_max` 并存到全局变量。但 `OnPluginStart` 执行时 `specialspawner.cfg` 还没执行，读到的是 specialspawner 编译默认小值（~10-15s）。

**修复：** 公告动态读实时 cvar，`CaptureSourceRange()` 在 `OnMapStart` 调用（此时 cfg 已执行）。

### 3. ss_spawnrange_min 过大导致引擎处死远处 SI（v2.2.0 修复 → 2026-07-27 再次修正）

`ss_spawnrange_min "500"` — 强制 SI 必须刷在离生还者 500+ 单位外。L4D2 引擎默认 `z_spawn_safety_range` = 550。如果可用 nav area 在 500-1500 范围内不够多，引擎找不到合法出生点，直接处死该 SI。

**修复：** 降到 `ss_spawnrange_min "200"`。

### 4. 刷新数量公式永远少 1 只（v2.3.4 修复）

旧公式：`spawn = base_spawn_size + extra_limit × (survivors - base_size) / extra_size`
代入默认值：`spawn = 5 + 1.5×(survivors-4) = 1.5×survivors - 1`

因为 `base_spawn_size(5) ≠ extra_limit×base_size(1.5×4=6)`，所以 4 人时只刷 5 只（不是 6）。

**修复：** 换用直接公式 `spawn = ceil(survivors × extra_limit)` = `ceil(存活人数 × 1.5)`。3人→5, 4人→6。

## 教训

- SourceMod 的 `OnPluginStart` → `OnConfigsExecuted` 有严格先后顺序，**依赖其他插件的 cvar 不要缓存到 OnPluginStart**
- **不要把同一 cvar 既当输入又当输出** — 反馈循环会导致值收敛退化
- `ss_spawnrange_min` 不要设太大 — L4D2 出生点数量有限，范围越大可用位置越少，引擎会静默丢弃 spawn 请求
- `RoundToCeil` 用于 spawn count 比 `RoundToNearest` 更合理 — 3×1.5=4.5 应该刷 5 只而不是 4 只

### 5. ss_time_mode 理解错误导致特感不停刷新（2026-07-27）

**症状：** 特感持续刷新，感觉没有波次间隔，像"不停刷特感"。

**根因：** `ss_time_mode` 被设为 `1`，但 specialspawner 的 mode 含义是：
| 值 | 行为 |
|---|---|
| **0** | **随机间隔** — random(ss_time_min, ss_time_max) |
| 1 | 递增模式 — 杀的越快，刷的越快（正反馈循环） |
| 2 | 递减模式 — 杀的越慢，刷的越快 |

si_composition_manager 的设计文档和记忆文件一直**错误地假设** `ss_time_mode 1 = 随机模式`。实际上 mode 1 是递增模式：生还者清怪越快 → 间隔缩短 → 杀得更快 → 间隔更短 → 最终间隔趋近于 0，表现为"不停刷特感"。

**修复：** `ss_time_mode "1"` → `ss_time_mode "0"`。

**关联记忆：** [[l4d2-specialspawner-config]] — ss_time_mode 正确文档

### 6. sourcemod.cfg 换图覆盖导致间隔退化到 ~10s（2026-07-27）

**症状：** `specialspawner.cfg` 配置 45-60s 间隔，实际却是 ~10 秒一波，像"不停刷特感"。

**根因：** `cfg/sourcemod/sourcemod.cfg` 在**每次换图时**都执行，其中有三行：
```
sm_cvar ss_time_min 40
sm_cvar ss_time_max 60
sm_cvar ss_time_mode 1
```
SourceMod 执行时序：
1. `specialspawner.cfg` → ss_time_mode=0, min=45, max=60 ✓
2. `si_composition_manager` OnMapStart → CaptureSourceRange() 读到 45/60 → PinSpawnTiming() 钉住 ✓
3. **`sourcemod.cfg` 执行（换图时）** → ss_time_mode=**1**（递增模式）, min=40 ✗ **全部覆盖！**

`ss_time_mode 1` 是递增模式：生还者清怪越快 → 间隔越短 → 杀得更快 → 间隔更短 → 收敛到 ~10s。

**修复：** 删除 `sourcemod.cfg` 中的 `sm_cvar ss_time_*` 三行，让 `specialspawner.cfg` + `si_composition_manager` 完全接管。注释留底：
```
// ss_time_* removed — managed by specialspawner.cfg + si_composition_manager
```

**教训：** `sourcemod.cfg` 在每个 map change 都会执行，是所有插件 cfg 之后的"最后一棒"。任何 Cvar 如果被 `sourcemod.cfg` 的 `sm_cvar` 覆盖，插件的精细控制就全白费了。以后改刷新时机只动 `specialspawner.cfg`，不动 `sourcemod.cfg`。

### 7. CaptureSourceRange 在 OnPluginStart 读到编译默认值 ~12s（2026-07-27）

**症状：** sourcemod.cfg 的 `sm_cvar ss_time_mode 1` 已删除，`ss_time_mode` 为 0 且 `specialspawner.cfg` 配置 45-60s，但实际间隔仍是 ~12 秒（sourcemod.cfg 的问题 #6 修复后仍然存在）。

**RCON 验证：**
```
ss_time_min = 12.449183  (def. 10.0)
ss_time_max = 12.449183  (def. 15.0)
ss_time_mode = 0          ← 正确
```

两个 cvar 钉在同一个 ~12.4 的值，说明 `PinSpawnTiming()` 在用 `random(~12.4, ~12.4)` = 12.4。`g_fCfgTimeMin`/`g_fCfgTimeMax` 被设成了 specialspawner 的编译默认值 10/15 而不是 cfg 的 45/60。

**根因：** SourceMod 执行序 = `OnPluginStart` → `OnMapStart` → cfgs 执行 → `OnConfigsExecuted`。

1. `OnPluginStart` 第 194 行：`CaptureSourceRange()` 从 live cvar 读 → specialspawner.cfg 还没执行 → 读到编译默认值 `min=10.0, max=15.0`
2. `OnPluginStart` 第 197 行：`PinSpawnTiming()` → `random(10, 15)` = ~12.4 → 把两个 cvar 都写成 ~12.4
3. `OnMapStart` 第 307 行：`CaptureSourceRange()` 再次从 live cvar 读 → 此时 cvar 已被钉成 (12.4, 12.4) → **反馈循环**，永远 12.4
4. `specialspawner.cfg` 执行 → 写 45/60 → 但 **没人读了**，`CaptureSourceRange()` 只在 OnPluginStart 和 OnMapStart 调用

**修复（v2.3.5）：**
1. 从 `OnPluginStart` 移除 `CaptureSourceRange()` / `PinSpawnTiming()` / `AdjustSpawnSize()`
2. 从 `OnMapStart` 移除 `CaptureSourceRange()`（读到的是 Pin 残余值）
3. 新增 `OnConfigsExecuted()` 回调，在此处调用上述三个函数 — cfg 保证已执行

**连带修复：** `g_fCfgBaseSpawnSize` 同样在 `OnPluginStart` 从 `ss_spawn_size` 捕获（line 189-191），那时 cfg 未执行读到的是默认值 4 而非配置值 6。也移到 `OnConfigsExecuted`。

**教训：**
- `OnPluginStart` 不能读其他插件的 cvar → 此时 cfg 全部未执行
- `OnMapStart` 不能读可能有"写回"行为的 cvar → Pin 后的残余值导致反馈循环
- **唯一安全时机 = `OnConfigsExecuted`**：cfg 刚执行完，无人改写过 cvar
- 硬编码默认值（`g_fCfgTimeMin=45.0` 行 110-111）只是 fallback，不能依赖
