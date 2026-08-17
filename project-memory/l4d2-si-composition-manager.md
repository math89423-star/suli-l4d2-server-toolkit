---
name: l4d2-si-composition-manager
description: 特感刷新组合管理器 v2.3.9 — 6种战术模式轮换（热重载不冻结，SM 补发 OnMapStart 实证）+ Tank协同 + 倒地补偿播报镜像
metadata: 
  node_type: memory
  type: project
  modified: 2026-08-15T07:37:51.702Z
  originSessionId: 8be29424-bfe9-42be-82e0-ad49b8009603
---

# L4D2 SI 刷新组合管理器 v2.4.0

**插件：** `si_composition_manager.smx` v2.4.0（备份 .bak.20260804_v239_pre_v240）
**源码：** `scripting/si_composition_manager.sp`
**配置：** `cfg/sourcemod/si_composition_manager.cfg`

## ⚠️ v2.4.0 关键教训：OnConfigsExecuted 只在换图/服务器启动触发（2026-08-04 实测）

**`sm plugins reload` 和 rcon `exec` 都不会触发 OnConfigsExecuted**（两次实测：reload 后
钉值回到硬编码默认 45/60、spawn 基线回到 6.0；exec 后 live 值只有 exec 本身写入的原始值）。
旧版 CaptureSourceRange 从 ss_time_min/max 捕获区间 → reload 后捕获失效 → **波次 35-50
怎么热应用都不生效**（实测 reload 后钉 56.6/58.2 = 默认 45/60 区间）。

**v2.4.0 修复**：波次区间来源改为**自身 cvar**（si_comp_mode_interval_min/max，
源码默认 35/50）——永不被动、reload 即生效；CaptureSourceRange 整个删除；模式轮换
与波次共用同一区间（cvar 描述本意 "synced"）。spawn 大小基线（g_fCfgBaseSpawnSize
从 ss_spawn_size 捕获）仍走 OnConfigsExecuted → **换图后自动落位，reload 改不了**。

**操作铁律**：si_comp 相关热改 → 改它自己的 cvar（si_comp_*，reload 即生效）；
涉及 specialspawner.cfg 基线（ss_time_*/ss_spawn_size）→ 换图才完全生效。

## v2.3.4 改动（2026-07-27）

1. **刷新数量公式改为直接乘法** — `spawn_size = ceil(存活人数 × ss_extra_limit)`，不再使用原来的 `base + extra × delta` 公式（原来因为 base_spawn_size≠extra_limit×base_size，结果永远少1只）
2. **播报增加存活数** — `[SI波次] 特感已刷新 6只! 进攻策略: 地空协同 | 存活: 5/8 | 下一波: 55秒后`
3. **修复 ReadSourceRange 反馈循环** — `CaptureSourceRange()` 只在 OnMapStart 读一次配置值，不再每波从 cvars 重读（PinSpawnTiming 把自己写的值又读回来了）
4. **移除 g_fCfgBaseSpawnSize** — 不再需要，公式不依赖 base_spawn_size

## 核心设计

### 波次规模公式（v2.3.4 直接乘法 → 2026-08 已改回 specialspawner 同款公式）

```
delta      = (存活人数 − ss_base_size 4) / ss_extra_size 1
spawn_size = round(基准 6 + ss_extra_limit 1.5 × delta)，下限 4，上限 = alive_limit
```
- `g_fCfgBaseSpawnSize` 基准只在 OnConfigsExecuted 抓一次（防自反馈），写 ss_spawn_size cvar
- 人数变化即时重算（PlayerTeam / PlayerDisconnect / 每波 PinSpawnTiming）
- **倒地补偿不写 cvar**：specialspawner v1.5.0 在 ExecuteSpawnQueue 刷怪瞬间按站立/总人数
  临时收缩（见 [[l4d2-specialspawner-config]]），si_comp v2.3.8 播报镜像同公式

### 模式差异化（v2）
每种模式**刻意省略 2-3 类特感**以建立鲜明辨识度。零比例类型 deficit 始终 ≤0，缺口算法自动排除。

### 自行管理刷新间隔（v2.1）
- `ss_time_mode 0`（随机间隔），插件接管随机计时
- 每波 pin min=max 到同一随机值，`random(X,X)=X` → 精确倒计时
- 播报显示精确倒计时
- **v2.3.4**: 源范围在 OnMapStart 捕获一次，不再从被 pin 过的 cvars 重读

### 波次检测
- `L4D_OnSpawnSpecial` 首次 spawn 判定为新波次（冷却 > ss_time_min/2）
- 每波只播报一次

## 7 种模式

| # | 模式 | S | B | H | Sp | J | C | 省略 | 主题 |
|---|------|---|---|---|----|---|---|------|------|
| 1 | 钢铁洪流 | 0 | 0 | 35 | 0 | 25 | 40 | Sm,Bm,Sp | 纯近战 |
| 2 | 暗影锁链 | 35 | 25 | 0 | 25 | 15 | 0 | H,C | 纯控制+尸潮 |
| 3 | 地空协同 | 0 | 0 | 35 | 20 | 20 | 25 | Sm,Bm | 天地夹击 |
| 4 | 生化危机 | 25 | 30 | 0 | 30 | 0 | 15 | H,J | 区域毒压 |
| 5 | 猎手集群 | 15 | 0 | 40 | 15 | 30 | 0 | C,Bm | 高速机动 |
| 6 | 均衡演武 | 17 | 16 | 17 | 16 | 17 | 17 | — | 全类型 |
| T | 巨兽协同 | 0 | 0 | 30 | 20 | 20 | 30 | Sm,Bm | Tank支援 |

## Cvars

| cvar | 默认 | 说明 |
|---|---|---|
| `si_comp_enable` | 1 | 总开关 |
| `si_comp_mode_interval_min` | **20.0**（2026-08-05 v2.0.0 由 40 下调） | 波次间隔 + 模式轮换区间下限（钉到 ss_time_min/max）——三态生命周期下冷静期(12-18s)承担缓冲, 波间隔缩短; 冷静期后间隔 = 钉值−平均冷静, 播报"X秒后下一波"≈22-38s |
| `si_comp_mode_interval_max` | **25.0**（2026-08-15 由 35 下调；原 v2.0.0 由 55→35） | 波次间隔 + 模式轮换区间上限（钉到 ss_time_min/max） |

**2026-08-15 波次间隔下调 35→25（用户要 20-25s/波）**：只改 `si_comp_mode_interval_max` 25。
实际总周期公式见 [[l4d2-specialspawner-config]] 的三态：**总周期 = REST(段位动态) + PostRestInterval**，
`PostRestInterval = 钉值 − 平均冷静, clamp[10,45]`。钉值 20-25 时 PostRest 恒被 clamp 到 **10s**
（20-25 − 15 = 5-10 → 10）。所以 T2 段位（冷静 12-18s）实际总周期 = **22-28s**（实测 REST 16.2→IDLE 10.0 = 26.2s）。
⚠️ **想严格压到 20-25s 需同时缩 ss_rest_max**（T2 上限 18→15），否则受冷静期上限拖到 28s。
已热更 + 写 cfg + git commit 6182e9d。
| `si_comp_announce` | 0 | 模式切换聊天公告 |
| `si_comp_wave_announce` | 1 | 波次播报（策略+倒计时+倒地补偿） |

## 播报格式（v2.3.8+，存活数已移除）

```
[SI波次] 特感已刷新 6只! 进攻策略: 钢铁洪流
[SI波次] 特感已刷新 5只(倒地补偿 10→5)! 进攻策略: 地空协同
```
**v2.0.0 去后缀**：去掉"| 下一波: X秒后"——三态下间隔在冷静期结束才消费（旧"播旧钉值"对齐失效）；倒计时播报由 specialspawner 进入冷静期时统一给出（[特感] 波次清剿完毕，X 秒后下一波）。

## 热重载实证（2026-08-04，v2.3.9）

- **SourceMod 对 late-load 插件补发 OnMapStart** → 模式轮换定时器链自动重建，
  热重载不冻结（曾误判为冻结并加 late-load 兜底块，active_mode 0→1 实证后已撤）
- **模式可达性**：RotateMode 每步在"除当前外的 5 个模式"中均匀随机（GetRandomInt(0,4)
  + ≥当前则 +1）→ 6 模式全部可达、不会连续重复；换图随机起手；Tank 存活时暂停轮换
- **实测轮换**：重载后 95s 内 3→2→4 两次轮换，链工作正常
- `si_comp_active_mode`：0-5 普通模式 / 6 = Tank 巨兽协同，AI_HardSI_bt 读取做行为配合

## 重要配置

- `ss_time_mode 0` — 随机模式，插件 pin min=max 实现精确倒计时
- `ss_spawnrange_min 200` — 防引擎处死远处 SI（500 太大，可用出生点不够）

## 相关记忆

- [[l4d2-specialspawner-config]] — specialspawner 全部 cvar
- [[l4d2-plugin-inventory]] — 插件清单
- [[l4d2-si-composition-timing-pitfall]] — 启动顺序 + 反馈循环根因
