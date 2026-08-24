---
name: l4d2-cwl-mk2-architecture
description: CWL MK.II (Workshop 3759448586) 架构审计——vanilla 保留型增强器，fire rate/reload/draw/movement multiplier
metadata:
  node_type: memory
  type: reference
  tags:
    - l4d2
    - cwl
    - mk2
    - custom-weapon
    - vscript
  originSessionId: suli-m14ebr-poc
  modified: 2026-08-20T01:00:00.000Z
---

# CWL MK.II (3759448586) 架构

## 概述
CWL Base 的大幅简化重写，从"完整武器接管框架"变为"vanilla 武器增强器"。
代码量减少 75%（~400 行 vs ~2000 行）。

## 文件位置
解包路径：`/home/administrator/l4d2-custom-weapon-poc/cwl_mk2/`
审计报告：`/home/administrator/l4d2-custom-weapon-poc/docs/cwl_mk2_audit.md`

## 核心架构变化

### 射击系统
**CWL Base**: Server-sided TraceShot + TakeDamageEx
**MK.II**: 保留 vanilla PrimaryAttack，通过修改 m_flNextPrimaryAttack 缩放射速

```
FireRateThink() — 每帧检查
  remaining = m_flNextPrimaryAttack - now
  newTime = now + remaining / fire_rate_multiplier
  → 写入 m_flNextPrimaryAttack + m_flNextSecondaryAttack
```

### 换弹系统
**CWL Base**: Custom timer + DoEntFire → reload hang 风险
**MK.II**: 保留 vanilla reload，修改 cooldown + playback rate

```
ReloadSpeedThink() — 检测长冷却窗口 (remaining > fire_reload_threshold)
  newTime = now + remaining * reload_speed_multiplier
  m_flPlaybackRate = 1.0 / reload_speed_multiplier  ← 同步动画速度
  reload_anim_buffer = 0.2s ← 尾帧缓冲
```

### Draw Speed（新增）
```
DrawSpeedThink() — 检测武器切换
  activeWeapon != scope.last_active_weapon → 新 draw
  newTime = now + remaining * draw_speed_multiplier
  修改 m_flNextPrimaryAttack + m_flNextSecondaryAttack + m_flNextAttack
```

### Movement Speed（新增）
```
MovementThink() — 每帧
  IsTargetWeapon(activeWeapon) → m_flLaggedMovementValue = multiplier
```

### 武器识别
```
IsTargetWeapon(activeWeapon) — 双重匹配
  classname == target_weapon
  AND CustomWeaponName == target_custom_weapon
```

### Spawn 替换
```
weapon_spawn_replacer — 确定性轮换
  SOURCE_SPAWNS = ["weapon_mp7"]
  REPLACEMENT_SPAWNS = ["weapon_smg_spawn", "weapon_smg_silenced_spawn", "weapon_smg_mp5_spawn"]
  按顺序分配，不 random
```

## MP7 配置
```squirrel
settings = {
    target_weapon             = "weapon_smg"
    target_custom_weapon      = "weapon_mp7"
    movement_speed_multiplier = 1.0
    headshot_multiplier       = 7.0
    draw_speed_multiplier     = 0.9      ← 10% faster draw
    fire_rate_multiplier      = 0.8      ← 25% faster fire rate
    reload_speed_multiplier   = 1.0      ← vanilla reload speed
    fire_detect_threshold     = 0.18
    fire_reload_threshold     = 1.5
    reload_anim_buffer        = 0.2
}
```

## FP Model（已确认）
沿用 Base 的 fake predicted_viewmodel workaround：
```
OnInitialize(): ViewModelIndex = GetModelIndex(CustomFPContext)
OnEquipped(): SetViewModel(player, viewmodel, CustomFPContext, Predicted_Viewmodel)
  → FakeViewModel.SetModel(ModelName)
  → 读 FakeViewModel.m_nModelIndex
  → 写入 Player.m_hViewModel.m_nModelIndex
```

## TP Model（已确认，比 Base 更完善）
```
OnEquipped():
  1. VanillaWorldModelIndex = self.m_nWorldModelIndex（保存原版）
  2. self.m_nWorldModelIndex = 0（隐藏原版世界模型）
  3. AttachWeaponPropNew(player, CustomTPContext)（创建 prop_dynamic_override）
  4. SetBody(Prop_Dynamic, 1)（bodygroup=invisible LOD）
  5. 人类玩家: Prop_Dynamic.m_fEffects |= EF_NODRAW(32)
OnThink: 每帧维护 m_nWorldModelIndex=0 + m_bSurvivorPositionHidingWeapons=1
Prop Watchdog: prop 被销毁时自动重建
```
关键改进：解决了 Base 的 double gun 问题（m_nWorldModelIndex=0 比 bodygroup=1 更可靠）

## Clipsize 问题
MP7 配置 AMMO_CLIP1=45，但 vanilla SMG weapon script clipsize=50
MK.II 不修改 weapon script → 引擎仍认为弹匣=50
处理方式：OnThink 每帧钳位 vanillaClip 到 AMMO_CLIP1
实际换弹：m_bInReload=0 阻断 vanilla reload → 自定义 ReloadWeapon()
注意：MK.II 声称 "保留 vanilla reload" 但实际是自定义实现

## Sound 问题
FIRE_SOUND = "Weapon_SG552.Single"（预缓存但不使用）
射击由 vanilla PrimaryAttack → 声音由引擎 weapon script 控制
结论：vanilla firing 下无法 per-instance 替换声音

## 对 PoC 的关键启示
1. **保留 vanilla 射击** ✅ — MK.II 已验证通过修改 cooldown 实现
2. **保留 vanilla 换弹** ✅ — MK.II 通过 cooldown + playback rate 实现
3. **PoC 应采用 MK.II 路线**，不用 Base 的完全接管
4. **FP model** 仍需沿用 Base 的 fake predicted_viewmodel workaround
5. **TP model** 需要更可靠的方案
