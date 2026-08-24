---
name: l4d2-weapon-values
description: L4D2 全武器当前配置 vs 官方默认值对比表，便于随时修正
metadata: 
  node_type: memory
  type: reference
  tags: 
    - l4d2
    - weapon
    - balance
    - config
  originSessionId: 21bfd058-aa5d-4486-8138-a401bab03214
  modified: 2026-08-03T15:24:34.478Z
---

# L4D2 武器数值对照表

> 更新时间: 2026-08-22（SMG×3 +10% 36/40/44 600/615/586DPS；SG552 0.0825→0.08 12.5RPS 612DPS；M16 53→52 实验100→52；Scout 315→295 AWP 475→385 仓库与部署对齐，用户核验；M16 0.088→0.086 0.084 太凶；马格南
> **105→108 用户拍板**（Hunter 3枪/Jockey 4枪差异化 108×3=324<325 + Witch 15→14发，
> 原文件 115 是 08-17 00:06 未生效改动，已覆盖为 108），RCON 均已即时生效；
> ⚠️ **2026-07-29 衰减重构**: rangemod — 步枪/SMG/狙击→1.00(零衰减), 手枪/霰弹→0.92(8%衰减), gainrange 贴近 range
> ⚠️ **2026-07-29 散布重构**: 移动散布收紧 AR×0.6 / SMG×0.5 / 狙击×0.7, 站立散布按等级重排, 全局约束 movement > standing
> 默认值来源: `pak01_*.vpk` 内 `scripts/weapon_*.txt`（TLS 更新后，2026-07-21 重新提取验证）
> 当前值来源: `cfg/weapon_init.cfg`（启动时由 sourcemod.cfg 中 `exec weapon_init.cfg` 加载）

## 伤害衰减公式 (2026-07-29 验证)

```
if distance ≤ GainRange:      multiplier = 1.0
elif distance ≥ Range:        multiplier = RangeModifier
else:                         multiplier = 1.0 + (RangeModifier - 1.0) × (distance - GainRange) / (Range - GainRange)
```

- **Range** = 子弹最大存活距离 + 衰减终点。超过此距离伤害恒定 = base × RangeModifier
- **RangeModifier** = 最远距离伤害占比。1.00 = 零衰减, 0.92 = 8% 衰减
- **GainRange** = 衰减起点。在此之前全额伤害。rangemod=1.00 时 GainRange 无意义
- ⚡ **关键发现**: 旧 rangemod 0.97-0.99 衰减仅 1-3%，曲线几乎平坦，改 GainRange/Range 无体感

## 生效方式说明

| 属性 | 生效方式 | 说明 |
|------|---------|------|
| damage, range, rangemod, gainrange | `sm_weapon` + left4dhooks | ✅ 所有武器生效 |
| minstandspread, minmovespread, mincrouchspread | `sm_weapon` + left4dhooks | ✅ 步枪/SMG/手枪/狙击生效 |
| penpower, penlayers | `sm_weapon` + left4dhooks | ✅ 所有武器生效 |
| cycletime, reloadduration（步枪/SMG） | `sm_weapon` + left4dhooks | ✅ 自动武器生效 |
| cycletime, reloadduration（霰弹枪） | WeaponHandling `l4d2_shotgun_speed.cfg` | ❌ sm_weapon 无效 |
| scatterpitch, scatteryaw（霰弹枪） | **暂无方案** | ❌ sm_weapon 无效 |
| clipsize（已配置的武器） | `sm_weapon` + left4dhooks | ✅ 生效，⚠️ uint8 上限 254（255 显示为 0，超则溢出如 450→194） |
| verticalpunch, horizontalpunch | `sm_cvar z_gun_*` | ✅ 全局生效，不要 per-weapon |

---

## 手枪

| 武器 | 属性 | 当前值 | 默认值 |
|------|------|--------|--------|
| **pistol** | damage | 40 | 36 |
| | range | 3600 | 2500 |
| | rangemod | 0.92 | 0.75 |
| | gainrange | 1200 | — |
| | cycletime | 0.14 | 0.175 |
| | minstandspread | 0.40 | 1.5 |
| | minmovespread | 0.45 | 3.0 |
| | mincrouchspread | 0.26 | 0.5 |
| | penpower | 50 | 30 |
| | penlayers | 2 | 2 |
| | clipsize | — | 15 |
| **pistol_magnum** | damage | **108** | 80 |
| | range | 4400 | 3500 |
| | rangemod | 0.92 | 0.75 |
| | gainrange | 1500 | — |
| | cycletime | 0.30 | 0.30 |
| | minstandspread | 0.50 | 1.25 |
| | minmovespread | 0.55 | 3.0 |
| | mincrouchspread | 0.30 | 0.5 |
| | penpower | 50 | 50 |
| | penlayers | 2 | 2 |
| | clipsize | — | 8 |

## 冲锋枪

| 武器 | 属性 | 当前值 | 默认值 |
|------|------|--------|--------|
| **smg** | damage | 36 | 20 |
| | range | 4200 | 2500 |
| | rangemod | 1.00 | 0.84 |
| | gainrange | 4100 | — |
| | cycletime | 0.060 | 0.0625 |
| | minstandspread | 0.45 | — |
| | minmovespread | 0.50 | — |
| | mincrouchspread | 0.30 | — |
| | penpower | 50 | 30 |
| | penlayers | 2 | 2 |
| | clipsize | — | 50 |
| **smg_silenced** | damage | 40 | 25 |
| | range | 4200 | 2200 |
| | rangemod | 1.00 | 0.84 |
| | gainrange | 4100 | 900 |
| | cycletime | 0.065 | 0.0625 |
| | minstandspread | 0.40 | — |
| | minmovespread | 0.45 | — |
| | mincrouchspread | 0.26 | — |
| | penpower | 50 | 30 |
| | penlayers | 2 | 2 |
| | clipsize | — | 50 |
| **smg_mp5** | damage | 44 | 24 |
| | range | 4300 | 2500 |
| | rangemod | 1.00 | 0.84 |
| | gainrange | 4200 | — |
| | cycletime | 0.075 | 0.075 |
| | minstandspread | 0.36 | — |
| | minmovespread | 0.40 | — |
| | mincrouchspread | 0.26 | — |
| | penpower | 50 | 30 |
| | penlayers | 2 | 2 |
| | clipsize | — | 50 |

## 步枪

| 武器 | 属性 | 当前值 | 默认值 |
|------|------|--------|--------|
| **rifle** (M16) | damage | 52 | 33 |
| | range | 4800 | 3000 |
| | rangemod | 1.00 | 0.97 |
| | gainrange | 4700 | 1500 |
| | cycletime | **0.086** | 0.0875 |
| | minstandspread | 0.35 | — |
| | minmovespread | 0.44 | — |
| | mincrouchspread | 0.15 | — |
| | penpower | 65 | 50 |
| | penlayers | 3 | 2 |
| | clipsize | — | 50 |
| **rifle_sg552** | damage | 49 | 33 |
| | range | 4700 | 3000 |
| | rangemod | 1.00 | 0.97 |
| | gainrange | 4600 | 1500 |
| | cycletime | 0.08 | 0.0825 |
| | minstandspread | 0.30 | — |
| | minmovespread | 0.42 | — |
| | mincrouchspread | 0.05 | — |
| | penpower | 65 | 50 |
| | penlayers | 3 | 2 |
| | clipsize | — | 50 |
| **rifle_ak47** | damage | 67 | 58 |
| | range | 4500 | 3000 |
| | rangemod | 1.00 | 0.97 |
| | gainrange | 4400 | 1500 |
| | cycletime | 0.113 | 0.13 |
| | minstandspread | 0.42 | — |
| | minmovespread | 0.50 | — |
| | mincrouchspread | 0.2 | — |
| | penpower | 80 | 50 |
| | penlayers | 4 | 2 |
| | clipsize | 40 | 40 |
| **rifle_desert** | damage | 55 | 44 |
| | range | 5200 | 3000 |
| | rangemod | 1.00 | 0.97 |
| | gainrange | 5100 | 1500 |
| | cycletime | — | 0.07 |
| | minstandspread | 0.24 | — |
| | minmovespread | 0.28 | — |
| | mincrouchspread | 0.05 | — |
| | penpower | 65 | 50 |
| | penlayers | 3 | 2 |
| | clipsize | — | 60 |
| **rifle_m60** | damage | 78 | 50 |
| | range | 5200 | 3000 |
| | rangemod | 1.00 | 0.97 |
| | gainrange | 5100 | 1500 |
| | cycletime | — | 0.11 |
| | minstandspread | 0.40 | — |
| | minmovespread | 0.55 | — |
| | mincrouchspread | 0.05 | — |
| | penpower | 80 | 50 |
| | penlayers | 4 | 2 |
| | clipsize | 150 | 150 |

## 狙击

| 武器 | 属性 | 当前值 | 默认值 |
|------|------|--------|--------|
| **hunting_rifle** | damage | 115 | 90 |
| | range | 7000 | 8192 |
| | rangemod | 1.00 | 1.0 |
| | gainrange | 6900 | — |
| | cycletime | 0.213 | 0.25 |
| | minstandspread | 0.08 | — |
| | minmovespread | 0.56 | — |
| | mincrouchspread | 0.0 | — |
| | penpower | 65 | 50 |
| | penlayers | 3 | 2 |
| | clipsize | — | 15 |
| **sniper_military** | damage | 145 | 90 |
| | range | 7000 | 8192 |
| | rangemod | 1.00 | 1.0 |
| | gainrange | 6900 | — |
| | cycletime | - | 0.25 |
| | minstandspread | 0.06 | — |
| | minmovespread | 0.53 | — |
| | mincrouchspread | 0.05 | — |
| | penpower | 100 | 50 |
| | penlayers | 4 | 2 |
| | clipsize | — | 30 |
| **sniper_scout** | damage | 295 | 90 |
| | range | 8192 | 8192 |
| | rangemod | 1.00 | 1.0 |
| | gainrange | 8092 | — |
| | cycletime | 0.765 | 0.9 |
| | minstandspread | 0.04 | — |
| | minmovespread | 0.42 | — |
| | mincrouchspread | 0.0 | — |
| | penpower | 120 | 50 |
| | penlayers | 5 | 2 |
| | clipsize | — | 15 |
| **sniper_awp** | damage | 385 | 115 |
| | range | 8400 | 8192 |
| | rangemod | 1.00 | 1.0 |
| | gainrange | 8300 | — |
| | cycletime | 0.9975 | 1.05 |
| | minstandspread | 0.02 | — |
| | minmovespread | 0.56 | — |
| | mincrouchspread | 0.0 | — |
| | penpower | 120 | 50 |
| | penlayers | 5 | 2 |
| | clipsize | — | 20 |

## 霰弹枪

> sm_weapon 设置 damage/range/rangemod/gainrange/penpower/penlayers。射速和换弹走 WeaponHandling (`l4d2_shotgun_speed.cfg`)，散布暂无修改方案。

| 武器 | 属性 | 当前值 | 默认值 |
|------|------|--------|--------|
| **pumpshotgun** | damage | 45 | 25 |
| | range | 3800 | 3000 |
| | rangemod | 0.92 | 0.7 |
| | gainrange | 1200 | — |
| | penpower | 50 | 30 |
| | penlayers | 2 | 2 |
| | 换弹倍率 | 1.2x (WH) | 1.0 |
| | 射速倍率 | 1.15x (WH) | 1.0 |
| **shotgun_chrome** | damage | 51 | 31 |
| | range | 3800 | 3000 |
| | rangemod | 0.92 | 0.7 |
| | gainrange | 1200 | — |
| | penpower | 50 | 30 |
| | penlayers | 2 | 2 |
| | 换弹倍率 | 1.2x (WH) | 1.0 |
| | 射速倍率 | 1.15x (WH) | 1.0 |
| **autoshotgun** | damage | 32 | 23 |
| | range | 3800 | 3000 |
| | rangemod | 0.92 | 0.7 |
| | gainrange | 1200 | — |
| | penpower | 50 | 30 |
| | penlayers | 2 | 2 |
| | 换弹倍率 | 1.1x (WH) | 1.0 |
| | 射速倍率 | 1.0x (WH) | 1.0 |
| **shotgun_spas** | damage | 38 | 28 |
| | range | 3800 | 3000 |
| | rangemod | 0.92 | 0.7 |
| | gainrange | 1200 | — |
| | penpower | 50 | 30 |
| | penlayers | 2 | 2 |
| | 换弹倍率 | 1.1x (WH) | 1.0 |
| | 射速倍率 | 1.0x (WH) | 1.0 |

## 其他

| 武器 | 属性 | 当前值 | 默认值 |
|------|------|--------|--------|
| **grenade_launcher** | damage | 750 | 400 |
| | range | 3400 | 3000 |
| | rangemod | 1.00 | 0.97 |
| | gainrange | 3300 | — |
| | cycletime | 1.2 | 0.5 |
| | clipsize | 1 | 1 |
| **chainsaw** | clipsize | 90 | 30 |

## 全武器 DPS / TTK 对照表

> 更新时间: 2026-07-26
> 特感血量参考：Boomer 50 / Spitter 100 / Smoker 250 / Hunter 250 / Jockey 325 / Charger 600 / Witch 667 / Tank 4000
> TTK = 致死枪数 × 射速间隔（首枪瞬发 = (n-1) × cycletime）
> 霰弹 DPS 为全弹命中理论值，实际随距离衰减

### 数值总表

| 武器 | 单发 | 弹丸 | cycletime | RPS | DPS | 弹匣 | 总伤 |
|------|------|------|-----------|-----|-----|------|------|
| pistol | 40 | 1 | 0.14 | 7.1 | **286** | 15 | 600 |
| magnum | 108 | 1 | 0.30 | 3.3 | **360** | 8 | 864 |
| smg | 36 | 1 | 0.060 | 16.7 | **600** | 50 | 1,800 |
| smg_silenced | 40 | 1 | 0.065 | 15.4 | **615** | 50 | 2,000 |
| smg_mp5 | 44 | 1 | 0.075 | 13.3 | **586** | 50 | 2,200 |
| rifle (M16) | 52 | 1 | 0.086 | 11.6 | **605** | 50 | 2,600 |
| rifle_sg552 | 49 | 1 | 0.08 | 12.5 | **612** | 50 | 2,450 |
| rifle_ak47 | 67 | 1 | 0.113 | 8.8 | **593** | 40 | 2,680 |
| rifle_desert | 55 | 1 | ~0.111 | 9.0 | **495** | 60 | 3,300 |
| rifle_m60 | 78 | 1 | 0.11 | 9.1 | **709** | 150 | 11,700 |
| hunting_rifle | 115 | 1 | 0.213 | 4.7 | **540** | 15 | 1,725 |
| sniper_military | 145 | 1 | 0.25 | 4.0 | **580** | 30 | 4,350 |
| sniper_scout | 295 | 1 | 0.765 | 1.3 | **385** | 15 | 4,425 |
| sniper_awp | 385 | 1 | 0.9975 | 1.0 | **386** | 20 | 7,700 |
| grenade_launcher | 750 | 1 | 1.2 | 0.83 | **625** | 1 | 750 |
| pumpshotgun | 45 | 10 | 0.435 | 2.3 | **1,034** | 8 | 3,600 |
| shotgun_chrome | 51 | 8 | 0.435 | 2.3 | **938** | 8 | 3,264 |
| autoshotgun | 32 | 11 | 0.15 | 6.7 | **2,347** | 10 | 3,520 |
| shotgun_spas | 38 | 9 | 0.15 | 6.7 | **2,280** | 10 | 3,420 |

### 特感致死枪数 / TTK(秒)

> 枪数=ceil(特感HP÷单发伤害)，TTK=首枪0延迟+(n-1)×cycletime

| 武器 | 单发 | Hunter 250 | Jockey 325 | Charger 600 | Witch 667 | Tank 4000 |
|------|------|------------|-------------|--------------|-----------|------------|
| pistol | 40 | 7发 0.84s | 9发 1.12s | 15发 1.96s | 17发 2.24s | 100发 13.9s |
| magnum | 108 | 3发 0.60s | 4发 0.90s | 6发 1.50s | 7发 1.80s | 38发 11.1s |
| smg | 36 | 7发 0.36s | 10发 0.54s | 17发 0.96s | 19发 1.08s | 112发 6.7s |
| smg_silenced | 40 | 7发 0.39s | 9发 0.52s | 15发 0.91s | 17发 1.04s | 100发 6.4s |
| smg_mp5 | 44 | 6发 0.38s | 8发 0.53s | 14发 0.98s | 16发 1.13s | 91发 6.8s |
| rifle M16 | 52 | 5发 0.34s | 7发 0.52s | 12发 0.95s | 14发 1.12s | 77发 6.6s |
| rifle SG552 | 48 | 6发 0.41s | 7发 0.50s | 13发 0.99s | 14发 1.07s | 84发 6.8s |
| rifle AK47 | 65 | 4发 0.34s | 5发 0.45s | 10发 1.02s | 11发 1.13s | 62发 6.9s |
| rifle SCAR | 68 | 4发 0.33s | 5发 0.44s | 9发 0.89s | 10发 1.00s | 59发 6.4s |
| rifle M60 | 78 | 4发 0.33s | 5发 0.44s | 8发 0.77s | 20发 2.09s | 52发 5.6s |
| hunting | 115 | 3发 0.43s | 3发 0.43s | 6发 1.07s | 14发 2.77s | 35发 7.2s |
| military | 165 | **2发 0.25s** | **2发 0.25s** | 4发 0.75s | 5发 1.00s | 25发 6.0s |
| scout | 295 | **1发 🔥** | 2发 0.77s | 3发 1.53s | 3发 1.53s | 14发 9.9s |
| awp | 385 | **1发 🔥** | **1发 🔥** | 2发 1.00s | 2发 1.00s | 11发 10.0s |
| GL | 750 | **1发 AoE** | **1发 AoE** | **1发 AoE** | **1发 AoE** | 6发 6.0s |
| pump | 45×10 | **1发 🔥** | **1发 🔥** | 2发 0.44s | 2发 0.44s | 9发 3.5s |
| chrome | 51×8 | **1发 🔥** | **1发 🔥** | 2发 0.44s | 2发 0.44s | 10发 3.9s |
| auto | 32×11 | **1发 🔥** | **1发 🔥** | 2发 0.15s | 2发 0.15s | 12发 1.7s |
| spas | 38×9 | **1发 🔥** | **1发 🔥** | 2发 0.15s | 2发 0.15s | 12发 1.7s |

### 差异化总结

| 层级 | 武器 | 关键阈值 | 定位 |
|------|------|----------|------|
| 副武器 | pistol | — | 备用，不打特感 |
| 副武器 | magnum | 3枪 Hunter | 副武器 mini 狙 |
| SMG | smg / silenced / mp5 | 7-8枪 Hunter | 近战清潮，容错高 |
| AR 入门 | M16 / SG552 | 5-6枪 Hunter | 中距火力，均衡 |
| AR 主力 | AK47 / SCAR | 4-5枪 Hunter | 单发伤害高，穿透强 |
| AR 压制 | M60 | 4枪 Hunter, 254发 | 弹幕压制，无法换弹 |
| 半自动狙 | hunting | **2枪 Hunter** | 快速连点，DPS 610 |
| 半自动狙 | military | **2枪 Jockey** | 7.62 重狙，DPS 700 |
| 栓动狙 | scout | **1枪 Hunter/Smoker** | 秒杀低血特感 |
| 栓动狙 | awp | **1枪 Jockey** | 秒杀中血特感 |
| 榴弹 | GL | 非Tank全秒（含溅射 600 秒 Charger） | AoE 清场 |
| 泵喷 | pump / chrome | 全弹命中秒 Jockey | 近战爆发，逐发装填 |
| 连喷 | auto / spas | 全弹命中秒 Jockey | 近战压制，弹匣换弹 |

## 音画同步

> 修改武器射速（cycletime）后，音频系统默认 100ms 缓冲会导致枪声滞后于动画。

| 参数 | 当前值 | 默认值 | 说明 |
|------|--------|--------|------|
| snd_mixahead | 0.05 | 0.1 | 音频预缓冲时间（秒），越小声音越紧贴画面 |

**写入位置**：`cfg/sourcemod/sourcemod.cfg` 中 `sm_cvar snd_mixahead 0.05`

⚠️ 必须用 `sm_cvar`：`snd_mixahead` 是 cheat-protected cvar，直接写 server.cfg 无效。缩减到 0.05 对 CPU 开销可忽略。

## 配置文件索引

| 配置 | 路径 |
|------|------|
| 武器属性 (sm_weapon) | `cfg/weapon_init.cfg`（启动一次性加载） |
| M60 弹匣 | `cfg/sourcemod/l4d2_m60_ammo.cfg`（sm_weapon clipsize 对 M60 无效） |
| 榴弹溅射/FF/Tank/Witch | `cfg/sourcemod/l4d2_gl_splash_fix.cfg` |
| GL 备弹 | `sourcemod/scripting/l4d2_loot_drop.sp`（m_iExtraPrimaryAmmo） |
| 霰弹枪射速/换弹 | `cfg/sourcemod/l4d2_shotgun_speed.cfg` |
| 引擎 cvars (sm_cvar) | `cfg/sourcemod/sourcemod.cfg` |
| 后坐力 | `cfg/sourcemod/sourcemod.cfg` (sm_cvar z_gun_*) |
| 火焰伤害 | `cfg/sourcemod/sourcemod.cfg` (sm_cvar inferno_damage + survivor_burn_factor_*) |
| 音画同步 | `cfg/sourcemod/sourcemod.cfg` (sm_cvar snd_mixahead) |

## 散布总表 (2026-07-29 更新，含原版对比)

> 原版值来源: `pak01_dir.vpk` + `pak01_00{0,1,2}.vpk` 内 `scripts/weapon_*.txt` (2026-07-29 重新提取)

### 站立散布 (minstandspread) — 由大到小: 霰弹 > 马格南 > SMG ≈ 手枪 > AR > 狙击

| 武器 | 原版 | 当前 | 变化 |
|------|:----:|:----:|:----:|
| 马格南 | 1.25 | **0.50** | ✅ -60% |
| 消音SMG | 1.20 | **0.40** | ✅ -67% |
| MP5 | 1.10 | **0.36** | ✅ -67% |
| SMG | 1.00 | **0.45** | ✅ -55% |
| AK47 | 1.00 | **0.42** | ✅ -58% |
| 泵喷 | 0.80 | **0.55** | ✅ -31% |
| 铬喷 | 0.80 | **0.55** | ✅ -31% |
| 连喷 | 0.80 | **0.60** | ✅ -25% |
| SPAS | 0.75 | **0.58** | ✅ -23% |
| Military | 0.50 | **0.06** | ✅ -88% |
| GL | 0.40 | — | 未设 |
| M16 | 0.40 | **0.35** | ✅ -12% |
| SG552 | 0.40 | **0.30** | ✅ -25% |
| SCAR | 0.35 | **0.24** | ✅ -31% |
| Hunting | 0.10 | **0.08** | ✅ -20% |
| Scout | 0.10 | **0.04** | ✅ -60% |
| AWP | 0.10 | **0.02** | ✅ -80% |
| 手枪 | 1.50 | **0.40** | ✅ -73% |
| M60 | 0.40 | **0.40** | = 原版 (继承 rifle 模板) |

### 移动散布 (minmovespread) — 由大到小: 霰弹 > 狙击 > 马格南 > SMG ≈ 手枪 > AR

| 武器 | 原版 | 当前 | 变化 |
|------|:----:|:----:|:----:|
| 连喷 | 1.50 | **0.75** | ✅ -50% |
| 泵喷 | 1.50 | **0.70** | ✅ -53% |
| SPAS | 1.50 | **0.72** | ✅ -52% |
| 铬喷 | 1.50 | **0.68** | ✅ -55% |
| AK47 | 6.00 | **0.50** | ✅ -92% |
| M16 | 5.00 | **0.44** | ✅ -91% |
| SG552 | 5.00 | **0.42** | ✅ -92% |
| Military | 5.00 | **0.53** | ✅ -89% |
| GL | 5.00 | — | 未设 |
| SCAR | 4.00 | **0.28** | ✅ -93% |
| SMG | 3.00 | **0.50** | ✅ -83% |
| 消音SMG | 3.00 | **0.45** | ✅ -85% |
| MP5 | 3.00 | **0.40** | ✅ -87% |
| 手枪 | 3.00 | **0.45** | ✅ -85% |
| 马格南 | 3.00 | **0.55** | ✅ -82% |
| Hunting | 3.00 | **0.56** | ✅ -81% |
| Scout | 3.00 | **0.42** | ✅ -86% |
| AWP | 3.00 | **0.56** | ✅ -81% |
| M60 | 5.00 | **0.55** | ✅ -89% (继承 rifle 模板) |

### 蹲下散布 (mincrouchspread) — 原版=0 的保持 0

| 武器 | 原版 | 当前 | 变化 |
|------|:----:|:----:|:----:|
| 消音SMG | 0.85 | **0.26** | ✅ -69% |
| MP5 | 0.75 | **0.26** | ✅ -65% |
| SMG | 0.70 | **0.30** | ✅ -57% |
| AK47 | 0.50 | **0.20** | ✅ -60% |
| 手枪 | 0.50 | **0.26** | ✅ -48% |
| 马格南 | 0.50 | **0.30** | ✅ -40% |
| M16 | 0.05 | **0.15** | ✅ +200% |
| SG552 | 0.05 | **0.05** | = 原版 |
| SCAR | 0.05 | **0.05** | = 原版 |
| Military | 0.05 | **0.05** | = 原版 |
| GL | 0.05 | — | 未设 |
| 泵喷 | 0 | **0.0** | = 原版 |
| 铬喷 | 0 | **0.0** | = 原版 |
| 连喷 | 0 | **0.0** | = 原版 |
| SPAS | 0 | **0.0** | = 原版 |
| Hunting | 0 | **0.0** | = 原版 |
| Scout | 0 | **0.0** | = 原版 |
| AWP | 0 | **0.0** | = 原版 |
| M60 | 0.05 | **0.05** | = 原版 (继承 rifle 模板) |

> ⚡ **核心踩坑记录 (2026-07-29)**: 
> 1. 起初错误假定原版散布为 0，导致蹲姿从 0 反向加到 0.01~0.42（狙击/霰弹蹲姿比原版飘）
> 2. VPK 提取: `pak01_dir.vpk` 只含目录树，武器脚本在 `pak01_00{0,1,2}.vpk` chunk 文件里
> 3. 原版大量武器蹲姿=0 是刻意设计——蹲下就是激光枪，鼓励战术动作
> 4. 移动散布原版极大（3.0~6.0），我们的收紧幅度 50~93% 是实打实的提升 |

## 火焰/燃烧瓶伤害

| 参数 | 当前值 | 默认值 | 说明 |
|------|--------|--------|------|
| inferno_damage | 55 | 40 | 火焰基础伤害/秒 |
| inferno_flame_lifetime | 15 | — | 火焰持续时间 |
| inferno_max_range | 550 | 500 | 火焰最大蔓延距离 |
| survivor_burn_factor_easy | 0.3 | 0.2 | 火焰伤害倍率 |
| survivor_burn_factor_normal | 0.4 | 0.2 | |
| survivor_burn_factor_hard | 0.5 | 0.4 | **当前难度 (Hard)** |
| survivor_burn_factor_expert | 0.8 | 1.0 | |
| z_special_burn_dmg_scale | 3 | — | 特感受火焰伤害倍率 |

> ⚠️ **2026-07-20 踩坑**：燃烧瓶对幸存者伤害为 0，根因链：
> 1. `z_friendly_fire_forgiveness = 1` → 引擎判定火焰是"非故意友伤"→ 伤害清零
> 2. 枪支走 `TraceAttack`（在 forgiveness 之前），`l4d2_ff_fix` 可拦截
> 3. 火焰走 `OnTakeDamage`（在 forgiveness **之后**），收到已是 0
> 4. `sm_cvar` 和启动参数 `+z_friendly_fire_forgiveness 0` 均**无效**（引擎忽略 cheat cvar 的修改）
> **真正修复**：`l4d2_ff_fix.smx` v1.3 — 火焰也用"清零原伤害 + SDKHooks_TakeDamage 重放"绕开 forgiveness
