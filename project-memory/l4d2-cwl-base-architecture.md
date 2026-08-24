---
name: l4d2-cwl-base-architecture
description: CWL Base v0.83 (Workshop 3254000850) 核心架构审计——身份链、FP model workaround、射击/换弹系统
metadata:
  node_type: memory
  type: reference
  tags:
    - l4d2
    - cwl
    - custom-weapon
    - vscript
    - weapon-model
  originSessionId: suli-m14ebr-poc
  modified: 2026-08-20T01:00:00.000Z
---

# CWL Base (3254000850) 核心架构

## 概述
纯 VScript (Squirrel) 实现的自定义武器框架，~2000 行核心代码。
原作者 Rectus，由 Devlos/Solved 重写。

## 文件位置
解包路径：`/home/administrator/l4d2-custom-weapon-poc/cwl_base/`
审计报告：`/home/administrator/l4d2-custom-weapon-poc/docs/cwl_base_audit.md`

## 核心调用链

### 启动链
```
director_base_addon.nut (1行)
  → custom_weapon_lab_base.nut
    → AddLibrary() (加载 base_utils)
    → LoadWeaponController() (创建 g_WeaponLab 全局)
      → custom_weapon_lab_controller.nut (1649行核心)
        → Initialize()
          ├→ SpawnEntityFromTable("predicted_viewmodel")  ← fake VM 单例
          ├→ SpawnEntityFromTable("logic_script")         ← 控制器实体
          └→ AddThinkToEnt(Think, 0.01s)                 ← 每帧 tick
    → AddWeapons()
      ├→ 读 custom_weaponlab.cfg (武器列表 + ReplacePercentage)
      ├→ 遍历每个武器 → 读 weapon_xxx.cfg
      ├→ GetTrackedViewmodel(WeaponClass) → 原版 FP model path
      └→ g_WeaponLab.AddCustomWeapon() + SetReplaceRequirements()
```

### 实例身份链
```
地图 weapon_spawn 实体
  ↓ round_start_post_nav 延迟1秒
ReplaceWeaponSpawns()
  ├→ 遍历所有 weapon_* 实体
  ├→ GetSpawnClass() — 通过 worldmodel 路径判断武器类型
  ├→ 按 REPLACE_PRECENTAGE 随机选中
  ├→ Spawn.SetContext("CustomWeaponName", weaponName, -1)
  ├→ Spawn.SetContext("CustomFPmodel", fpModel, -1)
  ├→ Spawn.SetContext("CustomTPmodel", tpModel, -1)
  └→ Spawn.SetModel(tpModel)  ← 地面模型替换
```

### Pickup → 身份传递
```
OnGameEvent_player_use
  ├→ IsCustomWeapon(ent) — ent.GetContext("CustomWeaponName") != null
  ├→ SetCustomWeaponContext(heldWeapon, ent) — 复制三个 context
  ├→ DoIncludeScript(script, weaponScope)
  └→ weaponScope.OnInitialize()
```

### FP Model Workaround（核心）
```
SetViewModel(player, viewmodel, ModelName, FakeViewModel):
  FakeViewModel.SetModel(ModelName)                    ← 给 fake VM 设模型
  FakeViewModel_ModelIndex = m_nModelIndex              ← 读回 model index
  NetProps.SetPropInt(ViewModel, "m_nModelIndex", idx) ← 写入真实 player VM
```
- fake predicted_viewmodel 是全局单例，仅用于获取 model index
- 每次 OnEquipped 时执行一次，不是每帧盲写

### TP Model
```
AttachWeaponPropNew(player, WeaponModel):
  SpawnEntityFromTable("prop_dynamic_override", {model = WeaponModel})
  DisableCollision + DisableShadow
  SetParent(player)
  → SetParentAttachment("weapon_bone")
  → SetBody(prop, 1)  ← bodygroup=1 (invisible LOD)
```
- 使用 prop_dynamic_override 挂载到 weapon_bone
- bodygroup=1 隐藏——double gun / invisible gun 风险来源

### 射击（完全 Server-Sided）
```
Think() 每 0.01s → OnStartFiring() → FireWeapon()
  ├→ fireFrame = fireFrame_Calculation
  ├→ EmitSoundOn(FIRE_SOUND)
  ├→ ScreenShake()
  ├→ PlayFPSequence + PlayTPSequence
  ├→ m_iClip1 = Clip1Ammo - 1
  └→ TraceShot(player, origin, spreadDir)
      ├→ 遍历 NUM_SHOT，计算散布
      ├→ TraceLineIgnoreClass() 射线检测
      ├→ IsHeadShot() / GetTraceWound()
      ├→ SpawnEffect() 弹道粒子
      └→ entity.TakeDamageEx() 应用伤害
```
- 禁用 vanilla：m_flNextPrimaryAttack = Time() + 1000
- m_bInReload 强制=1（idle 客户端预测）

### 换弹（Custom Timer）
```
ReloadWeapon() → DoEntFire 延迟 → ReloadMagazine()
  ├→ m_iAmmo = Clip2Ammo + Clip1Ammo
  ├→ m_iClip1 = 0
  ├→ PlayFPSequence("reload_layer")
  └→ DoEntFire延迟 → ReloadMagazine()
      ├→ Clip2Ammo = (Clip2Ammo + Clip1Ammo) - CLIP1
      ├→ m_iClip1 = CLIP1
      └→ IsReloading = false
```
- 是社区报告 "reload hang" / "weapon hangs" 根因

## 4 把预置武器
| 武器 | WeaponClass | FP Model | TP Model | 特殊 |
|------|-------------|----------|----------|------|
| Steyr | weapon_rifle | v_rifle_steyr | w_rifle_steyr | ZOOM=true |
| Auto Shotgun | weapon_rifle | v_shotgun_auto | w_shotgun_auto | NUM_SHOT=8 |
| China Lake | weapon_shotgun_chrome | v_grenade_chaina | w_grenade_chaina | PROJECTILE=true |
| PKM | weapon_rifle_m60 | v_mg_pkm | w_mg_pkm | CLIP1=150 |

## 关键限制
1. FP Model 只在 slot0 生效
2. TP Model bodygroup=1 → double gun / invisible gun 风险
3. Server-sided firing → 客户端无射击预测
4. Custom reload → reload hang / weapon hangs
5. Inventory 用 PlayerName 作 key → 改名丢武器

## 对 PoC 的启示
- FP model workaround 可沿用（已验证有效）
- 但射击/换弹不应沿用（server-sided 弊大于利）
- 应采用 MK.II 的 "修改 vanilla cooldown" 路线
