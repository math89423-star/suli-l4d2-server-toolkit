---
name: l4d2-tactical-ammo-shared
description: 武器特殊弹药共享池插件 — 按武器解锁燃烧/高爆、T循环切换、R补特殊弹、共享总池与高爆自伤
metadata: 
  node_type: memory
  type: project
  tags: 
    - l4d2
    - weapon
    - ammo
    - tactical
    - incendiary
    - explosive
  originSessionId: muse-spark-20260823-tactical-read
  modified: 2026-08-23T00:00:00.000Z
---

# L4D2 战术共享弹药池 (Tactical Shared Pool) v1.1.0

源码：`scripting/l4d2_tactical_ammo_shared.sp` (991行) → `plugins/l4d2_tactical_ammo_shared.smx`  
依赖：`left4dhooks` (`L4D2_GetIntWeaponAttribute`/`L4D2_GetFloatWeaponAttribute`/`L4D_StaggerPlayer`/`L4D2_SetEntityGlow`) + `sdkhooks` + `sdktools`  
配置：`cfg/sourcemod/l4d2_tactical_shared.cfg` (AutoExecConfig)

## 核心模型

- **共享总池 `g_iTotalPool[MAXPLAYERS+1]`**：`reserve(m_iAmmo) + curClip(m_iClip1/m_nUpgradedPrimaryAmmoLoaded)` 合并为单池，初始 40/540 这类步枪约 `620=弹匣+备弹+40解锁加成`。仅 `Event_Fire` 扣1，切换/换弹不扣。
- **按武器解锁 `g_iWeaponUnlock[2048] bit0=燃烧 bit1=高爆`** `sp:20`：实体索引级，掉落地上才发光，旧版 `g_bUnlocked[client]` 已废弃仅兼容迁移 `sp:19,362-368`。
- **三态 `MODE_NORMAL 0 / INCEND 1 / EXPLOS 2`** `sp:7-9`：`g_iMode[client]` + `g_bLaser` 保留激光位 `bit4`。
- **弹匣尺寸 `g_iClipSize`**：优先 `L4D2IWA_ClipSize`，回退 `shotgun 8 / rifle 50 / sniper 15 / other 40` `sp:93-97`。

## ConVars `sp:57-61`

| CVar | 默认 | 说明 |
|------|------|------|
| `l4d2_tactical_incend_add` | 40 | 燃烧包追加（实际取 `ClipSize`，回退才用此值） |
| `l4d2_tactical_explos_add` | 40 | 高爆包追加 |
| `l4d2_tactical_explos_self_damage` | 25 | 高爆贴脸自伤 5-30 钳制 |
| `l4d2_tactical_explos_self_radius` | 150 | 自伤判定半径 |
| `l4d2_tactical_explos_self_stagger` | 1 | 是否击退硬直 |

指令：`sm_tactical / sm_changeammo / sm_t` 切模式，`sm_tinfo` 调试；进服 5s 自动 `bind t "sm_tactical"` `sp:84`.

## 总池初始化 `EnsurePool()` `sp:85-136`

- 取 `slot0` 武器 `m_iClip1`/`m_nUpgradedPrimaryAmmoLoaded` → `curClip`，`m_iPrimaryAmmoType` → `m_iAmmo` reserve
- `isNewWeapon = ref!=curRef || ammoType变`
- 若 `total==0 || isNewWeapon` 才重算：
  - 未解锁枪 `b==0` → `total = reserve+cur` 重置，防 `50/524` 污染
  - 已解锁枪保留旧池，`abs(total-real)>200` 才重置为真实（跨枪种差异大时修正）

## 解锁流程（3路冗余）

1. **Event_Upgrade** `sp:137-153`：`upgrade_pack_used` 才算，`upgrade_pack_added` 直接 return；`laser` 忽略；`upgradepack_*` 无 `upgrade_ammo` 忽略；`0.25s Timer_VerifyUpgrade` 校验。
2. **Event_Use** `sp:154-170`：`player_use` 实体含 `upgrade_ammo` 同走 Verify；含 `ammo` 弹药堆 `0.2s Timer_SyncAmmo` `sp:227` 回满 `total=reserve+cur`。
3. **HUD轮询** `sp:574-623` 每 `0.3s` 扫描 `m_upgradeBitVec &3` 或 `up>0`，覆盖商店直接写 bit 无事件的路径 `sp:579`。

`Timer_VerifyUpgrade` `sp:171-226`：

- 去重 `g_fLastVerify 0.4s` `sp:175`
- 严格以 `bit&3 || up>0` 为准推导 `isExpl`，二次校验类型一致否则 `Verify fail`
- `EnsurePool` → `add = ClipSize>0 ? ClipSize : CVar` → `total+=add` → `g_iWeaponUnlock[w]|=位` → `m_upgradeBitVec=newBit|laser, m_nUpgraded=need, m_iClip1=need, m_iAmmo=total-need` → 居中/聊天提示+音效

**坑**：原 `0.12s` 过早常 `Verify fail`，已改 `0.25s` `sp:147`。

## 切换 `SwitchMode()` `sp:356-458`

- 换弹中 (`g_bInReload/g_hReloadTimer/m_bInReload/nativeShotgun`) 禁止 `sp:357-359`
- 迁移旧存档 `g_bUnlocked` → `g_iWeaponUnlock` `sp:363-368`
- `普通→燃烧→高爆→普通` 循环跳过未解锁位 `sp:373-384`
- 记录 `oldCur` 到 `g_iSwitchOldClip`，清空 `Clip/Up/Bit&4` 但 `total` 不变（旧弹已在池），随后动画：
  - 非霰弹：`dur=ReloadDuration+0.1` `sp:448`，`Timer_PollSwitch` `sp:459-476` 轮询 `m_bInReload`/`m_flNextAttack` 结束 → `Timer_GiveNewAmmo` `sp:477-505` `give=min(need,total)` 不扣池
  - 霰弹：逐发 `need=ClipSize-oldCur` `sp:413`，`Timer_ShotgunSwitchShell` `sp:851-904` 每发 `+1` 并 `m_iAmmo=total-newClip`，`IN_ATTACK` 中断

## 换弹拦截 `OnPlayerRunCmd` `sp:688-734` + `DoSpecialReload` `sp:735-789`

- 特殊模式下 `R` 上升沿（过滤 `g_bForceReload` 注入的假信号）若 `cur<clipSize && avail=total-cur>0` 则吞掉引擎 `IN_RELOAD`，走 `DoSpecialReload`
- `DoSpecialReload`：`g_bForceReload=true` 注入首帧动画，`need=clipSize-cur, give=min(need,avail)`，`g_fReloadEnd=now+baseDur+0.3` 预设，霰弹 `0.05s Timer_ShotgunShell` 逐发（`m_flNextPrimaryAttack` 校正），非霰弹 `0.05s Timer_PollReload` 轮询至 `m_bInReload==0 && nextAt/Prim<=now+0.05` 再 `+give`
- 耗尽时 `PrintCenter "特殊弹药耗尽"` 保持特殊位不自动切普通 `sp:751`

霰弹原生竞态保护：`g_bShotgunNativeReload` 期间 HUD 不覆写 `m_iAmmo` `sp:543`，且 `Timer_HUD` 检测 `m_bInReload==0` 后恢复特殊位并 `total=reserveAfter+clipAfter` `sp:510-532`。

## 空仓保持与HUD同步

- `Event_Fire` `sp:240-263`：`total--`，若特殊位被引擎清空（打空）立即 `newBit=needBit|laser` 恢复空仓等待 R
- `Timer_HUD` `sp:506-637`：
  - 已解锁枪每帧 `SetEntProp m_iAmmo = total - cur` `sp:544`
  - 空闲时若 `!hasNeed||!hasUp` 且该枪已解锁则补回特定位 `sp:548-565`
  - 未解锁枪 `total==0` 时 `EnsurePool` 初始化 `sp:568-571`
  - 右下角 `ShowSyncHudText` `总池 X [普通/燃烧/高爆] 解锁:燃烧高爆` `sp:631-633`，仅已解锁或池>0时显示

## 高爆自伤 `sp:296-349`

- 触发：`Event_Fire` 后 `0.03s Timer_ExplosTrace` 射线 `TR_TraceRayFilterEx(MASK_SHOT)` + `Event_BulletImpact` 精确 `x/y/z`，共用 `TryExplosSelfDamage`，`g_fLastSelfDmg 0.12s` 去重 `sp:299`
- 距离：`origin+40` 腹部高度 vs `expPos`，`dist>radius` 无伤
- 伤害：`dmg= maxDmg*(1-dist/radius)` 钳 `5-30` `sp:311-314`，`SDKHooks_TakeDamage(victim,0,0,dmg,DMG_BLAST,bypassHooks=true)` 绕过 FF 豁免，`L4D_StaggerPlayer` 击退 `sp:319-322`

## 掉落发光 `sp:656-687`

- `OnEntityCreated` `weapon_*` 延迟 `0.2s`、换枪后 `0.5s Timer_UpdateAllGroundGlow` 全扫 `sp:233-238`、Verify 后 `0.1s` 均触发 `UpdateWeaponGlow`
- 仅 `m_hOwnerEntity==-1||0` 地上枪：`bit&1` 红 `Constant 800 {255,0,0} + RenderColor 255,40,40`，`bit&2` 黄 `{255,255,0}`，否则 `RemoveGlow/m_iGlowType 0`
- `OnEntityDestroyed` 清 `g_iWeaponUnlock[ent]=0` 并 `RemoveGlow` `sp:644-654`

## 关键时序/数值

- Verify 延迟 `0.25s` + 去重 `0.4s`，Poll 轮询 `0.3s` HUD / `0.05s` Reload
- 自伤去重 `0.12s`，半径 `150`，伤害 `25` 衰减
- 绑定延迟 `5.0s` `sp:82`
- `g_iWeaponUnlock` 上限 `2048`，`MaxClients` 池

## 已知坑位

- `upgrade_pack_added` 空拿不算、激光排除、仅 `upgrade_ammo_*` 算
- 跨枪换 `total` 污染用 `>200` 阈值校正
- 霰弹原生 reload 期间禁止切换/覆写 `m_iAmmo`，需等 `m_bInReload` 清零再恢复
- `m_upgradeBitVec` 激光 `bit4` 需 `&4` 保留
- `L4D2_GetIntWeaponAttribute` 取不到时回退8/50/15/40
- `sm_cvar sv_cheats` 切回会复位 `z_gun_vertical_punch` 等，见 `l4d2-weapon-attributes`

## 2026-08-23 全枪种打空后重装回普通弹修复（霰弹+步枪）

**现象1**：任意枪（霰弹/步枪/狙）在燃烧/高爆模式下打空（`m_iClip1=0,m_nUpgraded=0`）后按 `R`，重新装上的却是普通弹（`m_upgradeBitVec=0`），但 `g_iMode` 仍为特种，HUD 仍显示 `总池 X [燃烧/高爆]`。步枪需按两次 `R` 第二次才转回特种。

**根因**：

1. `OnPlayerRunCmd` `sp:695` 仅拦截 `IN_RELOAD` 上升沿；空仓后引擎下一 tick 才置 `m_bInReload=1`，若漏检则引擎原生插入普通弹（`m_iClip1++ / m_iAmmo--` 不碰 `m_nUpgraded`）。
2. `g_bShotgunNativeReload` `sp:39` 从未置 `true`，`Timer_HUD` `sp:510` 兜底死代码，`sp:543/548` 保护失效；耗尽时 `avail==0` 放行给引擎违背 `sp:752` 设计。
3. 步枪首发上普通后，HUD `0.3s` 才 `!hasNeed||!hasUp` 转回特种，需二次 `R`；霰弹插件自增 `cur+1` 与引擎自增双重叠加导致 `0→2→4` 跳变，UI与泵动不同步。

**修复** (`scripting/l4d2_tactical_ammo_shared.sp` 2026-08-23 20:38及20:45两轮热更)：

- `OnPlayerRunCmd` `sp:703` 泛化劫持：任意枪 `g_iMode!=NORMAL && bits&needBit && m_bInReload==1 && !g_bInReload && timer==null` 立即 `Set m_bInReload 0`，`avail>0` 则 `DoSpecialReload`，否则吞键提示耗尽。
- `Timer_HUD` `sp:506` 泛化起始检测：非插件换弹期任意特种枪 `m_bInReload==1` 置 `g_bShotgunNativeReload=true`，结束时 `m_upgradeBitVec=mode|laser + m_nUpgraded=finalClip` 并 `total=reserveAfter+clipAfter`。
- `OnPlayerRunCmd` `sp:743` 新增空闲即时纠正（`!g_bInReload && timer==null && !native && m_bInReload==0`）：若 `cur>0 && (!hasNeed||!hasUp)` 立即 `m_upgradeBitVec=needBit|laser, m_nUpgraded=cur, m_iAmmo=total-cur`，步枪首发普通 `0.02s` 内自动转特种，无需二次 `R`。
- 霰弹逐发改引擎驱动：`DoSpecialReload` `sp:823` 记录 `g_iShotgunPreReloadClip=cur`；`Timer_ShotgunShell` `sp:841`/`Timer_ShotgunSwitchShell` `sp:919` 改为检测 `curClipNow > Pre` 才 `newClip=curClipNow` 纠正 `m_upgradeBitVec/m_nUpgraded/m_iClip1` 并 `Pre=newClip, Need--`，避免 `cur+1` 双重叠加；`OnPlayerRunCmd` `sp:768` 新增逐发即时纠正每 tick `curSC>Pre && (bit缺失||up==0)` 立即转特种，保证 `0→1→2...` 与泵动一对一。
- `OnEntityDestroyed` `sp:659` 精简仅 `g_iWeaponUnlock[ent]=0`，不再触碰已销毁实体，消除 `m_iGlowType not found` 刷屏。
- `SwitchMode` 霰弹分支 `sp:437` 补 `Pre=0` 初始化。

验证：`spcomp64` 0 error / 3 warning，产物 `20:38 md5 ed606250` → `20:45 md5 9221738e` 均 `sm plugins reload` 成功，`Timestamp 20:45:44 running`。

## 2026-08-23 霰弹逐发UI与步枪二次重装补充修复

**现象2**：霰弹特殊下 `R` 逐发不是一发一变、UI与动作不同步；步枪特殊打空需两次 `R` 才变满特种。

**根因**：见上3；霰弹自增与引擎双增叠加导致跳变，步枪首发普通需等 `0.3s HUD` 才纠正。

**修复**：同上空闲即时纠正 + 霰弹引擎驱动，均为 `20:45` 热更一并部署。

相关：[[l4d2-loot-drop-v180]]（弹药包掉落源） [[l4d2-shop-decoupled]]/[[l4d2-shop-default-prices]]（商店弹药包） [[l4d2-weapon-attributes]]（ClipSize来源） [[l4d2-gl-splash-fix]]/[[l4d2-can-full-damage]]（自伤绕过FF思路）
