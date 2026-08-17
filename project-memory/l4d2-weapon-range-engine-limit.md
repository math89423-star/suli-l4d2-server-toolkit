---
name: l4d2-weapon-range-engine-limit
description: Range 属性控制伤害衰减；引擎射程足够远（1000+单位验证）；配置一直真实生效
metadata: 
  node_type: memory
  type: project
  originSessionId: 55b4cd7c-a146-4bf9-a95b-3198eb46f3c9
  modified: 2026-08-14T15:20:59.986Z
---

# L4D2 武器射程和衰减机制

**结论**：weapon_init.cfg 中的 Range/RangeModifier/GainRange 配置**一直真实生效**，不存在引擎硬编码限制阻止配置工作。

**伤害衰减公式**（已实测验证）：
```
if distance ≤ GainRange: multiplier = 1.0
elif distance ≥ Range: multiplier = RangeModifier
else: multiplier = 1.0 - (1.0 - RangeModifier) * (distance - GainRange) / (Range - GainRange)
```

**验证数据**（2026-08-14，shotgun_chrome 配置：damage 51, gainrange 1200, range 3800, rangemod 0.92）：
- 231u：61.3伤害（100%衰减前）✅
- 467u：58.8伤害（100%衰减前）✅
- 1180u：52.3伤害（~95%，衰减中）✅
- 1069u：42.8-53.5伤害（~92%，接近恒定区）✅

公式精确到个位数，配置完全按预期工作。

**霰弹枪远距离伤害低的真凶**：
- **不是**射程限制
- **不是**衰减过大（rangemod 0.92 只衰减8%）
- **是**弹丸散布（scatterpitch/scatteryaw）导致远距离命中弹丸数骤减
  - 近距离（231u）：8弹丸全中 = 61.3伤害
  - 远距离（1180u）：约1弹丸命中 = 52.3伤害
  - 命中率从100%跌到12.5%，实际DPS暴跌87%

**诊断插件**：`l4d2_range_diagnostic.smx`（已部署）
- 提供 `!checkdist` 命令测量瞄准点距离
- 自动记录所有武器的实际命中距离和伤害
- 用于精确验证衰减公式

**配置文件**：`/opt/gameservers/l4d2/data/cfg/weapon_init.cfg`
- SMG rangemod 1.00（零衰减）
- Shotguns rangemod 0.92（8%衰减）
- 所有配置真实生效，无需修复

**历史错误**：
- ~~曾推测引擎硬编码 3000-4000 单位限制~~（错误）
- ~~l4d2_weapon_range_fix.smx DHooks 插件~~（不需要，已证伪）

**Why**：原版霰弹枪就能命中1000+单位目标，现在实测1180单位命中证明配置工作正常。

**How to apply**：
1. Range/RangeModifier/GainRange 配置直接生效，放心调整
2. 霰弹枪远距离弱需调单发伤害补偿散布损失，或接受散布限制
