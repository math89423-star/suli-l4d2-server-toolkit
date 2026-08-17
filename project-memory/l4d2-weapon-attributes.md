---
name: l4d2-weapon-attributes
description: L4D2 武器属性插件 — 架构、支持属性清单、配置方式
metadata: 
  node_type: memory
  type: reference
  tags: 
    - l4d2
    - weapon
    - attributes
    - sourcemod
    - left4dhooks
  originSessionId: 80150717-1ebf-41b6-aabc-32c17b3d7ded
  modified: 2026-07-29T01:26:51.254Z
---

# L4D2 武器属性插件

## 插件架构

武器属性修改由两层配合完成：

```
l4d2_weapon_attributes.smx (v2.0.0, 自定义插件)
    └── 注册 sm_weapon 命令，解析属性名 → 调用 left4dhooks natives
left4dhooks.smx (v1.168, SilvDev 扩展)
    └── 提供 L4D2_SetIntWeaponAttribute / L4D2_SetFloatWeaponAttribute
```

## 关键踩坑：后坐力控制

**正确做法**（只有两行 `sm_cvar`）：
```
sm_cvar z_gun_vertical_punch 0
sm_cvar z_gun_horiz_punch 0
```

`z_gun_vertical_punch` 和 `z_gun_horiz_punch` 是 replicated convar，设为 0 后引擎完全跳过武器开火的视角冲量（viewpunch）。

### 注意事项
1. **必须用 `sm_cvar`**：这两个是 cheat-protected cvar，直接写 server.cfg 会被引擎拒绝，必须通过 SourceMod 的 `sm_cvar` 设置。
2. **`sm_weapon verticalpunch` 无效**：L4D2 引擎的视角抖动系统不从武器属性接口读取，运行时修改武器属性的 verticalpunch 不会生效。不要画蛇添足加 per-weapon punch 设置。
3. **只有 VerticalPunch，没有 HorizontalPunch**：L4D2 武器脚本里只有 VerticalPunch 属性，水平抖动实际由散布系统（SpreadPerShot / MaxSpread）控制。
4. **不要额外插件**：之前 l4d2_punch_fix.smx 用 SendConVarValue 去"强化"这个设置，反而干扰了 sm_cvar 的正常复制，导致抖动恢复。已删除。两行 sm_cvar 就够了，越简单越稳。
5. **写入位置**：`cfg/sourcemod/sourcemod.cfg`，这个文件每次换图必定执行，比插件自己的 cfg 可靠。

所有 `sm_weapon` 命令写在 `data/cfg/weapon_init.cfg` 中（由 sourcemod.cfg 中 `exec weapon_init.cfg` 在启动时一次性加载，避免换图 Cbuf overflow）：

```
sm_weapon <武器名> <属性> <值>
```

武器名可省略 `weapon_` 前缀（如 `smg` 等价于 `weapon_smg`）。

## 全属性清单（v2.0.0 支持 32 个）

### Int 属性（整数值）

| 命令名 | Left4DHooks 枚举 | 说明 |
|--------|-----------------|------|
| `damage` | `L4D2IWA_Damage` | 基础伤害 |
| `bullets` | `L4D2IWA_Bullets` | 每次射击弹丸数 |
| `clipsize` | `L4D2IWA_ClipSize` | 弹匣容量 |
| `bucket` | `L4D2IWA_Bucket` | 弹药桶类型 |
| `tier` | `L4D2IWA_Tier` | 武器等级 (L4D2) |

### Float 属性（小数值）

| 命令名 | 别名 | Left4DHooks 枚举 | 说明 |
|--------|------|-----------------|------|
| `cycletime` | — | `L4D2FWA_CycleTime` | 射速间隔 |
| `range` | — | `L4D2FWA_Range` | 有效射程 |
| `rangemod` | `rangemodifier` | `L4D2FWA_RangeModifier` | 距离衰减系数 |
| `minstandspread` | `minstandingspread` | `L4D2FWA_MinStandingSpread` | 站立最小散布 |
| `minmovespread` | `maxmovementspread` | `L4D2FWA_MaxMovementSpread` | 移动最大散布 |
| `mincrouchspread` | `minduckingspread` | `L4D2FWA_MinDuckingSpread` | 蹲下最小散布 |
| `mininairspread` | — | `L4D2FWA_MinInAirSpread` | 空中最小散布 |
| `maxspread` | — | `L4D2FWA_MaxSpread` | 最大散布 |
| `spreadpershot` | — | `L4D2FWA_SpreadPerShot` | 每发射击散布增量 |
| `spreaddecay` | — | `L4D2FWA_SpreadDecay` | 散布衰减速度 |
| `penpower` | — | `L4D2FWA_PenetrationPower` | 穿透力 |
| `penlayers` | `pennumlayers` | `L4D2FWA_PenetrationNumLayers` | 穿透层数 |
| `penmaxdist` | — | `L4D2FWA_PenetrationMaxDist` | 穿透最大距离 |
| `charpenmaxdist` | — | `L4D2FWA_CharPenetrationMaxDist` | 穿透角色最大距离 |
| `scatterpitch` | `pelletscatterpitch` | `L4D2FWA_PelletScatterPitch` | 霰弹纵向散布 |
| `scatteryaw` | `pelletscatteryaw` | `L4D2FWA_PelletScatterYaw` | 霰弹横向散布 |
| `verticalpunch` | — | `L4D2FWA_VerticalPunch` | 垂直后坐力 |
| `horizontalpunch` | — | `L4D2FWA_HorizontalPunch` | 水平后坐力 |
| `reloadduration` | — | `L4D2FWA_ReloadDuration` | 换弹时间 |
| `maxplayerspeed` | — | `L4D2FWA_MaxPlayerSpeed` | 持枪最大移速 |
| `gainrange` | — | `L4D2FWA_GainRange` | 伤害增益范围 |

## 旧版插件问题

旧版 `l4d2_weapon_attributes.smx`（18KB，来源不明）不支持以下三个属性，日志会报 `Bad attribute name`：
- `clipsize` ❌
- `minmovespread` ❌
- `mincrouchspread` ❌

新版 v2.0.0 通过 left4dhooks natives 直接调用，全部支持。

## 当前武器配置值

详见 `weapon_init.cfg` 中的 `sm_weapon` 行（20 把武器，属性各有侧重）。

## 源码位置

`/opt/gameservers/l4d2/data/addons/sourcemod/scripting/l4d2_weapon_attributes.sp`

## 伤害衰减公式 (2026-07-29 验证)

```
if distance ≤ GainRange:      multiplier = 1.0
elif distance ≥ Range:        multiplier = RangeModifier
else:                         multiplier = 1.0 + (RangeModifier - 1.0) × (distance - GainRange) / (Range - GainRange)
```

- **Range** = 子弹最大存活距离 + 衰减终点。超过此距离伤害恒定 = base × RangeModifier
- **RangeModifier** = 最远距离伤害占比。1.00 = 零衰减, 0.92 = 8% 衰减
- **GainRange** = 衰减起点。在此之前全额伤害。rangemod=1.00 时 GainRange 无意义
- ⚡ **核心踩坑**: rangemod 0.97-0.99 表示全程仅掉 1-3%，曲线几乎平坦。改 Range/GainRange 无体感——只有把 rangemod 拉到 0.92 以下或直接 1.00 才能感知差异。

## 关联

- [[l4d2-howto-plugins]] — 插件安装/禁用流程
- [[l4d2-server-quick-reference]] — 服务器管理速查
- [[l4d2-weapon-values]] — 全武器当前 vs 默认值对照表

## 2026-08-16 补充：sv_cheats 会复位 cheat-replicated cvar（抖动复发坑）

**现象**：用户进服后"开火画面抖动又回来了"（只有垂直抖动，水平正常）。
**根因**：`z_gun_vertical_punch` 引擎默认 =1（`def. "1"`），`z_gun_horiz_punch` 默认 =0。
冒烟测试时执行过 `sm_cvar sv_cheats 1` 再 `sm_cvar sv_cheats 0`，sv_cheats 切换会触发
"game cheat replicated" 类 cvar 的复制同步复位为引擎默认值 → vertical 回 1（抖动回来），
horiz 回默认 0（无变化）。这就是为什么只垂直抖动、水平不抖。
**教训**：调试/冒烟测试开 sv_cheats 后必须检查并重设被它复位的 cheat cvar
（尤其 z_gun_vertical_punch 0）。恢复命令：
```
sm_cvar z_gun_vertical_punch 0
sm_cvar z_gun_horiz_punch 0
```
**检查技巧**：RCON 查 `z_gun_vertical_punch` 看 `def.` 值可判断引擎默认。
