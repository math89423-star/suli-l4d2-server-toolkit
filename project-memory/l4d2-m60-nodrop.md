---
name: l4d2-m60-nodrop
description: M60 空弹不丢弃插件 l4d2_m60_nodrop——CRifle_M60::PrimaryAttack 内存补丁（0x85→0x8D 跳过丢弃分支）+ 地面 0 发拾取保护；含反汇编证据、gamedata 注释坑
metadata:
  node_type: memory
  type: solution
  tags:
    - l4d2
    - plugin
    - m60
    - memory-patch
    - gamedata
  originSessionId: dsh-session-l4d2-m60-nodrop
  modified: 2026-08-16T21:00:00.000Z
---

# L4D2 M60 空弹不丢弃（l4d2_m60_nodrop）

## 需求（2026-08-16 用户）

M60/榴弹「子弹为 0 时不丢弃武器」+「如何补弹」。用户明确：先确认不丢弃能实现。
补弹机制（商店放行积分补弹 vs 免费命令）待用户定，未做。

## 结论：M60 丢弃是引擎代码，不是 SM 事件

M60 空弹丢弃发生在 **`CRifle_M60::PrimaryAttack()` 内部**（开火时 clip==0 直接丢枪），
没有任何 game event / SDKHook 可拦。GL 无此丢弃问题（无需 NoDrop patch）。

## 反汇编证据（运行中 server_srv.so，2.2.4.3 build 9309，BuildID 63d548cd）

从容器拷出二进制分析（docker cp l4d2-server:/home/louis/l4d2/left4dead2/bin/server_srv.so，
注意专用服务器加载的是 **server_srv.so** 不是 server.so）：

```
CRifle_M60::PrimaryAttack @ 0x547630（nm 局部符号 t，mangled _ZN10CRifle_M6013PrimaryAttackEv）
  547705: mov 0x1420(%ebx),%eax      ; m_iClip1
  54770b: test %eax,%eax
  54770d: jnz 54767a                  ; 0F 85 67 F9 FF FF；clip!=0 → 正常返回
  ; clip==0 → 落入丢弃块：
  54772a: call CCSPlayer::DropWeapon(owner, weapon, true, NULL)
  54773a: call CBaseCombatCharacter::SwitchToNextBestWeapon(NULL)
  547752: call CBaseEntity::SUB_StartFadeOut(...)
```

**补丁：偏移 222 处字节 0x85 → 0x8D**（`0F 85` jnz → `0F 8D` jge）。
clip 恒 ≥ 0（test 后 SF==OF 恒成立）→ 跳转恒走正常返回 → 丢弃块永不执行。
Windows 构建对应 0x75(jne 短跳) → 0xEB(jmp)（Lux gamedata 偏移 windows 271）。
与社区 LuxLuma [L4D2] M60_NoDrop_AmmoPile_patch 的 linux 偏移 222 完全一致。

## 实现

- `scripting/l4d2_m60_nodrop.sp` + `gamedata/l4d2_m60_nodrop.txt`（移植 Lux 方案 GPLv3）
- 应用前校验字节（必须 0x75 或 0x85，否则 LogError 不打补丁，防版本更新写坏内存）
- OnPluginEnd 还原原字节；`sm_m60nodrop_status`（root）读回当前内存字节验证
- 地面 0 发 M60 拾取保护（Lux 1.0.7 同款）：WeaponCanUse/WeaponDrop 钩子——
  手动丢出 0 发 M60 地面临时改 1 发并标记，玩家拾取瞬间减回 0 发（否则引擎对 0 发地面 M60 拾取处理异常）

## v1.1.0 弹药堆补丁（2026-08-16 用户拍板，GPT 调研 + 本机反汇编双重确认）

**用户决定**：做弹药堆补丁（M60/GL 通过地图弹药堆补弹）；后续会把这两把武器移出商店
改其他途径获取以平衡（"那是后话"）——商店暂不动。

**引擎逻辑**（server_srv.so 9309 反汇编实证）：`CWeaponAmmoSpawn::Use()` 里
`weapon->GetWeaponID(); cmp $0x15 je reject; cmp $0x25 je reject`——GL(21=0x15)/M60(37=0x25)
被明确排除不给弹。**补丁：偏移 81/101 处字节 0x15/0x25 → 0xFF**（武器 ID 永不匹配 →
排除失效 → 弹药堆正常给弹）。与 Lux gamedata（GL 81 / M60 101）完全一致。

**配套**：`ammo_m60_max` 必须非零（cvar `sm_m60_ammo_max` 默认 192，与 AmmoSets
hotgunammo 一致；引擎默认 0 = M60 reserve 上限 0，给了也会被吞）。GL 上限
`ammo_grenadelauncher_max` 本已是 30 不动。M60 reserve>0 后按 R 原生换弹可用
（M16 系动画，社区实证）；空弹**不会**自动换弹——第一版手动 R，不做换弹状态机
（devlos 2023 重写换弹的状态同步坑清单是警告）。

**验证**：`sm_m60nodrop_status` → NoDrop 0x8D / 弹药堆 GL 0xFF M60 0xFF / ammo_m60_max 192。

## tumtara 武器按钮修复（2026-08-16，用户"地图上 M60/榴弹捡不了"根因）

tumtara 的 M60/榴弹 = func_button + `GiveItem(WeaponNames.X)` 脚本发放，WeaponNames 表
缺失（VPK 已删 + 当前 VPK 版 tumtara_common.nuc 也无此定义）→ 按钮只报错不发枪。
修复：VPK 提取 23 个脚本装 data/maps/scripts/vscripts/ + special_toggle_functions.nut
追加 `::WeaponNames` 全局表。详见 [[l4d2-tumtara-pitfalls]] 坑 13。已实测发枪正常。

## v1.3.0 弹药量定稿（2026-08-16 用户拍板，实测补弹链路已通）

| 武器 | 弹夹 | 备弹 | 配置点 |
|---|---|---|---|
| M60 | **150** | **600** | `sm_m60_clip 150`（l4d2_m60_ammo cfg + .sp 默认 450→150）+ `sm_m60_ammo_max 600`（本插件 → 引擎 ammo_m60_max） |
| 榴弹 | 1（上膛） | **40** | `sm_gl_ammo_max 40`（本插件 v1.3.0 新增 → 引擎 ammo_grenadelauncher_max，共 40+1=41） |

- AmmoSets 同步：`l4d2_ammo_set_enabled_ammo_hotgunammo 600` / `..._grenadelauncherammo 40`（拾取给予量）
- 已生效 cvar 全部 RCON 验证（150/600/40/600/40）；**已有武器实体不追溯**——换图后新生成的 M60 才 150 弹夹，老武器打空后弹药堆会补到新上限
- ⚠ **换弹目标弹匣 = 引擎武器属性 clipsize（weapon_init.cfg `sm_weapon rifle_m60 clipsize`），
  不是 sm_m60_clip**！sm_m60_clip 只管生成时弹匣；两者不一致会"换弹后弹匣变回旧值"（实测：
  sm_m60_clip 150 + clipsize 254 → 换弹后变 254）。已统一 150/150（2026-08-17）。
- ⚠ 商店 ShopAmmoRefill 表（l4d2_shop.sp）仍是旧值 254/192/30——因商店对 M60/GL 仍拦截未启用，暂不同步（避免战斗中重载商店）；日后放行时记得改

## 踩坑（重要）

1. **gamedata 里不能写 `//` 注释**：SM gameconfig 解析器不认，注释会把后面的条目
   静默弄丢（条目消失不报错）。gamedata 保持纯 KeyValues 无注释（注释放 .sp 头部）。
2. 文件权限必须 ≥644（容器 louis UID 1000，root 创建的 700 文件读不了，老坑）。
3. `@_ZN` 局部符号（nm 小写 t，不在 .dynsym）SM 1.12 也能解析（SymbolsAreHidden=true
   走自研 .symtab 解析），与 defib_fix 同款；但解析依赖 gamedata 结构：
   **Addresses 节（signature 引用）+ Signatures 节（@_ZN 符号）必须同时存在**。
4. 验证方法：`sm_m60nodrop_status` 读回内存字节（应为 0x8D）+ 日志
   "[M60NoDrop] CRifle_M60::PrimaryAttack 补丁已应用 (offset=222, 0x85 -> 0x8D)"。
5. 内存补丁跨换图/热 reload 保持（reload 走 OnPluginEnd 还原 + OnPluginStart 重打），
   服务器重启后由插件自动重打。

## 状态

- 2026-08-16 20:31 已部署 plugins/，内存验证通过（字节 0x8D）。
- 行为验证：等用户实战把 M60 打到 0 发确认枪不丢（bot 自然开火测试因服务器有人
  未跑成；测试插件 scripting/l4d2_sw_test.sp 保留备用，smx 未部署）。
- 测试插件命令：sm_sw_test <名字|all> <m60|gl|rifle> <clip> [reserve] /
  sm_sw_drain / sm_sw_status / sm_sw_common（bot 面前刷小僵尸引它开火）。

## 下一步（用户拍板后做）

**2026-08-16 用户拍板：补弹走地图弹药堆（弹药堆补丁已上线 v1.1.0），商店暂不动；
后续计划把 M60/GL 移出商店改其他途径获取以平衡（后话）。** 如需再做：
- 商店「弹药补充」放行 M60/GL（l4d2_shop ShopAmmoRefill 表已有 M60 254/192、
  GL 1/30，只需去掉 ammoBlocked 拦截）或新插件免费命令；自维护 m_iClip1 + 玩家
  m_iAmmo[ammoType]（引擎真值，v1.7.4 教训：只改 m_iExtraPrimaryAmmo 镜像无效）。
- M60 reload（原版无 reserve+reload 体系）如需做成普通武器式换弹，单独模块。

## 关联

- [[l4d2-defib-fix-and-player-limit]] — @_ZN + Addresses/Signatures 结构同款先例
- [[l4d2-permissions-pitfall]] — 700 权限坑
- [[l4d2-weapon-values]] — M60 254 发 / GL 数值
- [[l4d2-shop-decoupled]] — 弹药补充商品（ammo_refill）
